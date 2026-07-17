#!/usr/bin/env bash
set -euo pipefail
umask 077

AGENT_ID="${AGENT_ID:-}"
BASE="${OKX_A2A_BASE:-$HOME/.okx-agent-task}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ONCHAINOS_VERSION="4.2.6"
readonly A2A_NODE_VERSION="0.1.9"
readonly SKILLS_TAG="v4.2.6"
readonly SKILLS_COMMIT="93a2841501cde295f26af026d9c3a33efd42fd49"
readonly SKILLS_CLI_VERSION="1.5.19"
readonly A2A_NODE_INTEGRITY="sha512-S5luVYnFfI0lGDS6RcpdbQmPr5mhvLS0X4hFg8lVRxGGXq2Rwphc0jlrKt12Pdx6MkdWhbf/rcfFgyXa8aOLWg=="
readonly SKILLS_CLI_INTEGRITY="sha512-SR05cbNk+R17GfaCFv94Hlq5EXDpUCbG0ZL9+EYi5UEHzUPAAl+kls2LxCT+67wAWlOAanUwzZekIVQvpCmp5w=="

if [ -z "$AGENT_ID" ]; then
  echo "Set AGENT_ID to the target ASP Agent ID before running this script." >&2
  exit 2
fi

if [ -L "$BASE/.production-initialized" ] || { [ -e "$BASE/.production-initialized" ] && [ ! -f "$BASE/.production-initialized" ]; }; then
  echo "Refusing to use a production marker that is not a regular non-symlink file." >&2
  exit 3
fi
if [ -f "$BASE/.production-initialized" ] && [ "${OKX_A2A_ALLOW_BOOTSTRAP_REPAIR:-0}" != "1" ]; then
  echo "Refusing to run the bootstrap installer over an initialized production runtime." >&2
  echo "Use the versioned maintenance/deploy workflow instead." >&2
  exit 3
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

install -d -m 0700 "$HOME/.local" "$HOME/.local/bin"
install -d -m 0700 "$BASE" "$BASE/bin" "$BASE/guard-bin" "$BASE/codex-home" \
  "$BASE/codex-home/sqlite" "$BASE/logs" "$BASE/run" "$BASE/state" "$HOME/.config/systemd/user"

sudo apt-get update
sudo apt-get install -y ca-certificates curl git jq unzip build-essential util-linux

node_ok=false
if command -v node >/dev/null 2>&1; then
  node_major="$(node --version | sed -E 's/^v([0-9]+).*/\1/')"
  node_minor="$(node --version | sed -E 's/^v[0-9]+\.([0-9]+).*/\1/')"
  if [ "$node_major" -gt 22 ] || { [ "$node_major" -eq 22 ] && [ "$node_minor" -ge 14 ]; }; then
    node_ok=true
  fi
fi

if [ "$node_ok" != "true" ]; then
  echo "Node.js >=22.14.0 is required. Install a verified Node.js release, then rerun." >&2
  exit 1
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "Codex CLI is required. Install it from the official OpenAI installer, then rerun." >&2
  exit 1
fi

install_onchainos_release() {
  local target asset tmp pinned_expected release_expected actual
  case "$(uname -m)" in
    x86_64)
      target="x86_64-unknown-linux-gnu"
      pinned_expected="04255ac0c375da320f351afd357825ae27db365e841459fe80ac86aed7586bee"
      ;;
    aarch64|arm64)
      target="aarch64-unknown-linux-gnu"
      pinned_expected="1ea7c8f2ebe3ca82fd5a543db17b1f555ed88d425a753a5d00b15df9e3aab21b"
      ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; return 1 ;;
  esac
  asset="onchainos-${target}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  curl --proto '=https' --tlsv1.2 -fsSL --max-time 60 \
    "https://github.com/okx/onchainos-skills/releases/download/v${ONCHAINOS_VERSION}/${asset}" \
    -o "$tmp/$asset"
  curl --proto '=https' --tlsv1.2 -fsSL --max-time 30 \
    "https://github.com/okx/onchainos-skills/releases/download/v${ONCHAINOS_VERSION}/checksums.txt" \
    -o "$tmp/checksums.txt"
  release_expected="$(awk -v name="$asset" '$2 == name {print $1}' "$tmp/checksums.txt")"
  actual="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
  if [ -z "$release_expected" ] || [ "$release_expected" != "$pinned_expected" ] || [ "$actual" != "$pinned_expected" ]; then
    echo "OnchainOS checksum verification failed for $asset." >&2
    return 1
  fi
  install -m 0755 "$tmp/$asset" "$HOME/.local/bin/onchainos"
}

current_onchainos="$(onchainos --version 2>/dev/null | awk '{print $2}' || true)"
if [ "$current_onchainos" != "$ONCHAINOS_VERSION" ]; then
  install_onchainos_release
fi
if [ "$(onchainos --version 2>/dev/null | awk '{print $2}')" != "$ONCHAINOS_VERSION" ]; then
  echo "Installed OnchainOS version does not match $ONCHAINOS_VERSION." >&2
  exit 1
fi

if [ "$(timeout 30s npm view "@okxweb3/a2a-node@${A2A_NODE_VERSION}" dist.integrity)" != "$A2A_NODE_INTEGRITY" ]; then
  echo "A2A Node registry integrity does not match the pinned value." >&2
  exit 1
fi
if [ "$(timeout 30s npm view "skills@${SKILLS_CLI_VERSION}" dist.integrity)" != "$SKILLS_CLI_INTEGRITY" ]; then
  echo "skills CLI registry integrity does not match the pinned value." >&2
  exit 1
fi
if [ "$(timeout 30s git ls-remote https://github.com/okx/onchainos-skills.git "refs/tags/${SKILLS_TAG}^{}" | awk 'NR == 1 {print $1}')" != "$SKILLS_COMMIT" ]; then
  echo "OKX skills tag does not resolve to the pinned commit." >&2
  exit 1
fi
npm install -g "@okxweb3/a2a-node@${A2A_NODE_VERSION}"
npm list -g --depth=0 "@okxweb3/a2a-node@${A2A_NODE_VERSION}" >/dev/null

skills_stage="$(mktemp -d)"
case "$skills_stage" in
  /tmp/*) ;;
  *) echo "Unexpected skills staging directory: $skills_stage" >&2; exit 1 ;;
esac
cleanup_skills_stage() {
  case "$skills_stage" in
    /tmp/*) rm -rf -- "$skills_stage" ;;
  esac
}
trap cleanup_skills_stage EXIT
install -d -m 0700 "$skills_stage/home" "$skills_stage/codex-home" "$BASE/codex-home/skills"
HOME="$skills_stage/home" CODEX_HOME="$skills_stage/codex-home" \
  timeout 180s npx --yes "skills@${SKILLS_CLI_VERSION}" add \
  "https://github.com/okx/onchainos-skills/tree/${SKILLS_TAG}" \
  --skill okx-ai --agent codex --global --copy --yes
staged_skill="$skills_stage/home/.agents/skills/okx-ai"
test -f "$staged_skill/SKILL.md"
test ! -L "$staged_skill"
test ! -L "$staged_skill/SKILL.md"
test -z "$(find "$staged_skill" -type l -print -quit)"
new_skill="$BASE/codex-home/skills/.okx-ai.new.$$"
cp -a "$staged_skill" "$new_skill"
if [ -e "$BASE/codex-home/skills/okx-ai" ] || [ -L "$BASE/codex-home/skills/okx-ai" ]; then
  [ -d "$BASE/codex-home/skills/okx-ai" ] && [ ! -L "$BASE/codex-home/skills/okx-ai" ] || {
    echo "Existing production skill path is not a regular non-symlink directory." >&2
    exit 1
  }
  mv "$BASE/codex-home/skills/okx-ai" "$BASE/state/okx-ai.bootstrap-backup.$(date -u +%Y%m%dT%H%M%SZ)"
fi
mv "$new_skill" "$BASE/codex-home/skills/okx-ai"
chmod 0700 "$BASE/codex-home/skills/okx-ai"
cleanup_skills_stage
trap - EXIT

install -m 0755 "$REPO_DIR/tools/codex-a2a-wrapper.sh" "$BASE/bin/codex-a2a-wrapper.sh"
install -m 0755 "$REPO_DIR/tools/a2a-fast-handler.cjs" "$BASE/bin/a2a-fast-handler.cjs"
install -m 0755 "$REPO_DIR/tools/a2a-auto-discovery.cjs" "$BASE/bin/a2a-auto-discovery.cjs"
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
# Verified on the unprivileged VPS user manager. Do not add directives that
# require unavailable device, clock, UTS, kernel-module, or capability setup.
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native
Environment=AGENT_ID=$AGENT_ID
Environment=OKX_A2A_BASE=$BASE
Environment=OKX_A2A_AI_CODEX_COMMAND=$BASE/bin/codex-a2a-wrapper.sh
Environment=PATH=$HOME/.local/bin:/opt/node-v22/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$BASE/bin/watchdog.sh
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
EOF

node_path="$(command -v node)"
cat > "$HOME/.config/systemd/user/okx-a2a-auto-discovery.service" <<EOF
[Unit]
Description=Guarded OKX AI task discovery for Agent $AGENT_ID
After=network-online.target okx-a2a-watchdog.service
Wants=network-online.target

[Service]
Type=oneshot
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native
Environment=AGENT_ID=$AGENT_ID
Environment=OKX_A2A_BASE=$BASE
Environment=PATH=$HOME/.local/bin:/opt/node-v22/bin:/usr/local/bin:/usr/bin:/bin
Environment=OKX_A2A_DISCOVERY_MIN_WEBSITE=0.01
Environment=OKX_A2A_DISCOVERY_MIN_REMOTE=1
Environment=OKX_A2A_DISCOVERY_MIN_RISK=10
Environment=OKX_A2A_DISCOVERY_MIN_QUERY=0.01
Environment=OKX_A2A_DISCOVERY_MIN_ANALYSIS=1
Environment=OKX_A2A_DISCOVERY_MIN_SOFTWARE=1
Environment=OKX_A2A_DISCOVERY_MIN_CONTENT=1
Environment=OKX_A2A_DISCOVERY_MAX_CANDIDATES=3
Environment=OKX_A2A_DISCOVERY_AUTO_CONTACT=1
Environment=OKX_A2A_DISCOVERY_CONTACT_COOLDOWN_HOURS=6
ExecStart=$node_path $BASE/bin/a2a-auto-discovery.cjs
TimeoutStartSec=90
Nice=10
EOF

cat > "$HOME/.config/systemd/user/okx-a2a-auto-discovery.timer" <<'EOF'
[Unit]
Description=Run guarded OKX AI task discovery periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
RandomizedDelaySec=60s
AccuracySec=30s
Persistent=true
Unit=okx-a2a-auto-discovery.service

[Install]
WantedBy=timers.target
EOF
chmod 0600 \
  "$HOME/.config/systemd/user/okx-a2a-watchdog.service" \
  "$HOME/.config/systemd/user/okx-a2a-auto-discovery.service" \
  "$HOME/.config/systemd/user/okx-a2a-auto-discovery.timer"

sudo loginctl enable-linger "$USER" >/dev/null 2>&1 || true
systemctl --user daemon-reload
systemctl --user enable okx-a2a-watchdog.service
systemctl --user enable okx-a2a-auto-discovery.timer
printf '%s\n' "onchainos=$ONCHAINOS_VERSION" "a2a-node=$A2A_NODE_VERSION" \
  "skills=$SKILLS_TAG" "skills-commit=$SKILLS_COMMIT" "skills-cli=$SKILLS_CLI_VERSION" \
  > "$BASE/.production-initialized"

cat <<EOF
Linux A2A base installed at: $BASE
Next manual steps:
1. Authenticate Codex on this VPS.
2. Log in to OnchainOS / OKX Agentic Wallet on this VPS.
3. Start the single watchdog entrypoint: systemctl --user start okx-a2a-watchdog.service
4. Wait for $BASE/run/watchdog-state.json to appear (normally within 60 seconds).
5. Start guarded task discovery: systemctl --user start okx-a2a-auto-discovery.timer
6. Run the read-only check: $BASE/bin/health-check.sh
EOF
