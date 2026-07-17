#!/usr/bin/env bash
set -euo pipefail

umask 077

AGENT_ID="${AGENT_ID:-}"
BASE="${OKX_A2A_BASE:-$HOME/.okx-agent-task}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[ "${OKX_A2A_ALLOW_MAINTENANCE:-0}" = "1" ] || die "set OKX_A2A_ALLOW_MAINTENANCE=1 for an explicit production change"
[[ "$AGENT_ID" =~ ^[0-9]+$ ]] || die "AGENT_ID must be numeric"
case "$BASE" in /*) ;; *) die "OKX_A2A_BASE must be absolute" ;; esac

export PATH="$HOME/.local/bin:/opt/node-v22/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
for command_name in install node okx-a2a onchainos systemctl; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name"
done
systemctl --user is-active --quiet okx-a2a-watchdog.service || die "okx-a2a-watchdog.service must be active"
if systemctl --user is-active --quiet okx-a2a.service 2>/dev/null; then
  die "duplicate okx-a2a.service is active"
fi

source_file="$REPO_DIR/tools/a2a-auto-discovery.cjs"
[ -f "$source_file" ] && [ ! -L "$source_file" ] || die "auto-discovery source is missing or a symlink"
node --check "$source_file"

install -d -m 0700 "$BASE/bin" "$BASE/backups" "$BASE/state/auto-discovery" "$BASE/logs" "$HOME/.config/systemd/user"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup="$BASE/backups/auto-discovery-$stamp"
install -d -m 0700 "$backup"

for existing in \
  "$BASE/bin/a2a-auto-discovery.cjs" \
  "$HOME/.config/systemd/user/okx-a2a-auto-discovery.service" \
  "$HOME/.config/systemd/user/okx-a2a-auto-discovery.timer"; do
  if [ -e "$existing" ] || [ -L "$existing" ]; then
    [ -f "$existing" ] && [ ! -L "$existing" ] || die "existing path is not a regular non-symlink file: $existing"
    cp -p "$existing" "$backup/$(basename "$existing")"
  fi
done

install -m 0755 "$source_file" "$BASE/bin/a2a-auto-discovery.cjs.new"
mv -f "$BASE/bin/a2a-auto-discovery.cjs.new" "$BASE/bin/a2a-auto-discovery.cjs"

node_path="$(command -v node)"
service_tmp="$HOME/.config/systemd/user/okx-a2a-auto-discovery.service.$stamp.tmp"
timer_tmp="$HOME/.config/systemd/user/okx-a2a-auto-discovery.timer.$stamp.tmp"

cat >"$service_tmp" <<EOF
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

cat >"$timer_tmp" <<'EOF'
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

chmod 0600 "$service_tmp" "$timer_tmp"
mv -f "$service_tmp" "$HOME/.config/systemd/user/okx-a2a-auto-discovery.service"
mv -f "$timer_tmp" "$HOME/.config/systemd/user/okx-a2a-auto-discovery.timer"

systemd-analyze --user verify \
  "$HOME/.config/systemd/user/okx-a2a-auto-discovery.service" \
  "$HOME/.config/systemd/user/okx-a2a-auto-discovery.timer"
systemctl --user daemon-reload
systemctl --user enable --now okx-a2a-auto-discovery.timer
systemctl --user start okx-a2a-auto-discovery.service
systemctl --user is-active --quiet okx-a2a-auto-discovery.timer || die "auto-discovery timer is not active"
systemctl --user is-active --quiet okx-a2a-watchdog.service || die "watchdog stopped during auto-discovery installation"
if systemctl --user is-active --quiet okx-a2a.service 2>/dev/null; then
  die "duplicate okx-a2a.service became active"
fi

refresh="$(timeout 45s okx-a2a agent refresh --json)"
node -e '
  const value = JSON.parse(process.argv[1]);
  const payload = value && typeof value.payload === "object" ? value.payload : value;
  process.exit(payload.agentCount === 1 && payload.activeClients === 1 ? 0 : 1);
' "$refresh" || die "communication verification did not return agentCount=1 activeClients=1"

printf '%s\n' \
  "Auto-discovery installed." \
  "Timer: active (15 minutes, randomized delay up to 60 seconds)" \
  "Policy: auto-completable public query >= 0.01; analysis/software/content/remote >= 1; quant risk >= 10 USDT" \
  "Behavior: start at most one negotiation per 6 hours; never call apply in the discovery loop" \
  "Backup: $backup"
