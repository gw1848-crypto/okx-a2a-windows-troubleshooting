#!/usr/bin/env bash
set -euo pipefail

# Anything captured from an inbound task can contain customer data. Keep new
# directories and temporary files private even when the caller has a loose
# login-shell umask.
umask 077

BASE="${OKX_A2A_BASE:-$HOME/.okx-agent-task}"
CODEX_HOME_DIR="${OKX_A2A_CODEX_HOME:-$BASE/codex-home}"
SQLITE_HOME_DIR="${OKX_A2A_CODEX_SQLITE_HOME:-$CODEX_HOME_DIR/sqlite}"
FAST_FALLBACK_STATUS=64
STDIN_FILE=""

mkdir -p "$CODEX_HOME_DIR" "$SQLITE_HOME_DIR" "$BASE/guard-bin" "$BASE/run" "$BASE/logs"
chmod 0700 "$CODEX_HOME_DIR" "$SQLITE_HOME_DIR" "$BASE/guard-bin" "$BASE/run" "$BASE/logs"

cleanup_stdin_file() {
  if [ -n "$STDIN_FILE" ]; then
    rm -f -- "$STDIN_FILE"
    STDIN_FILE=""
  fi
}

trap cleanup_stdin_file EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

export CODEX_HOME="$CODEX_HOME_DIR"
export CODEX_SQLITE_HOME="$SQLITE_HOME_DIR"
export PATH="$BASE/guard-bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

REAL_CODEX="${OKX_A2A_REAL_CODEX_COMMAND:-}"
if [ -z "$REAL_CODEX" ]; then
  REAL_CODEX="$(command -v codex || true)"
fi

if [ -z "$REAL_CODEX" ] || [ ! -x "$REAL_CODEX" ]; then
  echo "A2A Codex wrapper: codex was not found or is not executable." >&2
  exit 127
fi

IS_CODEX_EXEC=false
for arg in "$@"; do
  if [ "$arg" = "exec" ]; then
    IS_CODEX_EXEC=true
    break
  fi
done

if [ "$IS_CODEX_EXEC" = "true" ] && [ -x "$BASE/bin/a2a-fast-handler.cjs" ]; then
  # The daemon may pass the inbound envelope either as exec arguments or via stdin.
  # Inspect arguments first without consuming stdin; this is the common node runtime path.
  set +e
  node "$BASE/bin/a2a-fast-handler.cjs" "$@" </dev/null
  FAST_ARG_STATUS=$?
  set -e
  if [ "$FAST_ARG_STATUS" -eq 0 ]; then
    exit 0
  fi
  if [ "$FAST_ARG_STATUS" -ne "$FAST_FALLBACK_STATUS" ]; then
    exit "$FAST_ARG_STATUS"
  fi

  if [ ! -t 0 ]; then
    STDIN_FILE="$(mktemp "$BASE/run/a2a-stdin.XXXXXX")"
    # Stdin is normally delivered immediately by okx-a2a; timeout prevents health probes from hanging.
    timeout 2s cat > "$STDIN_FILE" || true
    if [ -s "$STDIN_FILE" ]; then
      set +e
      node "$BASE/bin/a2a-fast-handler.cjs" "$@" < "$STDIN_FILE"
      FAST_STDIN_STATUS=$?
      set -e
      if [ "$FAST_STDIN_STATUS" -eq 0 ]; then
        exit 0
      fi
      if [ "$FAST_STDIN_STATUS" -ne "$FAST_FALLBACK_STATUS" ]; then
        exit "$FAST_STDIN_STATUS"
      fi

      # Open the captured input first, unlink its directory entry, then make
      # it Codex's stdin. The anonymous file survives only until Codex closes
      # it, so exec cannot leave customer content in BASE/run.
      exec 9<"$STDIN_FILE"
      rm -f -- "$STDIN_FILE"
      STDIN_FILE=""
      exec "$REAL_CODEX" "$@" <&9 9<&-
    fi
    cleanup_stdin_file
  fi
fi

exec "$REAL_CODEX" "$@"
