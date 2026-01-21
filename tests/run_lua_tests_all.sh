#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$ROOT_DIR/tests"
HARNESS="$TEST_DIR/test_harness.lua"

# Run from tests directory to match CMake lua_tests target behavior
cd "$TEST_DIR"

export LUA_PATH="$ROOT_DIR/src/lua/?.lua;$ROOT_DIR/src/lua/?/init.lua;$ROOT_DIR/tests/?.lua;$ROOT_DIR/tests/?/init.lua;;${LUA_PATH:-}"
export LUA_CPATH="$ROOT_DIR/build/?.so;$ROOT_DIR/build/?/?.so;$ROOT_DIR/build/src/?.so;;${LUA_CPATH:-}"

if [[ ! -f "$HARNESS" ]]; then
  echo "ERROR: missing test harness at $HARNESS" >&2
  exit 2
fi

OUT_FILE="$ROOT_DIR/test-errors.txt"
: > "$OUT_FILE"

mapfile -t TESTS < <(
  find "$TEST_DIR" -maxdepth 1 -type f -name 'test_*.lua' \
    ! -name 'test_harness.lua' \
    -print | sort
)

TOTAL=${#TESTS[@]}
PASS=0
FAIL=0

if [[ $TOTAL -eq 0 ]]; then
  echo "No tests found in $TEST_DIR" >&2
  exit 2
fi

echo "[lua-tests] Running $TOTAL Lua test(s)..."

for t in "${TESTS[@]}"; do
  base="$(basename "$t")"
  echo "[lua-tests] → $base"

  tmp_out="$(mktemp -t lua_test_out.XXXXXX)"
  # Run each test in its own LuaJIT process via the harness so failures don't abort the suite.
  if luajit test_harness.lua "$base" >"$tmp_out" 2>&1; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    {
      echo "========================================"
      echo "FAILED: $base"
      echo "========================================"
      cat "$tmp_out"
      echo
    } >> "$OUT_FILE"

    cat "$tmp_out" >&2
  fi

  rm -f "$tmp_out"
done

echo "------------------------------------"
echo "Total PASSED: $PASS, FAILED: $FAIL"
echo "------------------------------------"

echo "[lua-tests] Wrote failing test output to: $OUT_FILE"

if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
