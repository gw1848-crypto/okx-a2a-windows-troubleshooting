#!/usr/bin/env bash
set -euo pipefail

umask 077

AGENT_ID="${AGENT_ID:-}"
BASE="${OKX_A2A_BASE:-$HOME/.okx-agent-task}"
readonly TARGET_ONCHAINOS_VERSION="4.2.6"
readonly TARGET_A2A_VERSION="0.1.9"
readonly TARGET_SKILLS_TAG="v4.2.6"
readonly TARGET_SKILLS_COMMIT="93a2841501cde295f26af026d9c3a33efd42fd49"
readonly SKILLS_CLI_VERSION="1.5.19"
readonly TARGET_A2A_INTEGRITY="sha512-S5luVYnFfI0lGDS6RcpdbQmPr5mhvLS0X4hFg8lVRxGGXq2Rwphc0jlrKt12Pdx6MkdWhbf/rcfFgyXa8aOLWg=="
readonly SKILLS_CLI_INTEGRITY="sha512-SR05cbNk+R17GfaCFv94Hlq5EXDpUCbG0ZL9+EYi5UEHzUPAAl+kls2LxCT+67wAWlOAanUwzZekIVQvpCmp5w=="

die() {
  echo "ERROR: $*" >&2
  exit 1
}

if [ "${OKX_A2A_ALLOW_MAINTENANCE:-0}" != "1" ]; then
  die "set OKX_A2A_ALLOW_MAINTENANCE=1 for an explicit production maintenance window"
fi
if [ "${OKX_A2A_MAINTENANCE_DRY_RUN:-0}" != "0" ] && [ "${OKX_A2A_MAINTENANCE_DRY_RUN:-0}" != "1" ]; then
  die "OKX_A2A_MAINTENANCE_DRY_RUN must be 0 or 1"
fi
if [ "${OKX_A2A_ALLOW_LEGACY_BASELINE:-0}" != "0" ] && [ "${OKX_A2A_ALLOW_LEGACY_BASELINE:-0}" != "1" ]; then
  die "OKX_A2A_ALLOW_LEGACY_BASELINE must be 0 or 1"
fi
if ! [[ "$AGENT_ID" =~ ^[0-9]+$ ]]; then
  die "AGENT_ID must be the numeric production Agent ID"
fi
case "$BASE" in
  /*) ;;
  *) die "OKX_A2A_BASE must be an absolute path" ;;
esac
marker_existed=0
if [ -f "$BASE/.production-initialized" ] && [ ! -L "$BASE/.production-initialized" ]; then
  marker_existed=1
elif [ -e "$BASE/.production-initialized" ] || [ -L "$BASE/.production-initialized" ]; then
  die "production marker exists but is not a regular non-symlink file"
elif [ "${OKX_A2A_ALLOW_LEGACY_BASELINE:-0}" != "1" ]; then
  die "production marker is missing; set OKX_A2A_ALLOW_LEGACY_BASELINE=1 only for a verified legacy production migration"
fi

export PATH="$HOME/.local/bin:/opt/node-v22/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export OKX_A2A_AI_CODEX_COMMAND="${OKX_A2A_AI_CODEX_COMMAND:-$BASE/bin/codex-a2a-wrapper.sh}"

for command_name in base64 curl date flock git install jq node npm okx-a2a onchainos sha256sum systemctl timeout; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name"
done
for required_file in \
  "$BASE/bin/codex-a2a-wrapper.sh" \
  "$BASE/bin/a2a-fast-handler.cjs" \
  "$BASE/bin/health-check.sh"; do
  [ -f "$required_file" ] && [ ! -L "$required_file" ] || die "required runtime file is missing or a symlink: $required_file"
done

install -d -m 0700 "$BASE/run" "$BASE/backups" "$BASE/releases"
exec 9>>"$BASE/run/runtime-upgrade.lock"
chmod 0600 "$BASE/run/runtime-upgrade.lock"
flock -n 9 || die "another runtime maintenance process already holds the lock"

if systemctl --user is-active --quiet okx-a2a.service 2>/dev/null; then
  die "duplicate okx-a2a.service is active; keep only okx-a2a-watchdog.service"
fi
systemctl --user is-active --quiet okx-a2a-watchdog.service || \
  die "okx-a2a-watchdog.service must be active before maintenance"

version_from_text() {
  grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

current_onchainos="$(onchainos --version 2>/dev/null | version_from_text || true)"
current_a2a="$(okx-a2a --version 2>/dev/null | version_from_text || true)"
[[ "$current_onchainos" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not determine current OnchainOS version"
[[ "$current_a2a" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not determine current A2A Node version"

onchainos_path="$(command -v onchainos)"
expected_onchainos_path="$HOME/.local/bin/onchainos"
[ "$onchainos_path" = "$expected_onchainos_path" ] || \
  die "OnchainOS must be managed at $expected_onchainos_path; found $onchainos_path"
[ -f "$onchainos_path" ] && [ ! -L "$onchainos_path" ] || die "OnchainOS binary is missing or a symlink"

skills_parent="$BASE/codex-home/skills"
skills_dir="$skills_parent/okx-ai"
if [ -e "$skills_parent" ] || [ -L "$skills_parent" ]; then
  [ -d "$skills_parent" ] && [ ! -L "$skills_parent" ] || \
    die "production skills parent exists but is not a regular non-symlink directory"
else
  install -d -m 0700 "$skills_parent"
fi
skill_existed=0
if [ -d "$skills_dir" ] && [ ! -L "$skills_dir" ]; then
  skill_existed=1
elif [ -e "$skills_dir" ] || [ -L "$skills_dir" ]; then
  die "production okx-ai skill path exists but is not a regular non-symlink directory"
elif [ "${OKX_A2A_ALLOW_LEGACY_BASELINE:-0}" != "1" ]; then
  die "production okx-ai skill directory is missing; set OKX_A2A_ALLOW_LEGACY_BASELINE=1 only for a verified legacy production migration"
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup="$BASE/backups/runtime-$stamp"
release="$BASE/releases/runtime-$stamp"
install -d -m 0700 "$backup" "$release" "$release/codex-home" "$release/installer-home"

echo "Preparing verified artifacts while the A2A listener remains online..."

case "$(uname -m)" in
  x86_64)
    onchainos_target="x86_64-unknown-linux-gnu"
    onchainos_sha256="04255ac0c375da320f351afd357825ae27db365e841459fe80ac86aed7586bee"
    ;;
  aarch64|arm64)
    onchainos_target="aarch64-unknown-linux-gnu"
    onchainos_sha256="1ea7c8f2ebe3ca82fd5a543db17b1f555ed88d425a753a5d00b15df9e3aab21b"
    ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac
onchainos_asset="onchainos-$onchainos_target"
curl --proto '=https' --tlsv1.2 -fsSL --max-time 60 \
  "https://github.com/okx/onchainos-skills/releases/download/v${TARGET_ONCHAINOS_VERSION}/${onchainos_asset}" \
  -o "$release/$onchainos_asset"
curl --proto '=https' --tlsv1.2 -fsSL --max-time 30 \
  "https://github.com/okx/onchainos-skills/releases/download/v${TARGET_ONCHAINOS_VERSION}/checksums.txt" \
  -o "$release/checksums.txt"
release_sha256="$(awk -v name="$onchainos_asset" '$2 == name {print $1}' "$release/checksums.txt")"
actual_sha256="$(sha256sum "$release/$onchainos_asset" | awk '{print $1}')"
[ "$release_sha256" = "$onchainos_sha256" ] && [ "$actual_sha256" = "$onchainos_sha256" ] || \
  die "OnchainOS release checksum verification failed"
chmod 0755 "$release/$onchainos_asset"

[ "$(timeout 30s npm view "@okxweb3/a2a-node@${TARGET_A2A_VERSION}" dist.integrity)" = "$TARGET_A2A_INTEGRITY" ] || \
  die "target A2A Node registry integrity changed"
[ "$(timeout 30s npm view "skills@${SKILLS_CLI_VERSION}" dist.integrity)" = "$SKILLS_CLI_INTEGRITY" ] || \
  die "skills CLI registry integrity changed"
remote_skills_commit="$(timeout 30s git ls-remote https://github.com/okx/onchainos-skills.git "refs/tags/${TARGET_SKILLS_TAG}^{}" | awk 'NR == 1 {print $1}')"
[ "$remote_skills_commit" = "$TARGET_SKILLS_COMMIT" ] || die "OKX skills tag no longer resolves to the pinned commit"

pack_to() {
  local destination="$1"
  local package_spec="$2"
  local output filename
  output="$(cd "$destination" && timeout 120s npm pack --silent "$package_spec")"
  filename="${output##*$'\n'}"
  [[ "$filename" =~ ^[A-Za-z0-9._-]+\.tgz$ ]] || die "unexpected npm pack filename for $package_spec"
  [ -f "$destination/$filename" ] || die "npm pack did not create $destination/$filename"
  printf '%s\n' "$destination/$filename"
}

target_a2a_tarball="$(pack_to "$release" "@okxweb3/a2a-node@${TARGET_A2A_VERSION}")"
target_tarball_integrity="$(node -e '
  const crypto = require("node:crypto");
  const fs = require("node:fs");
  const data = fs.readFileSync(process.argv[1]);
  process.stdout.write(`sha512-${crypto.createHash("sha512").update(data).digest("base64")}`);
' "$target_a2a_tarball")"
[ "$target_tarball_integrity" = "$TARGET_A2A_INTEGRITY" ] || die "downloaded A2A Node tarball integrity mismatch"

skills_log="$release/skills-install.log"
HOME="$release/installer-home" CODEX_HOME="$release/codex-home" \
  timeout 180s npx --yes "skills@${SKILLS_CLI_VERSION}" add \
  "https://github.com/okx/onchainos-skills/tree/${TARGET_SKILLS_TAG}" \
  --skill okx-ai --agent codex --global --copy --yes >"$skills_log" 2>&1
staged_skill="$release/installer-home/.agents/skills/okx-ai"
[ -f "$staged_skill/SKILL.md" ] && [ ! -L "$staged_skill" ] && [ ! -L "$staged_skill/SKILL.md" ] || \
  die "staged OKX skill is missing or contains an unexpected symlink"
[ -z "$(find "$staged_skill" -type l -print -quit)" ] || die "staged OKX skill contains a symlink"

cp -p "$onchainos_path" "$backup/onchainos"
if [ "$skill_existed" -eq 1 ]; then
  cp -a "$skills_dir" "$backup/okx-ai"
fi
rollback_a2a_tarball="$(pack_to "$backup" "@okxweb3/a2a-node@${current_a2a}")"
current_a2a_integrity="$(timeout 30s npm view "@okxweb3/a2a-node@${current_a2a}" dist.integrity)"
rollback_tarball_integrity="$(node -e '
  const crypto = require("node:crypto");
  const fs = require("node:fs");
  const data = fs.readFileSync(process.argv[1]);
  process.stdout.write(`sha512-${crypto.createHash("sha512").update(data).digest("base64")}`);
' "$rollback_a2a_tarball")"
[ -n "$current_a2a_integrity" ] && [ "$rollback_tarball_integrity" = "$current_a2a_integrity" ] || \
  die "rollback A2A Node tarball integrity mismatch"
if [ "$marker_existed" -eq 1 ]; then
  cp -p "$BASE/.production-initialized" "$backup/production-initialized"
fi
printf '%s\n' \
  "started=$stamp" \
  "agent=$AGENT_ID" \
  "onchainos-before=$current_onchainos" \
  "a2a-before=$current_a2a" \
  "onchainos-target=$TARGET_ONCHAINOS_VERSION" \
  "a2a-target=$TARGET_A2A_VERSION" \
  "skills-target=$TARGET_SKILLS_TAG" \
  "skills-commit=$TARGET_SKILLS_COMMIT" \
  "legacy-marker-existed=$marker_existed" \
  "legacy-skill-existed=$skill_existed" \
  >"$backup/manifest"
sha256sum "$backup/onchainos" "$rollback_a2a_tarball" "$release/$onchainos_asset" "$target_a2a_tarball" \
  >"$backup/artifact-sha256"

if [ "${OKX_A2A_MAINTENANCE_DRY_RUN:-0}" = "1" ]; then
  printf '%s\n' \
    "Maintenance dry run complete; the listener was not stopped." \
    "Current: OnchainOS $current_onchainos, A2A Node $current_a2a" \
    "Target: OnchainOS $TARGET_ONCHAINOS_VERSION, A2A Node $TARGET_A2A_VERSION" \
    "Legacy baseline: marker-existed=$marker_existed skill-existed=$skill_existed" \
    "Verified release: $release" \
    "Verified rollback backup: $backup"
  exit 0
fi

changed=0
success=0
auto_discovery_timer_was_active=0
if systemctl --user is-active --quiet okx-a2a-auto-discovery.timer 2>/dev/null; then
  auto_discovery_timer_was_active=1
fi

rollback_runtime() {
  set +e
  echo "Upgrade validation failed; rolling back the previous runtime..." >&2
  timeout 30s systemctl --user stop okx-a2a-watchdog.service >/dev/null 2>&1
  timeout 30s okx-a2a daemon stop >/dev/null 2>&1

  install -m 0755 "$backup/onchainos" "$expected_onchainos_path.rollback"
  mv -f "$expected_onchainos_path.rollback" "$expected_onchainos_path"
  timeout 180s npm install -g "$rollback_a2a_tarball" >/dev/null 2>"$backup/rollback-a2a.err"

  if [ "$skill_existed" -eq 1 ]; then
    rollback_skill="$skills_parent/.okx-ai.rollback.$stamp"
    cp -a "$backup/okx-ai" "$rollback_skill"
    if [ -e "$skills_dir" ]; then
      mv "$skills_dir" "$backup/failed-okx-ai"
    fi
    mv "$rollback_skill" "$skills_dir"
  elif [ -e "$skills_dir" ]; then
    mv "$skills_dir" "$backup/failed-okx-ai"
  fi

  if [ "$marker_existed" -eq 1 ]; then
    cp -p "$backup/production-initialized" "$BASE/.production-initialized.rollback"
    mv -f "$BASE/.production-initialized.rollback" "$BASE/.production-initialized"
  elif [ -e "$BASE/.production-initialized" ]; then
    mv "$BASE/.production-initialized" "$backup/failed-production-initialized"
  fi

  timeout 30s systemctl --user start okx-a2a-watchdog.service >/dev/null 2>&1
  if [ "$auto_discovery_timer_was_active" -eq 1 ]; then
    timeout 30s systemctl --user start okx-a2a-auto-discovery.timer >/dev/null 2>&1
  fi
  echo "Rollback attempted. Inspect $backup and rerun the read-only health check." >&2
  set -e
}

on_exit() {
  local status=$?
  trap - EXIT
  if [ "$changed" -eq 1 ] && [ "$success" -ne 1 ]; then
    rollback_runtime
  fi
  exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

maintenance_started_epoch="$(date +%s)"
echo "Entering the short maintenance window..."
if [ "$auto_discovery_timer_was_active" -eq 1 ]; then
  timeout 30s systemctl --user stop okx-a2a-auto-discovery.timer
fi
timeout 30s systemctl --user stop okx-a2a-watchdog.service
changed=1
timeout 30s okx-a2a daemon stop >/dev/null 2>&1 || true
if timeout 10s okx-a2a daemon status 2>/dev/null | head -n 1 | grep -Eq '^running([[:space:]]|$)'; then
  die "A2A daemon did not stop before the global package upgrade"
fi

install -m 0755 "$release/$onchainos_asset" "$expected_onchainos_path.new"
mv -f "$expected_onchainos_path.new" "$expected_onchainos_path"
timeout 180s npm install -g "$target_a2a_tarball" >"$release/a2a-install.log" 2>&1

[ "$(onchainos --version 2>/dev/null | version_from_text)" = "$TARGET_ONCHAINOS_VERSION" ] || \
  die "OnchainOS version verification failed after install"
[ "$(okx-a2a --version 2>/dev/null | version_from_text)" = "$TARGET_A2A_VERSION" ] || \
  die "A2A Node version verification failed after install"

new_skill="$skills_parent/.okx-ai.new.$stamp"
cp -a "$staged_skill" "$new_skill"
if [ "$skill_existed" -eq 1 ]; then
  mv "$skills_dir" "$backup/live-okx-ai"
fi
mv "$new_skill" "$skills_dir"

setup_file="$release/setup.json"
if ! timeout 120s okx-a2a setup --json >"$setup_file" 2>"$release/setup.err"; then
  die "A2A setup verification failed; details retained in the private release directory"
fi
node -e '
  const fs = require("node:fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const payload = value && typeof value.payload === "object" ? value.payload : value;
  if (payload.state !== "ready" || payload.authStatus !== "ready" || payload.providerCommandPersisted !== true) {
    process.exit(1);
  }
' "$setup_file" || die "A2A setup did not confirm ready auth and the persisted provider command"

# A2A setup may recreate or start its own user service. The watchdog remains
# the sole lifecycle owner and always launches the daemon with --no-autostart.
timeout 30s systemctl --user stop okx-a2a.service >/dev/null 2>&1 || true
if systemctl --user is-active --quiet okx-a2a.service 2>/dev/null; then
  die "A2A setup left the duplicate okx-a2a.service active"
fi

marker_tmp="$(mktemp "$BASE/.production-initialized.XXXXXX")"
printf '%s\n' \
  "onchainos=$TARGET_ONCHAINOS_VERSION" \
  "a2a-node=$TARGET_A2A_VERSION" \
  "skills=$TARGET_SKILLS_TAG" \
  "skills-commit=$TARGET_SKILLS_COMMIT" \
  "skills-cli=$SKILLS_CLI_VERSION" \
  >"$marker_tmp"
chmod 0600 "$marker_tmp"
mv -f "$marker_tmp" "$BASE/.production-initialized"

fast_start_ms="$(date +%s%3N)"
fast_output="$(OKX_A2A_FAST_HANDLER_SELF_TEST=1 timeout 3s \
  "$BASE/bin/codex-a2a-wrapper.sh" --sandbox workspace-write exec self-test </dev/null)"
fast_elapsed_ms=$(( $(date +%s%3N) - fast_start_ms ))
grep -q '^FAST_HANDLER_SELF_TEST ok$' <<<"$fast_output" || die "wrapper did not hit the fast handler"
[ "$fast_elapsed_ms" -le 2000 ] || die "fast handler self-test exceeded 2000ms (${fast_elapsed_ms}ms)"

timeout 30s systemctl --user start okx-a2a-watchdog.service
timeout 15s systemctl --user is-active --quiet okx-a2a-watchdog.service || die "watchdog did not start"
if systemctl --user is-active --quiet okx-a2a.service 2>/dev/null; then
  die "duplicate okx-a2a.service became active after watchdog start"
fi

state_file="$BASE/run/watchdog-state.json"
state_ready=0
for _ in $(seq 1 45); do
  if [ -s "$state_file" ] && node -e '
    const fs = require("node:fs");
    const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const minimumEpoch = Number(process.argv[2]);
    const fresh = Number.isInteger(value.checkedAtEpoch)
      && value.checkedAtEpoch >= minimumEpoch
      && Math.abs(Date.now() / 1000 - value.checkedAtEpoch) <= 180;
    process.exit(fresh && value.agentCount === 1 && value.activeClients === 1 && value.healthy === true ? 0 : 1);
  ' "$state_file" "$maintenance_started_epoch" 2>/dev/null; then
    state_ready=1
    break
  fi
  sleep 2
done
[ "$state_ready" -eq 1 ] || die "watchdog did not produce a fresh activeClients=1 snapshot"

AGENT_ID="$AGENT_ID" "$BASE/bin/health-check.sh" >"$release/health-check.log" 2>&1 || \
  die "read-only health check failed after upgrade"
refresh_file="$release/agent-refresh.json"
timeout 45s okx-a2a agent refresh --json >"$refresh_file" 2>"$release/agent-refresh.err"
jq -e '((.payload.agentCount // .agentCount) == 1) and ((.payload.activeClients // .activeClients) == 1)' \
  "$refresh_file" >/dev/null || die "live communication verification did not return agentCount=1 and activeClients=1"
if systemctl --user is-active --quiet okx-a2a.service 2>/dev/null; then
  die "duplicate okx-a2a.service became active during final communication verification"
fi
if [ "$auto_discovery_timer_was_active" -eq 1 ]; then
  timeout 30s systemctl --user start okx-a2a-auto-discovery.timer
  systemctl --user is-active --quiet okx-a2a-auto-discovery.timer || \
    die "auto-discovery timer did not resume after runtime maintenance"
fi

success=1
printf '%s\n' \
  "Upgrade complete." \
  "OnchainOS: $TARGET_ONCHAINOS_VERSION" \
  "A2A Node: $TARGET_A2A_VERSION" \
  "OKX skills: $TARGET_SKILLS_TAG ($TARGET_SKILLS_COMMIT)" \
  "Fast handler: ${fast_elapsed_ms}ms" \
  "Communication: agentCount=1 activeClients=1" \
  "Backup: $backup"
