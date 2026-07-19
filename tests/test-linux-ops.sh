#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"

cleanup() {
  case "$TMP_ROOT" in
    "${TMPDIR:-/tmp}"/*|/tmp/*) rm -rf -- "$TMP_ROOT" ;;
    *) echo "Refusing to remove unexpected test directory: $TMP_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_status() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [ "$actual" -eq "$expected" ] || fail "$label: expected status $expected, got $actual"
}

assert_no_stdin_files() {
  local run_dir="$1"
  local found
  found="$(find "$run_dir" -maxdepth 1 -type f -name 'a2a-stdin.*' -print -quit)"
  [ -z "$found" ] || fail "stdin capture was left behind: $found"
}

make_executable() {
  chmod 0755 "$1"
}

echo "[0/4] shell syntax and maintenance safety gate"
bash -n \
  "$ROOT/scripts/setup-linux-vps.sh" \
  "$ROOT/scripts/upgrade-linux-runtime.sh" \
  "$ROOT/scripts/install-auto-discovery-linux.sh" \
  "$ROOT/scripts/watchdog-linux.sh" \
  "$ROOT/scripts/health-check-linux.sh" \
  "$ROOT/tools/codex-a2a-wrapper.sh"
node --check "$ROOT/tools/a2a-auto-discovery.cjs"
grep -q 'TARGET_ONCHAINOS_VERSION="4.2.6"' "$ROOT/scripts/upgrade-linux-runtime.sh" || \
  fail "runtime upgrade does not pin OnchainOS 4.2.6"
grep -q 'TARGET_A2A_VERSION="0.1.9"' "$ROOT/scripts/upgrade-linux-runtime.sh" || \
  fail "runtime upgrade does not pin A2A Node 0.1.9"
grep -q 'TARGET_SKILLS_COMMIT="93a2841501cde295f26af026d9c3a33efd42fd49"' \
  "$ROOT/scripts/upgrade-linux-runtime.sh" || fail "runtime upgrade does not pin the OKX skills commit"
grep -q 'onchainos-skills/tree/${TARGET_SKILLS_TAG}' "$ROOT/scripts/upgrade-linux-runtime.sh" || \
  fail "runtime upgrade does not install from the verified skills tag"
grep -q 'HOME="$release/installer-home"' "$ROOT/scripts/upgrade-linux-runtime.sh" || \
  fail "runtime upgrade does not isolate skills installer writes from the live home"
grep -q 'HOME="$skills_stage/home"' "$ROOT/scripts/setup-linux-vps.sh" || \
  fail "bootstrap does not isolate skills installer writes from the live home"
grep -q 'onchainos-skills/tree/${SKILLS_TAG}' "$ROOT/scripts/setup-linux-vps.sh" || \
  fail "bootstrap does not install from the verified skills tag"
grep -q 'OnUnitActiveSec=1h' "$ROOT/scripts/setup-linux-vps.sh" || \
  fail "bootstrap does not install the hourly discovery timer"
grep -q 'never call apply' "$ROOT/scripts/install-auto-discovery-linux.sh" || \
  fail "discovery installer does not document the no-direct-apply boundary"
grep -q 'OKX_A2A_ALLOW_LEGACY_BASELINE' "$ROOT/scripts/upgrade-linux-runtime.sh" || \
  fail "runtime upgrade does not guard legacy baseline migration"
grep -q 'legacy-skill-existed=' "$ROOT/scripts/upgrade-linux-runtime.sh" || \
  fail "runtime upgrade does not record legacy skill absence for rollback"
for directive in \
  'PrivateDevices=true' \
  'ProtectClock=true' \
  'ProtectHostname=true' \
  'ProtectKernelModules=true' \
  'CapabilityBoundingSet='; do
  if grep -Fqx "$directive" "$ROOT/scripts/setup-linux-vps.sh"; then
    fail "user systemd unit includes VPS-incompatible directive: $directive"
  fi
done
for directive in \
  'UMask=0077' \
  'NoNewPrivileges=true' \
  'PrivateTmp=true' \
  'ProtectSystem=full' \
  'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6'; do
  grep -Fqx "$directive" "$ROOT/scripts/setup-linux-vps.sh" || \
    fail "user systemd unit is missing verified hardening: $directive"
done
set +e
AGENT_ID=424242 OKX_A2A_BASE="$TMP_ROOT/not-initialized" \
  "$ROOT/scripts/upgrade-linux-runtime.sh" >/dev/null 2>&1
status=$?
set -e
assert_status 1 "$status" "explicit maintenance opt-in gate"

set +e
AGENT_ID=424242 OKX_A2A_BASE="$TMP_ROOT/not-initialized" \
  "$ROOT/scripts/install-auto-discovery-linux.sh" >/dev/null 2>&1
status=$?
set -e
assert_status 1 "$status" "auto-discovery explicit maintenance opt-in gate"

echo "[1/4] wrapper exit semantics and stdin cleanup"
WRAPPER_HOME="$TMP_ROOT/wrapper-home"
WRAPPER_BASE="$TMP_ROOT/wrapper-base"
mkdir -p "$WRAPPER_HOME" "$WRAPPER_BASE/bin"

cat >"$WRAPPER_BASE/bin/a2a-fast-handler.cjs" <<'EOF'
#!/usr/bin/env node
const fs = require("node:fs");
const input = fs.readFileSync(0, "utf8");
if (input.length > 0 && process.env.MODE_OUT) {
  fs.writeFileSync(process.env.MODE_OUT, String(fs.fstatSync(0).mode & 0o777));
}
const raw = input.length > 0 ? process.env.FAST_STDIN_STATUS : process.env.FAST_ARG_STATUS;
const status = Number(raw ?? "64");
process.exit(Number.isInteger(status) ? status : 64);
EOF
make_executable "$WRAPPER_BASE/bin/a2a-fast-handler.cjs"

cat >"$TMP_ROOT/real-codex.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$REAL_ARGS_OUT"
cat >"$REAL_STDIN_OUT"
EOF
make_executable "$TMP_ROOT/real-codex.sh"

REAL_ARGS_OUT="$TMP_ROOT/real-args"
REAL_STDIN_OUT="$TMP_ROOT/real-stdin"
MODE_OUT="$TMP_ROOT/stdin-mode"
export REAL_ARGS_OUT REAL_STDIN_OUT MODE_OUT

set +e
FAST_ARG_STATUS=0 OKX_A2A_BASE="$WRAPPER_BASE" HOME="$WRAPPER_HOME" \
  OKX_A2A_REAL_CODEX_COMMAND="$TMP_ROOT/real-codex.sh" \
  "$ROOT/tools/codex-a2a-wrapper.sh" --sandbox exec test </dev/null
status=$?
set -e
assert_status 0 "$status" "fast handler success"
[ ! -e "$REAL_ARGS_OUT" ] || fail "real Codex ran after fast-handler success"

set +e
printf '%s' '{"event":"test"}' | FAST_ARG_STATUS=70 OKX_A2A_BASE="$WRAPPER_BASE" HOME="$WRAPPER_HOME" \
  OKX_A2A_REAL_CODEX_COMMAND="$TMP_ROOT/real-codex.sh" \
  "$ROOT/tools/codex-a2a-wrapper.sh" --sandbox exec test
status=$?
set -e
assert_status 70 "$status" "non-fallback argument failure"
[ ! -e "$REAL_ARGS_OUT" ] || fail "real Codex ran after non-64 argument failure"

set +e
printf '%s' '{"event":"handled"}' | FAST_ARG_STATUS=64 FAST_STDIN_STATUS=0 \
  OKX_A2A_BASE="$WRAPPER_BASE" HOME="$WRAPPER_HOME" \
  OKX_A2A_REAL_CODEX_COMMAND="$TMP_ROOT/real-codex.sh" \
  "$ROOT/tools/codex-a2a-wrapper.sh" --sandbox exec test
status=$?
set -e
assert_status 0 "$status" "stdin fast-handler success"
case "$(uname -s)" in
  MINGW*|MSYS*) ;;
  *) [ "$(cat "$MODE_OUT")" = "384" ] || fail "stdin capture mode was not 0600" ;;
esac
assert_no_stdin_files "$WRAPPER_BASE/run"

set +e
printf '%s' '{"event":"stop"}' | FAST_ARG_STATUS=64 FAST_STDIN_STATUS=75 \
  OKX_A2A_BASE="$WRAPPER_BASE" HOME="$WRAPPER_HOME" \
  OKX_A2A_REAL_CODEX_COMMAND="$TMP_ROOT/real-codex.sh" \
  "$ROOT/tools/codex-a2a-wrapper.sh" --sandbox exec test
status=$?
set -e
assert_status 75 "$status" "non-fallback stdin failure"
[ ! -e "$REAL_ARGS_OUT" ] || fail "real Codex ran after non-64 stdin failure"
assert_no_stdin_files "$WRAPPER_BASE/run"

payload='{"event":"fallback"}'
set +e
printf '%s' "$payload" | FAST_ARG_STATUS=64 FAST_STDIN_STATUS=64 \
  OKX_A2A_BASE="$WRAPPER_BASE" HOME="$WRAPPER_HOME" \
  OKX_A2A_REAL_CODEX_COMMAND="$TMP_ROOT/real-codex.sh" \
  "$ROOT/tools/codex-a2a-wrapper.sh" --sandbox exec test
status=$?
set -e
assert_status 0 "$status" "explicit Codex fallback"
[ "$(cat "$REAL_STDIN_OUT")" = "$payload" ] || fail "real Codex did not receive the captured stdin"
assert_no_stdin_files "$WRAPPER_BASE/run"

echo "[2/4] watchdog strict counts and single-instance gate"
WATCH_HOME="$TMP_ROOT/watch-home"
WATCH_BASE="$TMP_ROOT/watch-base"
CALL_LOG="$TMP_ROOT/a2a-calls"
mkdir -p "$WATCH_HOME/.local/bin" "$WATCH_BASE/bin" "$WATCH_BASE/guard-bin"

cat >"$WATCH_HOME/.local/bin/flock" <<'EOF'
#!/usr/bin/env bash
exit "${MOCK_FLOCK_STATUS:-0}"
EOF
make_executable "$WATCH_HOME/.local/bin/flock"

cat >"$WATCH_HOME/.local/bin/okx-a2a" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_A2A_CALLS"
case "$*" in
  "--version") echo "0.1.8" ;;
  "daemon status") printf 'running pid=123\nready=true\n' ;;
  "agent refresh --json") printf '%s\n' "$MOCK_REFRESH_JSON" ;;
  "daemon start --no-autostart"|"daemon stop") ;;
  *) echo "unexpected okx-a2a arguments: $*" >&2; exit 64 ;;
esac
EOF
make_executable "$WATCH_HOME/.local/bin/okx-a2a"

mkdir -p "$WATCH_BASE/logs"
printf 'pre-existing watchdog log\n' >"$WATCH_BASE/logs/watchdog.log"
MOCK_A2A_CALLS="$CALL_LOG" MOCK_REFRESH_JSON='{"payload":{"agentCount":1,"activeClients":1}}' \
  WATCHDOG_LOG_MAX_BYTES=1 WATCHDOG_LOG_BACKUP_COUNT=5 \
  WATCHDOG_RUN_ONCE=1 AGENT_ID=424242 OKX_A2A_BASE="$WATCH_BASE" HOME="$WATCH_HOME" \
  "$ROOT/scripts/watchdog-linux.sh" >/dev/null
grep -q '"agentCount":1,"activeClients":1,"healthy":true,"reason":"ok"' \
  "$WATCH_BASE/run/watchdog-state.json" || fail "healthy watchdog state was not written"
[ -f "$WATCH_BASE/logs/watchdog.log.1" ] && [ -f "$WATCH_BASE/logs/watchdog.log.2" ] || \
  fail "watchdog log rotation did not retain the expected backups"

: >"$CALL_LOG"
MOCK_A2A_CALLS="$CALL_LOG" MOCK_REFRESH_JSON='{"payload":{"agentCount":2,"activeClients":2}}' \
  WATCHDOG_RUN_ONCE=1 AGENT_ID=424242 OKX_A2A_BASE="$WATCH_BASE" HOME="$WATCH_HOME" \
  "$ROOT/scripts/watchdog-linux.sh" >/dev/null
grep -q '"agentCount":2,"activeClients":2,"healthy":false,"reason":"agent_count_mismatch"' \
  "$WATCH_BASE/run/watchdog-state.json" || fail "agent-count mismatch was not rejected"
! grep -Eq '^daemon (stop|start --no-autostart)$' "$CALL_LOG" || \
  fail "configuration mismatch caused a daemon restart"

: >"$CALL_LOG"
MOCK_A2A_CALLS="$CALL_LOG" MOCK_REFRESH_JSON='{"payload":{"agentCount":1,"activeClients":0}}' \
  WATCHDOG_FAILURES_BEFORE_RESTART=1 WATCHDOG_RUN_ONCE=1 AGENT_ID=424242 \
  OKX_A2A_BASE="$WATCH_BASE" HOME="$WATCH_HOME" \
  "$ROOT/scripts/watchdog-linux.sh" >/dev/null
grep -qx 'daemon stop' "$CALL_LOG" || fail "restart did not stop the existing daemon"
grep -qx 'daemon start --no-autostart' "$CALL_LOG" || \
  fail "restart did not preserve the single no-autostart lifecycle owner"
! grep -q '^daemon restart$' "$CALL_LOG" || fail "restart used the autostart-capable shortcut"

: >"$CALL_LOG"
set +e
MOCK_FLOCK_STATUS=1 MOCK_A2A_CALLS="$CALL_LOG" MOCK_REFRESH_JSON='{}' \
  WATCHDOG_RUN_ONCE=1 AGENT_ID=424242 OKX_A2A_BASE="$WATCH_BASE" HOME="$WATCH_HOME" \
  "$ROOT/scripts/watchdog-linux.sh" >/dev/null 2>&1
status=$?
set -e
assert_status 75 "$status" "single-instance gate"
[ ! -s "$CALL_LOG" ] || fail "second watchdog instance called okx-a2a"

echo "[3/4] read-only health check command surface"
MOCK_REFRESH_JSON='{"payload":{"agentCount":1,"activeClients":1}}' \
  MOCK_A2A_CALLS="$CALL_LOG" WATCHDOG_RUN_ONCE=1 AGENT_ID=424242 \
  OKX_A2A_BASE="$WATCH_BASE" HOME="$WATCH_HOME" \
  "$ROOT/scripts/watchdog-linux.sh" >/dev/null

for runtime_file in \
  "$WATCH_BASE/bin/codex-a2a-wrapper.sh" \
  "$WATCH_BASE/bin/a2a-fast-handler.cjs" \
  "$WATCH_BASE/guard-bin/okx-a2a" \
  "$WATCH_BASE/guard-bin/npm"; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$runtime_file"
  make_executable "$runtime_file"
done
cp "$ROOT/tools/codex-a2a-wrapper.sh" "$WATCH_BASE/bin/codex-a2a-wrapper.sh"
make_executable "$WATCH_BASE/bin/codex-a2a-wrapper.sh"

cat >"$WATCH_HOME/.local/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf 'codex %s\n' "$*" >>"$MOCK_HEALTH_CALLS"
case "$*" in
  "--version") echo "codex-cli 1.0.0" ;;
  "login status") ;;
  *) exit 64 ;;
esac
EOF
make_executable "$WATCH_HOME/.local/bin/codex"

cat >"$WATCH_HOME/.local/bin/onchainos" <<'EOF'
#!/usr/bin/env bash
printf 'onchainos %s\n' "$*" >>"$MOCK_HEALTH_CALLS"
case "$*" in
  "--version") echo "onchainos 4.2.4" ;;
  "agent get-agents --agent-ids 424242") ;;
  *) exit 64 ;;
esac
EOF
make_executable "$WATCH_HOME/.local/bin/onchainos"

cat >"$WATCH_HOME/.local/bin/npm" <<'EOF'
#!/usr/bin/env bash
printf 'npm %s\n' "$*" >>"$MOCK_HEALTH_CALLS"
[ "$*" = "--version" ] || exit 64
echo "10.0.0"
EOF
make_executable "$WATCH_HOME/.local/bin/npm"

cat >"$WATCH_HOME/.local/bin/stat" <<'EOF'
#!/usr/bin/env bash
case "${*: -1}" in
  */watchdog-state.json) echo 600 ;;
  */run) echo 700 ;;
  *) /usr/bin/stat "$@" ;;
esac
EOF
make_executable "$WATCH_HOME/.local/bin/stat"

HEALTH_CALL_LOG="$TMP_ROOT/health-calls"
: >"$HEALTH_CALL_LOG"
: >"$CALL_LOG"
MOCK_HEALTH_CALLS="$HEALTH_CALL_LOG" MOCK_A2A_CALLS="$CALL_LOG" \
  AGENT_ID=424242 OKX_A2A_BASE="$WATCH_BASE" HOME="$WATCH_HOME" \
  OKX_A2A_AI_CODEX_COMMAND="$WATCH_BASE/bin/codex-a2a-wrapper.sh" \
  OKX_A2A_REAL_CODEX_COMMAND="$WATCH_HOME/.local/bin/codex" \
  "$ROOT/scripts/health-check-linux.sh" >/dev/null

if grep -Eiq 'preflight|switch-runtime|agent refresh|setup|doctor|xmtp-send' "$HEALTH_CALL_LOG" "$CALL_LOG"; then
  fail "read-only health check invoked a maintenance or outbound command"
fi

echo "PASS: Linux wrapper, watchdog, and read-only health checks"
