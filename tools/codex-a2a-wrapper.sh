#!/usr/bin/env bash
set -euo pipefail

BASE="${OKX_A2A_BASE:-$HOME/.okx-agent-task}"
CODEX_HOME_DIR="${OKX_A2A_CODEX_HOME:-$BASE/codex-home}"
SQLITE_HOME_DIR="${OKX_A2A_CODEX_SQLITE_HOME:-$CODEX_HOME_DIR/sqlite}"

mkdir -p "$CODEX_HOME_DIR" "$SQLITE_HOME_DIR" "$BASE/guard-bin" "$BASE/run" "$BASE/logs"

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
        rm -f "$STDIN_FILE"
        exit 0
      fi
      exec "$REAL_CODEX" "$@" < "$STDIN_FILE"
    fi
    rm -f "$STDIN_FILE"
  fi
fi

exec "$REAL_CODEX" "$@"
