#!/usr/bin/env bash
set -euo pipefail

AGENT_ID="${AGENT_ID:-}"
BASE="${OKX_A2A_BASE:-$HOME/.okx-agent-task}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "$AGENT_ID" ]; then
  echo "Set AGENT_ID to the target ASP Agent ID before running this script." >&2
  exit 2
fi

if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required on this VPS user." >&2
  exit 1
fi

if [ ! -r /etc/os-release ]; then
  echo "Cannot detect Linux distribution." >&2
  exit 1
fi

. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *)
    echo "This setup script is tested for Ubuntu/Debian. Detected: ${ID:-unknown}" >&2
    exit 1
    ;;
esac

mkdir -p "$BASE/bin" "$BASE/guard-bin" "$BASE/codex-home/sqlite" "$BASE/logs" "$HOME/.config/systemd/user"

sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git jq unzip build-essential

node_ok=false
if command -v node >/dev/null 2>&1; then
  node_major="$(node --version | sed -E 's/^v([0-9]+).*/\1/')"
  node_minor="$(node --version | sed -E 's/^v[0-9]+\.([0-9]+).*/\1/')"
  if [ "$node_major" -gt 22 ] || { [ "$node_major" -eq 22 ] && [ "$node_minor" -ge 14 ]; }; then
    node_ok=true
  fi
fi

if [ "$node_ok" != "true" ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi

if ! command -v codex >/dev/null 2>&1; then
  curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh
fi

if ! command -v onchainos >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/okx/onchainos-skills/main/install.sh -o /tmp/onchainos-install.sh
  sh /tmp/onchainos-install.sh
fi

npm install -g @okxweb3/a2a-node@latest
npx --yes skills add okx/onchainos-skills --yes || true

install -m 0755 "$REPO_DIR/tools/codex-a2a-wrapper.sh" "$BASE/bin/codex-a2a-wrapper.sh"
install -m 0755 "$REPO_DIR/tools/a2a-fast-handler.cjs" "$BASE/bin/a2a-fast-handler.cjs"
install -m 0755 "$REPO_DIR/guards/okx-a2a" "$BASE/guard-bin/okx-a2a"
install -m 0755 "$REPO_DIR/guards/npm" "$BASE/guard-bin/npm"
install -m 0644 "$REPO_DIR/examples/AGENTS.override-linux.md" "$BASE/codex-home/AGENTS.override.md"
install -m 0755 "$REPO_DIR/scripts/health-check-linux.sh" "$BASE/bin/health-check.sh"
install -m 0755 "$REPO_DIR/scripts/watchdog-linux.sh" "$BASE/bin/watchdog.sh"

cat > "$BASE/codex-home/config.toml" <<'EOF'
model = "gpt-5.4-mini"
model_reasoning_effort = "low"
approval_policy = "never"
sandbox_mode = "workspace-write"
EOF

cat > "$HOME/.config/systemd/user/okx-a2a-watchdog.service" <<EOF
[Unit]
Description=OKX A2A watchdog for Agent $AGENT_ID
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=AGENT_ID=$AGENT_ID
Environment=OKX_A2A_BASE=$BASE
Environment=OKX_A2A_AI_CODEX_COMMAND=$BASE/bin/codex-a2a-wrapper.sh
Environment=PATH=$HOME/.local/bin:/opt/node-v22/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$BASE/bin/watchdog.sh
Restart=always
RestartSec=15

[Install]
WantedBy=default.target
EOF

sudo loginctl enable-linger "$USER" >/dev/null 2>&1 || true
systemctl --user daemon-reload
systemctl --user enable okx-a2a-watchdog.service

cat <<EOF
Linux A2A base installed at: $BASE
Next manual steps:
1. Authenticate Codex on this VPS.
2. Log in to OnchainOS / OKX Agentic Wallet on this VPS.
3. Run: $BASE/bin/health-check.sh
4. If healthy, run: systemctl --user start okx-a2a-watchdog.service
EOF
