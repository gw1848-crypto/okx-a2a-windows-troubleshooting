#!/usr/bin/env bash
set -uo pipefail

umask 077

AGENT_ID="${AGENT_ID:-}"
BASE="${OKX_A2A_BASE:-$HOME/.okx-agent-task}"
COMMAND_TIMEOUT_SECONDS="${HEALTH_COMMAND_TIMEOUT_SECONDS:-30}"
STATE_MAX_AGE_SECONDS="${WATCHDOG_STATE_MAX_AGE_SECONDS:-900}"
STATE_FILE="$BASE/run/watchdog-state.json"
A2A_CODEX_HOME="${OKX_A2A_CODEX_HOME:-$BASE/codex-home}"
A2A_CODEX_SQLITE_HOME="${OKX_A2A_CODEX_SQLITE_HOME:-$A2A_CODEX_HOME/sqlite}"
REAL_CODEX_COMMAND="${OKX_A2A_REAL_CODEX_COMMAND:-}"

if [ -z "$AGENT_ID" ]; then
  echo "Set AGENT_ID before running the health check." >&2
  exit 2
fi
if [[ ! "$COMMAND_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "HEALTH_COMMAND_TIMEOUT_SECONDS must be a positive integer." >&2
  exit 2
fi
if [[ ! "$STATE_MAX_AGE_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "WATCHDOG_STATE_MAX_AGE_SECONDS must be a positive integer." >&2
  exit 2
fi

export OKX_A2A_AI_CODEX_COMMAND="${OKX_A2A_AI_CODEX_COMMAND:-$BASE/bin/codex-a2a-wrapper.sh}"
export PATH="$HOME/.local/bin:/opt/node-v22/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
if [ -z "$REAL_CODEX_COMMAND" ]; then
  REAL_CODEX_COMMAND="$(command -v codex || true)"
fi

failures=0

pass() {
  printf 'OK: %s\n' "$*"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

print_maintenance_hint() {
  cat >&2 <<EOF

This health check is read-only. It did not run preflight, switch-runtime,
agent refresh, setup, doctor, or an outbound guard probe.

If repair is required, use a separate manual maintenance session:
  export OKX_A2A_AI_CODEX_COMMAND="$OKX_A2A_AI_CODEX_COMMAND"
  timeout 180s okx-a2a doctor --fix --json

If doctor changes the runtime, or the watchdog remains unhealthy after its
next check, restart only the watchdog supervisor:
  systemctl --user restart okx-a2a-watchdog.service

Then wait for a fresh watchdog snapshot and run this read-only check again.
EOF
}

echo "[1/7] Required commands"
for required_command in timeout node npm codex onchainos okx-a2a stat find; do
  if command -v "$required_command" >/dev/null 2>&1; then
    pass "$required_command is available"
  else
    fail "$required_command is missing"
  fi
done

if ! command -v timeout >/dev/null 2>&1; then
  print_maintenance_hint
  exit 1
fi

echo "[2/7] Runtime versions and authentication"
if node_version="$(timeout "${COMMAND_TIMEOUT_SECONDS}s" node --version 2>/dev/null)"; then
  pass "Node $node_version"
  if timeout "${COMMAND_TIMEOUT_SECONDS}s" node -e '
    const [major, minor] = process.versions.node.split(".").map(Number);
    process.exit(major > 22 || (major === 22 && minor >= 14) ? 0 : 1);
  ' >/dev/null 2>&1; then
    pass "Node satisfies the v22.14 minimum"
  else
    fail "Node must be v22.14 or newer"
  fi
else
  fail "Node version check failed or timed out"
fi

if npm_version="$(timeout "${COMMAND_TIMEOUT_SECONDS}s" npm --version 2>/dev/null)"; then
  pass "npm $npm_version"
else
  fail "npm version check failed or timed out"
fi

if [ -n "$REAL_CODEX_COMMAND" ] && codex_version="$(timeout "${COMMAND_TIMEOUT_SECONDS}s" "$REAL_CODEX_COMMAND" --version 2>/dev/null)"; then
  pass "Codex ${codex_version%%$'\n'*}"
else
  fail "Codex version check failed or timed out"
fi
if [ -n "$REAL_CODEX_COMMAND" ] && \
  CODEX_HOME="$A2A_CODEX_HOME" CODEX_SQLITE_HOME="$A2A_CODEX_SQLITE_HOME" \
  timeout "${COMMAND_TIMEOUT_SECONDS}s" "$REAL_CODEX_COMMAND" login status >/dev/null 2>&1; then
  pass "isolated A2A Codex authentication is ready"
else
  fail "isolated A2A Codex login status failed or timed out"
fi

if onchainos_version="$(timeout "${COMMAND_TIMEOUT_SECONDS}s" onchainos --version 2>/dev/null)"; then
  pass "OnchainOS ${onchainos_version%%$'\n'*}"
else
  fail "OnchainOS version check failed or timed out"
fi

if a2a_version="$(timeout "${COMMAND_TIMEOUT_SECONDS}s" okx-a2a --version 2>/dev/null)"; then
  pass "A2A Node ${a2a_version%%$'\n'*}"
else
  fail "A2A Node version check failed or timed out"
fi

echo "[3/7] Daemon status"
if daemon_status="$(timeout "${COMMAND_TIMEOUT_SECONDS}s" okx-a2a daemon status 2>/dev/null)"; then
  daemon_status_first_line="${daemon_status%%$'\n'*}"
  case "$daemon_status_first_line" in
    running|running\ *) pass "daemon is running" ;;
    *) fail "daemon status is not running: $daemon_status_first_line" ;;
  esac
else
  fail "daemon status failed or timed out"
fi

echo "[4/7] Cached communication state"
if [ ! -e "$STATE_FILE" ]; then
  fail "watchdog state is missing: $STATE_FILE"
elif [ -L "$STATE_FILE" ] || [ ! -f "$STATE_FILE" ]; then
  fail "watchdog state must be a regular, non-symlink file"
elif [ ! -O "$STATE_FILE" ]; then
  fail "watchdog state is not owned by the current user"
else
  state_mode="$(stat -c '%a' "$STATE_FILE" 2>/dev/null || true)"
  if [ "$state_mode" = "600" ]; then
    pass "watchdog state permissions are 600"
  else
    fail "watchdog state permissions are $state_mode; expected 600"
  fi

  if state_values="$(timeout "${COMMAND_TIMEOUT_SECONDS}s" node -e '
    const fs = require("node:fs");
    const state = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const validCount = (value) => value === null || (Number.isInteger(value) && value >= 0);
    if (state.schemaVersion !== 1 || !Number.isInteger(state.checkedAtEpoch) ||
        typeof state.daemonRunning !== "boolean" || !validCount(state.agentCount) ||
        !validCount(state.activeClients) || typeof state.healthy !== "boolean" ||
        typeof state.reason !== "string" || !/^[a-z_]+$/.test(state.reason)) {
      process.exit(1);
    }
    process.stdout.write([
      state.checkedAtEpoch,
      state.daemonRunning ? 1 : 0,
      state.agentCount ?? -1,
      state.activeClients ?? -1,
      state.healthy ? 1 : 0,
      state.reason,
    ].join("\t"));
  ' "$STATE_FILE" 2>/dev/null)"; then
    IFS=$'\t' read -r checked_at daemon_running agent_count active_clients healthy reason <<<"$state_values"
    now_epoch="$(date +%s)"
    state_age=$((now_epoch - checked_at))

    if [ "$state_age" -lt 0 ] || [ "$state_age" -gt "$STATE_MAX_AGE_SECONDS" ]; then
      fail "watchdog state is stale or future-dated (age=${state_age}s, max=${STATE_MAX_AGE_SECONDS}s)"
    else
      pass "watchdog state is fresh (age=${state_age}s)"
    fi
    if [ "$daemon_running" -ne 1 ]; then
      fail "watchdog last observed the daemon offline (reason=$reason)"
    fi
    if [ "$agent_count" -eq 1 ] && [ "$active_clients" -eq 1 ] && [ "$healthy" -eq 1 ] && [ "$reason" = "ok" ]; then
      pass "agentCount=1 and activeClients=1"
    else
      fail "communication snapshot is unhealthy: agentCount=$agent_count activeClients=$active_clients healthy=$healthy reason=$reason"
    fi
  else
    fail "watchdog state is malformed or incomplete"
  fi
fi

echo "[5/7] Agent identity query"
if timeout "${COMMAND_TIMEOUT_SECONDS}s" onchainos agent get-agents --agent-ids "$AGENT_ID" >/dev/null 2>&1; then
  pass "Agent $AGENT_ID is queryable"
else
  fail "Agent $AGENT_ID query failed or timed out"
fi

echo "[6/7] Local isolation files"
for executable_file in \
  "$BASE/bin/codex-a2a-wrapper.sh" \
  "$BASE/bin/a2a-fast-handler.cjs" \
  "$BASE/guard-bin/okx-a2a" \
  "$BASE/guard-bin/npm"; do
  if [ -f "$executable_file" ] && [ -x "$executable_file" ]; then
    pass "$executable_file is installed and executable"
  else
    fail "$executable_file is missing or not executable"
  fi
done

run_mode="$(stat -c '%a' "$BASE/run" 2>/dev/null || true)"
if [ "$run_mode" = "700" ]; then
  pass "$BASE/run permissions are 700"
else
  fail "$BASE/run permissions are $run_mode; expected 700"
fi

echo "[7/7] Stale stdin capture check"
stale_stdin="$(find "$BASE/run" -maxdepth 1 -type f -name 'a2a-stdin.*' -mmin +5 -print -quit 2>/dev/null || true)"
if [ -z "$stale_stdin" ]; then
  pass "no stale a2a-stdin capture files were found"
else
  fail "stale stdin capture file found: $stale_stdin"
fi

if [ "$failures" -gt 0 ]; then
  printf '\nOKX A2A read-only health check failed: %s issue(s).\n' "$failures" >&2
  print_maintenance_hint
  exit 1
fi

echo
echo "OKX A2A read-only health check passed. No runtime or identity state was changed."
