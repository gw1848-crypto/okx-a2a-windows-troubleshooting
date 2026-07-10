#!/usr/bin/env bash
set -euo pipefail

AGENT_ID="${AGENT_ID:-}"
BASE="${OKX_A2A_BASE:-$HOME/.okx-agent-task}"

if [ -z "$AGENT_ID" ]; then
  echo "Set AGENT_ID before starting the watchdog." >&2
  exit 2
fi
LOG_DIR="$BASE/logs"
LOG="$LOG_DIR/watchdog.log"

mkdir -p "$LOG_DIR"

export OKX_A2A_AI_CODEX_COMMAND="${OKX_A2A_AI_CODEX_COMMAND:-$BASE/bin/codex-a2a-wrapper.sh}"
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

fail_count=0

log() {
  printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"
}

ensure_daemon() {
  if okx-a2a daemon status >/tmp/okx-a2a-daemon-status.out 2>&1; then
    return 0
  fi

  log "daemon not running, starting"
  okx-a2a daemon start >>"$LOG" 2>&1 || return 1
}

check_active_client() {
  if ! okx-a2a agent refresh --json >/tmp/okx-a2a-agent-refresh.json 2>>"$LOG"; then
    return 1
  fi

  active="$(jq -r '.payload.activeClients // .activeClients // empty' /tmp/okx-a2a-agent-refresh.json 2>/dev/null || true)"
  if [ -z "$active" ] || [ "$active" -lt 1 ]; then
    return 1
  fi
  return 0
}

while true; do
  if ensure_daemon && check_active_client; then
    fail_count=0
  else
    fail_count=$((fail_count + 1))
    log "active client check failed count=$fail_count"
    if [ "$fail_count" -ge 2 ]; then
      log "restarting daemon after repeated failures"
      okx-a2a daemon restart >>"$LOG" 2>&1 || okx-a2a daemon start >>"$LOG" 2>&1 || true
      fail_count=0
    fi
  fi
  sleep 60
done
