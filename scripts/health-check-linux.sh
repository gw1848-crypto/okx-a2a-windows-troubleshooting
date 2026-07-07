#!/usr/bin/env bash
set -euo pipefail

AGENT_ID="${AGENT_ID:-3682}"
BASE="${OKX_A2A_BASE:-$HOME/.okx-agent-task}"

export OKX_A2A_AI_CODEX_COMMAND="${OKX_A2A_AI_CODEX_COMMAND:-$BASE/bin/codex-a2a-wrapper.sh}"
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

echo "[1/8] Node"
node --version
npm --version

echo "[2/8] Codex"
codex --version

echo "[3/8] OnchainOS"
onchainos preflight --skill-version 4.1.0

echo "[4/8] A2A CLI"
npm list -g @okxweb3/a2a-node --depth=0 --json
okx-a2a --version || true

echo "[5/8] Daemon"
okx-a2a daemon status || true

echo "[6/8] Runtime setup"
okx-a2a switch-runtime --json
okx-a2a agent refresh --json
okx-a2a setup --json

echo "[7/8] Agent status"
onchainos agent get-agents --agent-ids "$AGENT_ID" || true

echo "[8/8] Guard checks"
set +e
"$BASE/guard-bin/okx-a2a" xmtp-send --job-id dummy --to-agent-id 1 --message 'jwt auth fail stderr' >/tmp/okx-a2a-guard-test.out 2>&1
status=$?
set -e
if [ "$status" -eq 0 ]; then
  echo "Sensitive xmtp-send guard did not block." >&2
  exit 1
fi
if [ "$status" -ne 78 ]; then
  cat /tmp/okx-a2a-guard-test.out >&2 || true
  echo "Sensitive xmtp-send guard returned $status, expected 78." >&2
  exit 1
fi

echo "OKX A2A Linux health check completed."
