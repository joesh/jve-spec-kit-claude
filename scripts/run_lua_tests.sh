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

# Collect test files (sorted) in a Bash-compatible way even on macOS Bash 3.2.
# Sweeps the top-level tests/ AND tests/synthetic/lua/ (pure-Lua unit tests).
# synthetic/binding and synthetic/integration have their own runners
# (run_binding_tests.sh, run_integration_tests.sh) — do NOT add them here.
LUA_TESTS=()
while IFS= read -r test_path; do
  LUA_TESTS+=("${test_path}")
done < <( { find "${TEST_DIR}" -maxdepth 1 -type f -name 'test_*.lua'; \
            find "${TEST_DIR}/synthetic/lua" -type f -name 'test_*.lua'; } | sort )

# Sentinels intentionally RED until a tracked cleanup lands — excluded from
# the green gate (run them directly to check progress; see each test's header).
KNOWN_RED=( "test_no_legacy_identifiers.lua" )
is_known_red() {
  local base="$1" r
  for r in "${KNOWN_RED[@]}"; do [[ "${base}" == "${r}" ]] && return 0; done
  return 1
}

if [[ ${#LUA_TESTS[@]} -eq 0 ]]; then
  echo "[lua-tests] No Lua test scripts found under ${TEST_DIR}."
  exit 0
fi

RUN_SLOW="${RUN_SLOW_TESTS:-0}"
SKIP=0
RED_SKIP=0

echo "[lua-tests] Running ${#LUA_TESTS[@]} Lua test(s)..."

# Filter out known-RED sentinels and (unless RUN_SLOW_TESTS=1) SLOW tests.
RUN_TESTS=()
for test_file in "${LUA_TESTS[@]}"; do
  if is_known_red "$(basename "${test_file}")"; then
    RED_SKIP=$((RED_SKIP+1))
    continue
  fi
  if [[ "$RUN_SLOW" != "1" ]] && head -3 "${test_file}" | grep -q SLOW_TEST; then
    SKIP=$((SKIP+1))
    continue
  fi
  RUN_TESTS+=("${test_file}")
done

# Run tests in parallel — each is a fresh luajit process with isolated
# state (its own /tmp/jve/test_*.db). Bash 3.2 on macOS doesn't have
# `wait -n`, so collect exit codes into a file and tally at the end.
PARALLEL_JOBS="${LUA_TEST_JOBS:-4}"
RESULTS_DIR="$(mktemp -d -t lua_results.XXXXXX)"

# test_harness resolves test paths relative to tests/, so pass the path
# relative to TEST_DIR (e.g. synthetic/lua/test_foo.lua), not the basename.
# Status/log filenames sanitize the relative path so nested dirs can't collide.
run_one() {
  local test_file="$1"
  local rel="${test_file#${TEST_DIR}/}"
  local safe_name="${rel//\//_}"
  local out_log="${RESULTS_DIR}/${safe_name}.log"
  if (cd "${TEST_DIR}" && luajit test_harness.lua "${rel}") > "${out_log}" 2>&1; then
    echo "PASS" > "${RESULTS_DIR}/${safe_name}.status"
  else
    echo "FAIL" > "${RESULTS_DIR}/${safe_name}.status"
  fi
  echo "[lua-tests] → ${rel}"
}
export -f run_one
export TEST_DIR RESULTS_DIR LUA_PATH LUA_CPATH JVE_SQLITE3_PATH

printf '%s\n' "${RUN_TESTS[@]}" \
  | xargs -P "${PARALLEL_JOBS}" -I '{}' bash -c 'run_one "$@"' _ '{}'

# Tally results
FAIL_COUNT=0
for test_file in "${RUN_TESTS[@]}"; do
  rel="${test_file#${TEST_DIR}/}"
  safe_name="${rel//\//_}"
  status="$(cat "${RESULTS_DIR}/${safe_name}.status" 2>/dev/null || echo "FAIL")"
  if [[ "$status" != "PASS" ]]; then
    FAIL_COUNT=$((FAIL_COUNT+1))
    echo "[lua-tests] ✗ ${rel}" >&2
    cat "${RESULTS_DIR}/${safe_name}.log" >&2
  fi
done
rm -rf "${RESULTS_DIR}"

if [[ $FAIL_COUNT -gt 0 ]]; then
  echo "[lua-tests] ${FAIL_COUNT} Lua test(s) FAILED." >&2
  exit 1
fi

SUMMARY="[lua-tests] All Lua tests passed."
[[ $SKIP -gt 0 ]] && SUMMARY="${SUMMARY} (${SKIP} slow skipped; RUN_SLOW_TESTS=1 to include)"
[[ $RED_SKIP -gt 0 ]] && SUMMARY="${SUMMARY} (${RED_SKIP} known-RED sentinel(s) excluded)"
echo "${SUMMARY}"
