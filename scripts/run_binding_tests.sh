#!/usr/bin/env bash
set -euo pipefail

# Binding test runner — runs Lua test scripts inside JVEEditor binary
# so they get real C++ bindings (qt_xml_parse, qt_json_encode, etc.)
# but don't need a full UI environment.
#
# Usage: ./scripts/run_binding_tests.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$ROOT_DIR/build/bin/JVEEditor"
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
PASS=0
FAIL=0

if [[ $TOTAL -eq 0 ]]; then
  echo "No binding tests found in $BIND_DIR" >&2
  exit 2
fi

echo "[binding-tests] Running $TOTAL binding test(s)..."

for t in "${TESTS[@]}"; do
  base="$(basename "$t")"
  echo "[binding-tests] → $base"

  tmp_out="$(mktemp -t binding_test_out.XXXXXX)"
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
echo "Binding: PASSED=$PASS FAILED=$FAIL"
echo "------------------------------------"

if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
