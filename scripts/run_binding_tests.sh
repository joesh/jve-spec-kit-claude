#!/usr/bin/env bash
set -euo pipefail

# Binding test runner — runs Lua test scripts inside JVEEditor binary
# so they get real C++ bindings (qt_xml_parse, qt_json_encode, etc.)
# but don't need a full UI environment.
#
# Tests run in parallel for speed. Each gets its own JVEEditor process.
#
# Usage: ./scripts/run_binding_tests.sh
#   RUN_SLOW_TESTS=1 to include tests marked SLOW_TEST

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Binary location: prefer JVE_BINARY (set by cmake via $<TARGET_FILE:JVEEditor>
# in CMakeLists.txt's add_test invocation — always correct regardless of
# build dir or bundle vs raw layout). Fall back to BUILD_DIR-derived path
# for standalone script invocations.
BUILD_DIR="${BUILD_DIR:-build}"
BINARY="${JVE_BINARY:-$ROOT_DIR/$BUILD_DIR/bin/jve.app/Contents/MacOS/jve}"
BIND_DIR="$ROOT_DIR/tests/binding"

if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: JVEEditor binary not found at $BINARY" >&2
  echo "       Run 'make -j4' first." >&2
  exit 2
fi

mapfile -t TESTS < <(
  find "$BIND_DIR" -maxdepth 1 -type f -name 'test_*.lua' \
    -print | sort
)

TOTAL=${#TESTS[@]}

if [[ $TOTAL -eq 0 ]]; then
  echo "No binding tests found in $BIND_DIR" >&2
  exit 2
fi

RUN_SLOW="${RUN_SLOW_TESTS:-0}"
RESULTS_DIR="$(mktemp -d -t binding_results.XXXXXX)"

# Determine which tests to run vs skip
SKIP=0
RUN_TESTS=()
for t in "${TESTS[@]}"; do
  if [[ "$RUN_SLOW" != "1" ]] && head -3 "$t" | grep -q SLOW_TEST; then
    SKIP=$((SKIP+1))
    continue
  fi
  RUN_TESTS+=("$t")
done

echo "[binding-tests] Running ${#RUN_TESTS[@]} binding test(s) in parallel..."

# Launch all tests in parallel
for t in "${RUN_TESTS[@]}"; do
  base="$(basename "$t")"
  (
    tmp_out="$RESULTS_DIR/$base.out"
    if "$BINARY" --test "$t" >"$tmp_out" 2>&1; then
      echo "PASS" > "$RESULTS_DIR/$base.status"
    else
      echo "FAIL" > "$RESULTS_DIR/$base.status"
    fi
  ) &
done

wait

# Collect results
PASS=0
FAIL=0
FAILED_NAMES=()

for t in "${RUN_TESTS[@]}"; do
  base="$(basename "$t")"
  status="$(cat "$RESULTS_DIR/$base.status" 2>/dev/null || echo "FAIL")"
  if [[ "$status" == "PASS" ]]; then
    echo "[binding-tests] ✓ $base"
    PASS=$((PASS+1))
  else
    echo "[binding-tests] ✗ $base"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("$base")
    cat "$RESULTS_DIR/$base.out" >&2
  fi
done

# Cleanup temp dir
rm -rf "$RESULTS_DIR"

echo "------------------------------------"
if [[ $SKIP -gt 0 ]]; then
  echo "Binding: PASSED=$PASS FAILED=$FAIL SKIPPED=$SKIP (set RUN_SLOW_TESTS=1 to include)"
else
  echo "Binding: PASSED=$PASS FAILED=$FAIL"
fi
echo "------------------------------------"

if [[ $FAIL -ne 0 ]]; then
  echo "Failed tests: ${FAILED_NAMES[*]}" >&2
  exit 1
fi
