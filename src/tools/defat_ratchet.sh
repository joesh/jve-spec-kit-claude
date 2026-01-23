#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
BASE="$ROOT_DIR/tools/defat_ratchet_baseline.txt"
TMP=$(mktemp)

if [ ! -f "$BASE" ]; then
  echo "Missing baseline: $BASE" >&2
  echo "Run: tools/defat_ratchet_update_baseline.sh" >&2
  exit 2
fi

# 1) command.create callsites outside command_manager/command.lua
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

sort -u "$TMP" > "$TMP.sorted"
rm -f "$TMP"

if ! diff -u "$BASE" "$TMP.sorted"; then
  echo "" >&2
  echo "Defat ratchet failed: new re-fat patterns were introduced." >&2
  echo "If intentional, regenerate baseline with tools/defat_ratchet_update_baseline.sh" >&2
  rm -f "$TMP.sorted"
  exit 1
fi

rm -f "$TMP.sorted"
