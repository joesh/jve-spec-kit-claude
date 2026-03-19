#!/usr/bin/env bash
set -euo pipefail

# Integration test runner — runs Lua test scripts inside JVEEditor binary
# so they get real C++ EMP bindings (no mocks).
#
# Usage: ./tests/run_integration_tests.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$ROOT_DIR/build/bin/JVEEditor"
INTEG_DIR="$ROOT_DIR/tests/integration"

if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: JVEEditor binary not found at $BINARY" >&2
  echo "       Run 'make -j4' first." >&2
  exit 2
fi

mapfile -t TESTS < <(
  find "$INTEG_DIR" -maxdepth 1 -type f -name 'test_*.lua' \
    -print | sort
)

TOTAL=${#TESTS[@]}
PASS=0
FAIL=0

if [[ $TOTAL -eq 0 ]]; then
  echo "No integration tests found in $INTEG_DIR" >&2
  exit 2
fi

echo "[integration] Running $TOTAL integration test(s)..."

RUN_SLOW="${RUN_SLOW_TESTS:-0}"
SKIP=0

for t in "${TESTS[@]}"; do
  base="$(basename "$t")"

  # Skip tests marked -- SLOW unless RUN_SLOW_TESTS=1
  if [[ "$RUN_SLOW" != "1" ]] && head -3 "$t" | grep -q SLOW_TEST; then
    SKIP=$((SKIP+1))
    continue
  fi

  echo "[integration] → $base"

  tmp_out="$(mktemp -t integ_test_out.XXXXXX)"
  if "$BINARY" --test "$t" >"$tmp_out" 2>&1; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "  FAILED: $base"
    cat "$tmp_out" >&2
  fi

  rm -f "$tmp_out"
done

echo "------------------------------------"
if [[ $SKIP -gt 0 ]]; then
  echo "Integration: PASSED=$PASS FAILED=$FAIL SKIPPED=$SKIP (set RUN_SLOW_TESTS=1 to include)"
else
  echo "Integration: PASSED=$PASS FAILED=$FAIL"
fi
echo "------------------------------------"

if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
