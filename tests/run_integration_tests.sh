#!/usr/bin/env bash
set -euo pipefail

# Integration test runner — uses batch mode (single JVEEditor process per group)
# for most tests. UI tests that need isolated Qt windows run in separate processes.
#
# Batch groups (single process each):
#   batch_playback  — 13 TMB/playback tests
#   batch_codec     — 4 codec/media tests
#   batch_waveform  — 3 waveform/peak tests
#   batch_editing   — 2 editing operation tests
#
# Separate processes:
#   test_layout_sanity, test_widget_lifecycle, test_keyboard_qshortcut_integration,
#   test_tab_order_restore, test_codec_status_on_startup
#
# Usage: ./tests/run_integration_tests.sh
#   RUN_SLOW_TESTS=1 to include slow tests (test_tmb_bwf_offset)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$ROOT_DIR/build/bin/JVEEditor"
INTEG_DIR="$ROOT_DIR/tests/integration"

if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: JVEEditor binary not found at $BINARY" >&2
  echo "       Run 'make -j4' first." >&2
  exit 2
fi

RUN_SLOW="${RUN_SLOW_TESTS:-0}"
RESULTS_DIR="$(mktemp -d -t integ_results.XXXXXX)"
PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()

run_test() {
  local name="$1"
  shift
  local tmp_out="$RESULTS_DIR/$name.out"

  if "$@" >"$tmp_out" 2>&1; then
    echo "[integration] ✓ $name"
    PASS=$((PASS+1))
  else
    echo "[integration] ✗ $name"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("$name")
    cat "$tmp_out" >&2
  fi
}

# ─── Batch groups (single JVEEditor process each) ─────────────────────

echo "[integration] Running batch groups..."

run_test "batch_playback" "$BINARY" --test "$INTEG_DIR/batch_playback.lua"
run_test "batch_codec"    "$BINARY" --test "$INTEG_DIR/batch_codec.lua"
run_test "batch_waveform" "$BINARY" --test "$INTEG_DIR/batch_waveform.lua"
run_test "batch_editing"  "$BINARY" --test "$INTEG_DIR/batch_editing.lua"

# ─── Tests that need isolated processes (FFI conflicts, etc) ──────────

run_test "test_playback_av_sync_offset" "$BINARY" --test "$INTEG_DIR/test_playback_av_sync_offset.lua"

# ─── Slow tests (optional) ────────────────────────────────────────────

if [[ "$RUN_SLOW" == "1" ]]; then
  if [[ -f "$INTEG_DIR/test_tmb_bwf_offset.lua" ]]; then
    run_test "test_tmb_bwf_offset" "$BINARY" --test "$INTEG_DIR/test_tmb_bwf_offset.lua"
  fi
else
  SKIP=$((SKIP+1))
fi

# ─── UI tests (separate process each — need isolated Qt windows) ──────

echo "[integration] Running UI tests (separate processes)..."

for t in \
  test_layout_sanity.lua \
  test_widget_lifecycle.lua \
  test_keyboard_qshortcut_integration.lua \
  test_floating_window_key_isolation.lua \
  test_tab_order_restore.lua \
  test_codec_status_on_startup.lua
do
  if [[ -f "$INTEG_DIR/$t" ]]; then
    run_test "$t" "$BINARY" --test "$INTEG_DIR/$t"
  fi
done

# ─── Results ──────────────────────────────────────────────────────────

rm -rf "$RESULTS_DIR"

echo "------------------------------------"
if [[ $SKIP -gt 0 ]]; then
  echo "Integration: PASSED=$PASS FAILED=$FAIL SKIPPED=$SKIP (set RUN_SLOW_TESTS=1 to include)"
else
  echo "Integration: PASSED=$PASS FAILED=$FAIL"
fi
echo "------------------------------------"

if [[ $FAIL -ne 0 ]]; then
  echo "Failed tests: ${FAILED_NAMES[*]}" >&2
  exit 1
fi
