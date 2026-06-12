#!/usr/bin/env bash

set -euo pipefail

# VM dispatch is deferred to between Phase 1 and Phase 2.
# Phase 1 (timing-sensitive playback/codec tests) MUST run on the host —
# UTM does not pass VideoToolbox through, so every codec falls back to
# software decode in the VM and the cadence/drift assertions fail
# regardless of fixture choice. Phase 2 (non-timing-sensitive) dispatches
# to the VM when reachable, matching the existing fan-out model.
_VM_DISPATCH_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/_run_in_vm.sh"

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
# Binary location: prefer JVE_BINARY (set by cmake via $<TARGET_FILE:JVEEditor>
# in CMakeLists.txt's add_test invocation — always correct regardless of
# build dir or bundle vs raw layout). Fall back to BUILD_DIR-derived path
# for standalone script invocations.
BUILD_DIR="${BUILD_DIR:-build}"
BINARY="${JVE_BINARY:-$ROOT_DIR/$BUILD_DIR/bin/jve.app/Contents/MacOS/jve}"
INTEG_DIR="$ROOT_DIR/tests/synthetic/integration"

if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: JVEEditor binary not found at $BINARY" >&2
  echo "       Run 'make -j4' first." >&2
  exit 2
fi

RUN_SLOW="${RUN_SLOW_TESTS:-0}"
RESULTS_DIR="$(mktemp -d -t integ_results.XXXXXX)"
# Clean up scratch dir on any exit path. Phase 1's early-exit-on-fail and
# the VM-dispatch exec replace below would otherwise leave it behind.
trap 'rm -rf "$RESULTS_DIR"' EXIT
PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()

# Run a single test in the background. Records status + output to
# RESULTS_DIR. Collected later by finalize_tests. Each test is already
# an independent JVEEditor process, so no shared-state risk from
# parallelizing — only CPU contention.
#
# Per-test JVE_TEMPLATE_DIR: project_templates.get_template_path
# regenerates a shared .jvp in resources/templates/ on every open_fresh
# call. Parallel test processes racing through that produce "disk I/O
# error" / "no sequence found after identity update" failures.
# Per-test scratch dir isolates them.
launch_test() {
  local name="$1"
  shift
  local tmp_out="$RESULTS_DIR/$name.out"
  local template_dir="/tmp/jve/templates_${name}_$$"
  (
    if JVE_TEMPLATE_DIR="$template_dir" "$@" >"$tmp_out" 2>&1; then
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

# ─── Phase 1: timing-sensitive batches (paired parallelism, HOST ONLY) ─
# These tests assert on wall-clock latency (e.g. playback cadence p95 ≤ 80ms)
# and require VideoToolbox HW decode. UTM does not pass VideoToolbox through,
# so every codec falls back to software decode in the VM — playback rate
# drops below the cadence/drift budgets and the assertions fail regardless
# of fixture choice. Run on host only; when we are already re-exec'd inside
# the VM (Phase 2 dispatch), Phase 1 has already completed on the host.
#
# Full N-way parallelism with other tests causes tail-latency flakes, but
# running just the three perf batches together (3 processes on a machine
# with ≥4 cores) stays inside their timing budgets. Verified: pair
# (batch_playback + batch_codec) completes in 37s and passes.
if [ "${JVE_IN_VM:-0}" != "1" ]; then
  echo "[integration] Phase 1: timing-sensitive batches (host-local, paired parallel)..."
  PERF_BATCH_NAMES=(batch_playback batch_codec test_playback_av_sync_offset)
  launch_test "batch_playback"                 "$BINARY" --test "$INTEG_DIR/batch_playback.lua"
  launch_test "batch_codec"                    "$BINARY" --test "$INTEG_DIR/batch_codec.lua"
  launch_test "test_playback_av_sync_offset"   "$BINARY" --test "$INTEG_DIR/test_playback_av_sync_offset.lua"
  wait
  collect_results "${PERF_BATCH_NAMES[@]}"

  # Surface Phase 1 failures immediately. The VM re-exec below would otherwise
  # overwrite our exit code with Phase 2's, hiding host-only regressions.
  if [ "$FAIL" -gt 0 ]; then
    echo "[integration] Phase 1 had $FAIL failure(s); skipping Phase 2 dispatch" >&2
    echo "Failed tests: ${FAILED_NAMES[*]}" >&2
    exit 1
  fi
fi

# ─── Phase 2 dispatch: VM if reachable, else host ─────────────────────
# Sourcing _run_in_vm.sh re-execs this script on the guest with JVE_IN_VM=1,
# which gates Phase 1 above to a no-op (already done on host) and runs only
# the Phase 2 block below. Host process exits with the guest's status.
# When the VM is off/unreachable, sourcing falls through and Phase 2 runs
# locally.
. "$_VM_DISPATCH_SCRIPT"

# ─── Phase 2: non-timing-sensitive, run in parallel ───────────────────
echo "[integration] Phase 2: other batches + UI tests (parallel)..."
PARALLEL_NAMES=()
launch_p() {
  PARALLEL_NAMES+=("$1")
  launch_test "$@"
}

launch_p "batch_waveform" "$BINARY" --test "$INTEG_DIR/batch_waveform.lua"
launch_p "batch_editing"  "$BINARY" --test "$INTEG_DIR/batch_editing.lua"
launch_p "batch_timeline_render" "$BINARY" --test "$INTEG_DIR/batch_timeline_render.lua"

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
  test_drt_writer_file_roundtrip.lua \
  test_drt_round_trip_validator.lua \
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
  test_peak_gen_cancel_all_re_request.lua \
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
  test_timeline_edit_navigation.lua \
  test_go_to_edit_surfaces_playhead.lua \
  test_panel_maximize.lua \
  test_focus_manager.lua \
  test_media_status_bg_probe.lua \
  test_media_status_codec_error_persistence.lua \
  test_monitor_mark_bar_wheel.lua \
  test_source_zoom.lua \
  test_sequence_monitor.lua \
  test_sequence_monitor_no_orphan_engine.lua \
  test_tmb_audio_contract.lua \
  test_offline_frame_rendering.lua \
  test_playback_engine_log_tag.lua \
  test_012_inspector_lifecycle.lua \
  test_012_inspector_widget_state.lua \
  test_012_inspector_public_api.lua \
  test_012_collapsible_section.lua \
  test_playback_engine_contract.lua \
  test_decode_mode_command.lua \
  test_transport_contract.lua \
  test_transport_bootstrap_accessor.lua \
  test_transport_subscribes_to_signals.lua \
  test_transport_first_open_defaults_to_record.lua \
  test_audio_handover_contract.lua \
  test_playback_edit_invalidation.lua \
  test_av_handover_ordering.lua \
  test_audio_play_unfed_no_crash.lua \
  test_reverse_to_zero_playback.lua \
  test_reverse_clip_source_traversal.lua \
  test_controller_owns_audio_transport.lua \
  test_video_display_on_seek.lua \
  test_playback_transport_state_machine.lua \
  test_fullscreen_viewer.lua \
  test_edit_history_window_project_switch.lua \
  test_edit_source_popup_invariants.lua \
  test_playback_engine_filter.lua \
  test_playback_routes_to_displayed_tab.lua \
  test_mark_routing.lua \
  test_browser_activation_routes_through_commands.lua \
  test_scroll_persistence_reopen.lua \
  test_scroll_persistence_cold_start.lua \
  test_scroll_survives_tab_switch.lua \
  test_timeline_zoom_scroller.lua \
  test_clip_draw_stability.lua \
  test_drag_select_no_layout_jump.lua
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
