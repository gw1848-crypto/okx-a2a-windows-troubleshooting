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

STDIN_FILE=""
if [ "${1:-}" = "exec" ] && [ ! -t 0 ]; then
  STDIN_FILE="$(mktemp "$BASE/run/a2a-stdin.XXXXXX")"
  cat > "$STDIN_FILE"
  if [ -s "$STDIN_FILE" ] && [ -x "$BASE/bin/a2a-fast-handler.cjs" ]; then
    set +e
    node "$BASE/bin/a2a-fast-handler.cjs" "$@" < "$STDIN_FILE"
    FAST_STATUS=$?
    set -e
    if [ "$FAST_STATUS" -eq 0 ]; then
      rm -f "$STDIN_FILE"
      exit 0
    fi
  fi
  exec "$REAL_CODEX" "$@" < "$STDIN_FILE"
fi

exec "$REAL_CODEX" "$@"
