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

# Run a single test in the background. Records status + output to
# RESULTS_DIR. Collected later by finalize_tests. Each test is already
# an independent JVEEditor process, so no shared-state risk from
# parallelizing — only CPU contention.
launch_test() {
  local name="$1"
  shift
  local tmp_out="$RESULTS_DIR/$name.out"
  (
    if "$@" >"$tmp_out" 2>&1; then
      echo "PASS" > "$RESULTS_DIR/$name.status"
    else
      echo "FAIL" > "$RESULTS_DIR/$name.status"
    fi
  ) &
}

# Collect results for a set of previously-launched tests.
collect_results() {
  local names=("$@")
  for name in "${names[@]}"; do
    local status
    status="$(cat "$RESULTS_DIR/$name.status" 2>/dev/null || echo "FAIL")"
    if [[ "$status" == "PASS" ]]; then
      echo "[integration] ✓ $name"
      PASS=$((PASS+1))
    else
      echo "[integration] ✗ $name"
      FAIL=$((FAIL+1))
      FAILED_NAMES+=("$name")
      cat "$RESULTS_DIR/$name.out" >&2
    fi
  done
}

# ─── Phase 1: timing-sensitive batches (paired parallelism) ────────────
# These tests assert on wall-clock latency (e.g. playback cadence p95 ≤ 80ms).
# Full N-way parallelism with other tests causes tail-latency flakes, but
# running just the three perf batches together (3 processes on a machine
# with ≥4 cores) stays inside their timing budgets. Verified: pair
# (batch_playback + batch_codec) completes in 37s and passes.
echo "[integration] Phase 1: timing-sensitive batches (paired parallel)..."
PERF_BATCH_NAMES=(batch_playback batch_codec test_playback_av_sync_offset)
launch_test "batch_playback"                 "$BINARY" --test "$INTEG_DIR/batch_playback.lua"
launch_test "batch_codec"                    "$BINARY" --test "$INTEG_DIR/batch_codec.lua"
launch_test "test_playback_av_sync_offset"   "$BINARY" --test "$INTEG_DIR/test_playback_av_sync_offset.lua"
wait
collect_results "${PERF_BATCH_NAMES[@]}"

# ─── Phase 2: non-timing-sensitive, run in parallel ───────────────────
echo "[integration] Phase 2: other batches + UI tests (parallel)..."
PARALLEL_NAMES=()
launch_p() {
  PARALLEL_NAMES+=("$1")
  launch_test "$@"
}

launch_p "batch_waveform" "$BINARY" --test "$INTEG_DIR/batch_waveform.lua"
launch_p "batch_editing"  "$BINARY" --test "$INTEG_DIR/batch_editing.lua"

# Slow tests (optional)
if [[ "$RUN_SLOW" == "1" ]]; then
  if [[ -f "$INTEG_DIR/test_tmb_bwf_offset.lua" ]]; then
    launch_p "test_tmb_bwf_offset" "$BINARY" --test "$INTEG_DIR/test_tmb_bwf_offset.lua"
  fi
else
  SKIP=$((SKIP+1))
fi

# UI tests — each is its own process, fine to run alongside non-perf batches.
for t in \
  test_zstd_bindings.lua \
  test_layout_sanity.lua \
  test_widget_lifecycle.lua \
  test_keyboard_qshortcut_integration.lua \
  test_floating_window_key_isolation.lua \
  test_tab_order_restore.lua \
  test_codec_status_on_startup.lua \
  fs_watcher_media_status.lua \
  test_tmb_content_rewrite_invalidation.lua \
  test_tmb_restore_after_offline.lua \
  test_tmb_audio_content_rewrite_invalidation.lua \
  test_tmb_mixed_audio_content_rewrite.lua \
  test_tmb_invalidate_on_offline_flip.lua \
  test_monitor_refresh_ordering.lua \
  test_tmb_audio_unbeeps_on_reconnect.lua \
  test_inspector_set_value_undo.lua \
  test_inspector_focus_scroll.lua \
  test_peak_gen_admission.lua \
  test_reader_audio_only.lua \
  test_peak_cache_mtime_fractional.lua \
  test_peak_cache_coverage_regen.lua \
  test_relink_tc_resync.lua \
  test_source_tab_rekey_no_orphan.lua \
  test_set_mark_and_trim_if_clip_routes_to_trim.lua \
  test_show_source_tab.lua \
  test_show_source_tab_empty_blanks_body.lua \
  test_source_tab_and_viewer_set_transport_target.lua \
  test_source_viewer_signal.lua \
  test_source_viewer_load_clip.lua \
  test_source_viewer_publishes_selection.lua \
  test_match_frame.lua \
  test_match_frame_partial_and_offline.lua \
  test_go_to_next_prev_edit.lua \
  test_timeline_edit_navigation.lua
do
  if [[ -f "$INTEG_DIR/$t" ]]; then
    launch_p "$t" "$BINARY" --test "$INTEG_DIR/$t"
  fi
done

wait
collect_results "${PARALLEL_NAMES[@]}"

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
