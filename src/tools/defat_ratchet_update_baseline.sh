#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT_DIR/tools/defat_ratchet_baseline.txt"
TMP=$(mktemp)

# 1) command.create callsites outside command_manager/command.lua
#    (These are the old ceremony entry points.)
grep -RInE "\bcommand(_module)?\.create\(" "$ROOT_DIR/lua" \
  | grep -vE "^${ROOT_DIR}/lua/core/command\.lua:" \
  | grep -vE "^${ROOT_DIR}/lua/core/command_manager\.lua:" \
  > "$TMP" || true

# 2) set_parameter usage in UI paths
if [ -d "$ROOT_DIR/lua/ui" ]; then
  grep -RInE ":set_parameter\(" "$ROOT_DIR/lua/ui" >> "$TMP" || true
fi


# 3) get_parameter usage in command executors (post-Step-4 ratchet)
if [ -d "$ROOT_DIR/lua/core/commands" ]; then
  grep -RInE "\bget_parameter\(" "$ROOT_DIR/lua/core/commands" >> "$TMP" || true
fi


# Normalize + write
sort -u "$TMP" > "$OUT"
rm -f "$TMP"
echo "Wrote $OUT"
