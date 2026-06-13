#!/usr/bin/env luajit
--- Regression: scrolling or zooming the timeline during playback must NOT
--- stop playback or seek the playhead.
---
--- Root cause: flush_state_to_db() is wired as the persist_callback for
--- viewport changes. It executes SetPlayhead with displayed_cache.playhead_position
--- (a stale pre-playback value). SetPlayhead emits playhead_changed, which
--- sequence_monitor hears and calls seek_to_frame(stale), stopping playback.
---
--- Fix: skip SetPlayhead in flush_state_to_db when data.state.is_playing is true.
--- The engine already persists the live playhead directly during playback (no signal).
---
--- Domain contract: while playing, viewport scroll/zoom must not affect playhead.
--- Observable: playhead_changed must NOT fire during a scroll when is_playing = true.

require("test_env")

_G.qt_create_single_shot_timer = function(_d, cb) if cb then cb() end end

print("=== test_scroll_during_playback_preserves_playhead.lua ===")

local database        = require("core.database")
local timeline_state  = require("ui.timeline.timeline_state")
local command_manager = require("core.command_manager")
local Signals         = require("core.signals")

local DB = "/tmp/jve/test_scroll_during_playback_preserves_playhead.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB))
local conn = database.get_connection()
conn:exec(require("import_schema"))

local now = os.time()
conn:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj1', 'Test', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        playhead_frame, view_start_frame, view_duration_frames,
        video_scroll_offset, audio_scroll_offset,
        created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Main', 'sequence', 24, 1, 48000, 1920, 1080,
        50, 0, 300, 0, 0, %d, %d);
]], now, now, now, now))

timeline_state.reset()
timeline_state.init("seq1", "proj1")
command_manager.init("seq1", "proj1")

-- Track every playhead_changed emission
local playhead_changed_log = {}
local token = Signals.connect("playhead_changed", function(seq_id, frame)
    table.insert(playhead_changed_log, { seq_id = seq_id, frame = frame })
end)

-- ── Case 1: NOT playing — scroll must flush state (including SetPlayhead) ──
-- This verifies the baseline: when parked, flush works normally.
local n_before = #playhead_changed_log
timeline_state.set_viewport_start_time(10)
assert(#playhead_changed_log > n_before, string.format(
    "When not playing, scrolling must trigger SetPlayhead (flush_state_to_db). "
    .. "Expected playhead_changed to fire; log had %d entries before, %d after.",
    n_before, #playhead_changed_log))
print(string.format("  ✓ parked: playhead_changed fired on scroll (%d emission(s))",
    #playhead_changed_log - n_before))

-- ── Case 2: IS playing — scroll must NOT fire playhead_changed ──
-- This is the regression: stale playhead emit during playback caused a seek
-- that stopped the transport.
timeline_state.set_is_playing(true)

local n_before_playing = #playhead_changed_log
timeline_state.set_viewport_start_time(30)

assert(#playhead_changed_log == n_before_playing, string.format(
    "While playing, scrolling must NOT fire playhead_changed (would stop playback). "
    .. "Expected no new emissions; got %d. Stale playhead flush is the regression.",
    #playhead_changed_log - n_before_playing))
print("  ✓ playing: playhead_changed suppressed on scroll (no spurious seek)")

-- ── Case 3: Resume parked — scroll should flush again after stopping ──
timeline_state.set_is_playing(false)

local n_before_resumed = #playhead_changed_log
timeline_state.set_viewport_start_time(20)
assert(#playhead_changed_log > n_before_resumed, string.format(
    "After stopping, scrolling must resume flushing SetPlayhead. "
    .. "Expected playhead_changed to fire; got %d new emissions.",
    #playhead_changed_log - n_before_resumed))
print("  ✓ after stop: playhead_changed fires again on scroll")

Signals.disconnect(token)

print("\n✅ test_scroll_during_playback_preserves_playhead.lua passed")
