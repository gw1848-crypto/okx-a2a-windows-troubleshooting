#!/usr/bin/env bash
set -euo pipefail

BASE="${OKX_A2A_BASE:-$HOME/.okx-agent-task}"
CODEX_HOME_DIR="${OKX_A2A_CODEX_HOME:-$BASE/codex-home}"
SQLITE_HOME_DIR="${OKX_A2A_CODEX_SQLITE_HOME:-$CODEX_HOME_DIR/sqlite}"

mkdir -p "$CODEX_HOME_DIR" "$SQLITE_HOME_DIR" "$BASE/guard-bin"

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

exec "$REAL_CODEX" "$@"
