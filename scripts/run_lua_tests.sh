#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="${ROOT_DIR}/tests"

# Ensure temp root exists for all tests
mkdir -p /tmp/jve

if ! command -v luajit >/dev/null 2>&1; then
  echo "[lua-tests] luajit is not installed or not on PATH." >&2
  echo "[lua-tests] Install LuaJIT (e.g., brew install luajit) before running the build." >&2
  exit 1
fi

if [[ -z "${JVE_SQLITE3_PATH:-}" ]]; then
  candidate_paths=(
    "/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib"
    "/usr/local/opt/sqlite/lib/libsqlite3.dylib"
    "/usr/local/lib/libsqlite3.dylib"
    "/usr/local/lib/libsqlite3.so"
    "/usr/lib/libsqlite3.dylib"
    "/usr/lib/libsqlite3.so"
    "/lib/x86_64-linux-gnu/libsqlite3.so"
    "/lib64/libsqlite3.so"
  )

  for candidate in "${candidate_paths[@]}"; do
    if [[ -f "${candidate}" ]]; then
      export JVE_SQLITE3_PATH="${candidate}"
      echo "[lua-tests] Using libsqlite3 at ${candidate}"
      break
    fi
  done
fi

# Ensure Lua can locate project modules.
export LUA_PATH="${ROOT_DIR}/src/lua/?.lua;${ROOT_DIR}/src/lua/?/init.lua;${TEST_DIR}/?.lua;${TEST_DIR}/?/init.lua;;"
export LUA_CPATH=";;"

# Validate that the SQLite binding can load before running every test.
if ! luajit -e "require('core.sqlite3')" >/dev/null 2>&1; then
  echo "[lua-tests] Failed to load SQLite3 FFI binding (core.sqlite3)." >&2
  echo "[lua-tests] Tried default library paths${JVE_SQLITE3_PATH:+ (currently '${JVE_SQLITE3_PATH}')}." >&2
  echo "[lua-tests] Set JVE_SQLITE3_PATH to the full path of your libsqlite3 shared library if it lives elsewhere." >&2
  exit 1
fi

# Collect test files (sorted) in a Bash-compatible way even on macOS Bash 3.2
LUA_TESTS=()
while IFS= read -r test_path; do
  LUA_TESTS+=("${test_path}")
done < <(find "${TEST_DIR}" -maxdepth 1 -type f -name 'test_*.lua' | sort)

if [[ ${#LUA_TESTS[@]} -eq 0 ]]; then
  echo "[lua-tests] No Lua test scripts found under ${TEST_DIR}."
  exit 0
fi

echo "[lua-tests] Running ${#LUA_TESTS[@]} Lua test(s)..."

for test_file in "${LUA_TESTS[@]}"; do
  test_name="$(basename "${test_file}")"
  echo "[lua-tests] → ${test_name}"
  (cd "${TEST_DIR}" && luajit "${test_name}")
done

echo "[lua-tests] All Lua tests passed."
