#!/usr/bin/env bash
set -euo pipefail

umask 077

AGENT_ID="${AGENT_ID:-}"
BASE="${OKX_A2A_BASE:-$HOME/.okx-agent-task}"
INTERVAL_SECONDS="${WATCHDOG_INTERVAL_SECONDS:-60}"
REFRESH_INTERVAL_SECONDS="${WATCHDOG_REFRESH_INTERVAL_SECONDS:-300}"
RESTART_COOLDOWN_SECONDS="${WATCHDOG_RESTART_COOLDOWN_SECONDS:-600}"
FAILURES_BEFORE_RESTART="${WATCHDOG_FAILURES_BEFORE_RESTART:-2}"
LOG_MAX_BYTES="${WATCHDOG_LOG_MAX_BYTES:-10485760}"
LOG_BACKUP_COUNT="${WATCHDOG_LOG_BACKUP_COUNT:-5}"
RUN_ONCE="${WATCHDOG_RUN_ONCE:-0}"

if [ -z "$AGENT_ID" ]; then
  echo "Set AGENT_ID before starting the watchdog." >&2
  exit 2
fi

require_positive_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "$name must be a positive integer; got: $value" >&2
    exit 2
  fi
}

require_positive_integer WATCHDOG_INTERVAL_SECONDS "$INTERVAL_SECONDS"
require_positive_integer WATCHDOG_REFRESH_INTERVAL_SECONDS "$REFRESH_INTERVAL_SECONDS"
require_positive_integer WATCHDOG_RESTART_COOLDOWN_SECONDS "$RESTART_COOLDOWN_SECONDS"
require_positive_integer WATCHDOG_FAILURES_BEFORE_RESTART "$FAILURES_BEFORE_RESTART"
require_positive_integer WATCHDOG_LOG_MAX_BYTES "$LOG_MAX_BYTES"
require_positive_integer WATCHDOG_LOG_BACKUP_COUNT "$LOG_BACKUP_COUNT"
if [ "$RUN_ONCE" != "0" ] && [ "$RUN_ONCE" != "1" ]; then
  echo "WATCHDOG_RUN_ONCE must be 0 or 1; got: $RUN_ONCE" >&2
  exit 2
fi

LOG_DIR="$BASE/logs"
RUN_DIR="$BASE/run"
LOG="$LOG_DIR/watchdog.log"
LOCK_FILE="$RUN_DIR/watchdog.lock"
STATE_FILE="$RUN_DIR/watchdog-state.json"

mkdir -p "$LOG_DIR" "$RUN_DIR"
chmod 0700 "$LOG_DIR" "$RUN_DIR"

export OKX_A2A_AI_CODEX_COMMAND="${OKX_A2A_AI_CODEX_COMMAND:-$BASE/bin/codex-a2a-wrapper.sh}"
export PATH="$HOME/.local/bin:/opt/node-v22/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

for required_command in timeout flock node okx-a2a stat; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Required command is missing: $required_command" >&2
    exit 69
  fi
done

# Keep the descriptor open for the lifetime of the process. A second manual or
# systemd launch exits without running recovery actions.
exec 9>>"$LOCK_FILE"
chmod 0600 "$LOCK_FILE"
if ! flock -n 9; then
  echo "OKX A2A watchdog is already running for base: $BASE" >&2
  # A systemd unit using Restart=on-failure must retry after a transient lock
  # conflict; exiting successfully could leave only a manual instance alive.
  exit 75
fi

rotate_log_if_needed() {
  local log_size index previous

  if [ ! -f "$LOG" ]; then
    touch "$LOG"
    chmod 0600 "$LOG"
    return 0
  fi

  log_size="$(stat -c '%s' "$LOG" 2>/dev/null || printf '0')"
  if [[ ! "$log_size" =~ ^[0-9]+$ ]] || [ "$log_size" -lt "$LOG_MAX_BYTES" ]; then
    chmod 0600 "$LOG"
    return 0
  fi

  index="$LOG_BACKUP_COUNT"
  while [ "$index" -gt 1 ]; do
    previous=$((index - 1))
    if [ -f "$LOG.$previous" ]; then
      mv -f -- "$LOG.$previous" "$LOG.$index"
    fi
    index="$previous"
  done
  mv -f -- "$LOG" "$LOG.1"
  touch "$LOG"
  chmod 0600 "$LOG"
}

log() {
  rotate_log_if_needed
  printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"
}

write_state() {
  local checked_at="$1"
  local daemon_running="$2"
  local agent_count="$3"
  local active_clients="$4"
  local healthy="$5"
  local reason="$6"
  local state_tmp

  if [[ ! "$reason" =~ ^[a-z_]+$ ]]; then
    reason="invalid_state_reason"
  fi
  if [ -z "$agent_count" ]; then
    agent_count="null"
  fi
  if [ -z "$active_clients" ]; then
    active_clients="null"
  fi

  state_tmp="$(mktemp "$RUN_DIR/watchdog-state.XXXXXX")"
  if ! printf '{"schemaVersion":1,"checkedAtEpoch":%s,"daemonRunning":%s,"agentCount":%s,"activeClients":%s,"healthy":%s,"reason":"%s"}\n' \
    "$checked_at" "$daemon_running" "$agent_count" "$active_clients" "$healthy" "$reason" >"$state_tmp"; then
    rm -f -- "$state_tmp"
    return 1
  fi
  chmod 0600 "$state_tmp"
  mv -f -- "$state_tmp" "$STATE_FILE"
}

daemon_is_running() {
  local status_output first_line
  if ! status_output="$(timeout 15s okx-a2a daemon status 9>&- 2>&1)"; then
    return 1
  fi
  first_line="${status_output%%$'\n'*}"
  case "$first_line" in
    running|running\ *) return 0 ;;
    *) return 1 ;;
  esac
}

DAEMON_RECOVERED=0
ensure_daemon() {
  DAEMON_RECOVERED=0
  if daemon_is_running; then
    return 0
  fi

  log "WARN daemon is not running; starting without installing another autostart entry"
  if ! timeout 30s okx-a2a daemon start --no-autostart 9>&- >>"$LOG" 2>&1; then
    log "ERROR daemon start failed or timed out"
    return 1
  fi
  if ! daemon_is_running; then
    log "ERROR daemon did not report running after start"
    return 1
  fi

  DAEMON_RECOVERED=1
  log "OK daemon started"
  return 0
}

restart_daemon() {
  log "WARN restarting daemon after repeated communication failures"
  if ! timeout 30s okx-a2a daemon restart 9>&- >>"$LOG" 2>&1; then
    log "ERROR daemon restart failed or timed out"
    return 1
  fi
  if ! daemon_is_running; then
    log "ERROR daemon did not report running after restart"
    return 1
  fi
  log "OK daemon restarted; communication will be checked on the next cycle"
}

CHECK_AGENT_COUNT=""
CHECK_ACTIVE_CLIENTS=""
CHECK_REASON=""
CHECK_RESTARTABLE=0

check_agent_health() {
  local checked_at="$1"
  local refresh_file counts

  CHECK_AGENT_COUNT=""
  CHECK_ACTIVE_CLIENTS=""
  CHECK_REASON="refresh_failed"
  CHECK_RESTARTABLE=1
  refresh_file="$(mktemp "$RUN_DIR/agent-refresh.XXXXXX")"

  if ! timeout 45s okx-a2a agent refresh --json 9>&- >"$refresh_file" 2>>"$LOG"; then
    rm -f -- "$refresh_file"
    write_state "$checked_at" true "" "" false "$CHECK_REASON" || log "ERROR could not write watchdog state"
    return 1
  fi

  if ! counts="$(node -e '
    const fs = require("node:fs");
    const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const payload = value && typeof value.payload === "object" ? value.payload : value;
    const agentCount = payload && payload.agentCount;
    const activeClients = payload && payload.activeClients;
    if (!Number.isInteger(agentCount) || agentCount < 0 || !Number.isInteger(activeClients) || activeClients < 0) {
      process.exit(1);
    }
    process.stdout.write(`${agentCount}\t${activeClients}`);
  ' "$refresh_file" 9>&- 2>>"$LOG")"; then
    rm -f -- "$refresh_file"
    CHECK_REASON="refresh_parse_failed"
    CHECK_RESTARTABLE=0
    write_state "$checked_at" true "" "" false "$CHECK_REASON" || log "ERROR could not write watchdog state"
    return 1
  fi
  rm -f -- "$refresh_file"

  IFS=$'\t' read -r CHECK_AGENT_COUNT CHECK_ACTIVE_CLIENTS <<<"$counts"
  if [ "$CHECK_AGENT_COUNT" -eq 1 ] && [ "$CHECK_ACTIVE_CLIENTS" -eq 1 ]; then
    CHECK_REASON="ok"
    CHECK_RESTARTABLE=0
    write_state "$checked_at" true "$CHECK_AGENT_COUNT" "$CHECK_ACTIVE_CLIENTS" true "$CHECK_REASON" || log "ERROR could not write watchdog state"
    return 0
  fi

  if [ "$CHECK_AGENT_COUNT" -ne 1 ]; then
    CHECK_REASON="agent_count_mismatch"
    CHECK_RESTARTABLE=0
  else
    CHECK_REASON="active_clients_mismatch"
    CHECK_RESTARTABLE=1
  fi
  write_state "$checked_at" true "$CHECK_AGENT_COUNT" "$CHECK_ACTIVE_CLIENTS" false "$CHECK_REASON" || log "ERROR could not write watchdog state"
  return 1
}

fail_count=0
last_refresh_epoch=0
last_restart_epoch=0

log "START watchdog pid=$$ refreshInterval=${REFRESH_INTERVAL_SECONDS}s restartCooldown=${RESTART_COOLDOWN_SECONDS}s"
trap 'log "STOP watchdog pid=$$"' EXIT

while true; do
  now_epoch="$(date +%s)"

  if ! ensure_daemon; then
    fail_count=$((fail_count + 1))
    write_state "$now_epoch" false "" "" false "daemon_unavailable" || log "ERROR could not write watchdog state"
    log "ERROR daemon recovery failed count=$fail_count"
  else
    if [ "$DAEMON_RECOVERED" -eq 1 ]; then
      last_refresh_epoch=0
    fi

    if [ "$last_refresh_epoch" -eq 0 ] || [ $((now_epoch - last_refresh_epoch)) -ge "$REFRESH_INTERVAL_SECONDS" ]; then
      if check_agent_health "$now_epoch"; then
        if [ "$fail_count" -gt 0 ]; then
          log "OK communication recovered agentCount=1 activeClients=1"
        fi
        fail_count=0
        last_refresh_epoch="$now_epoch"
      else
        fail_count=$((fail_count + 1))
        log "WARN communication check failed reason=$CHECK_REASON agentCount=${CHECK_AGENT_COUNT:-unknown} activeClients=${CHECK_ACTIVE_CLIENTS:-unknown} count=$fail_count"

        if [ "$CHECK_RESTARTABLE" -eq 0 ]; then
          # Configuration/schema failures are not repaired by daemon churn.
          fail_count=0
          last_refresh_epoch="$now_epoch"
        elif [ "$fail_count" -ge "$FAILURES_BEFORE_RESTART" ]; then
          if [ "$last_restart_epoch" -eq 0 ] || [ $((now_epoch - last_restart_epoch)) -ge "$RESTART_COOLDOWN_SECONDS" ]; then
            last_restart_epoch="$now_epoch"
            fail_count=0
            if restart_daemon; then
              last_refresh_epoch=0
              write_state "$now_epoch" true "" "" false "daemon_restarted_pending_check" || log "ERROR could not write watchdog state"
            else
              last_refresh_epoch="$now_epoch"
              write_state "$now_epoch" false "" "" false "daemon_restart_failed" || log "ERROR could not write watchdog state"
            fi
          else
            log "WARN restart suppressed by cooldown"
            fail_count=0
            last_refresh_epoch="$now_epoch"
          fi
        else
          # Retry once on the next loop; healthy operation stays on the slower
          # refresh interval to avoid unnecessary identity churn.
          last_refresh_epoch=0
        fi
      fi
    fi
  fi

  if [ "$RUN_ONCE" = "1" ]; then
    break
  fi
  sleep "$INTERVAL_SECONDS"
done
