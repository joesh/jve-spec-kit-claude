#!/usr/bin/env luajit

-- Regression test: GoToNextEdit / GoToPrevEdit must persist playhead to DB,
-- emit playhead_changed signal, and surface playhead in viewport.
-- Bug: these commands called timeline_state.set_playhead_position() directly,
-- bypassing model persistence and signal emission (unlike GoToStart/GoToEnd).

require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Forward-declare mock_monitor
local mock_monitor

-- Mock panel_manager — justified: seek_to_frame requires Qt engine
package.loaded['ui.panel_manager'] = {
    get_active_sequence_monitor = function() return mock_monitor end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
local timeline_state = require('ui.timeline.timeline_state')
local Signals = require("core.signals")
local Sequence = require("models.sequence")

local TEST_DB = "/tmp/jve/test_go_to_edit_surfaces_playhead.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

-- Create a timeline with clips spread across a wide range:
-- clip_a [0, 100), gap [100, 5000), clip_b [5000, 5150)
-- Viewport shows frames [0, 500) — clip_b is WAY off-screen.
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj1', 'Test Project', 'resample', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos,
        selected_gap_infos, current_sequence_number, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Sequence', 'nested',
        30, 1, 48000, 1920, 1080, 0, 500, 50, '[]', '[]', '[]', 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO clips (
        id, project_id, clip_kind, track_id, owner_sequence_id, media_id, name,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at
    ) VALUES
        ('clip_a', 'proj1', 'timeline', 'track_v1', 'seq1', NULL, 'Clip A',
         0, 100, 0, 100, 30, 1, 1, 0, %d, %d),
        ('clip_b', 'proj1', 'timeline', 'track_v1', 'seq1', NULL, 'Clip B',
         5000, 150, 0, 150, 30, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now))

-- Mock sequence monitor
mock_monitor = {
    sequence_id = "seq1",
    view_id = "timeline_monitor",
    total_frames = 5150,
    playhead = 50,
    engine = {
        is_playing = function() return false end,
        stop = function() end,
    },
}
function mock_monitor:seek_to_frame(frame)
    self.playhead = math.max(0, math.floor(frame))
    timeline_state.set_playhead_position(self.playhead)
end

-- Track playhead_changed signal emissions
local signal_log = {}
Signals.connect("playhead_changed", function(sequence_id, frame)
    table.insert(signal_log, { sequence_id = sequence_id, frame = frame })
    -- Mirror real SequenceMonitor behavior
    if mock_monitor.sequence_id == sequence_id and type(frame) == "number" then
        mock_monitor:seek_to_frame(frame)
    end
end)

command_manager.init('seq1', 'proj1')

print("=== GoToNextEdit/GoToPrevEdit Playhead Surfacing Tests ===")

-- Test 1: GoToNextEdit emits playhead_changed signal
print("Test 1: GoToNextEdit emits playhead_changed signal")
timeline_state.set_playhead_position(50)
signal_log = {}
local result = command_manager.execute("GoToNextEdit", { project_id = "proj1" })
assert(result.success, "GoToNextEdit should succeed")
assert(timeline_state.get_playhead_position() == 100,
    string.format("playhead should be at 100, got %d", timeline_state.get_playhead_position()))
assert(#signal_log > 0, "GoToNextEdit must emit playhead_changed signal (got 0 emissions)")
assert(signal_log[1].sequence_id == "seq1", "signal should have correct sequence_id")
assert(signal_log[1].frame == 100,
    string.format("signal should carry frame 100, got %s", tostring(signal_log[1].frame)))

-- Test 2: GoToNextEdit persists playhead to DB
print("Test 2: GoToNextEdit persists playhead to DB")
local seq = Sequence.load("seq1")
assert(seq, "sequence should be loadable")
assert(seq.playhead_position == 100,
    string.format("DB playhead should be 100, got %s", tostring(seq.playhead_position)))

-- Test 3: GoToPrevEdit emits playhead_changed signal
print("Test 3: GoToPrevEdit emits playhead_changed signal")
timeline_state.set_playhead_position(5100)
signal_log = {}
result = command_manager.execute("GoToPrevEdit", { project_id = "proj1" })
assert(result.success, "GoToPrevEdit should succeed")
assert(timeline_state.get_playhead_position() == 5000,
    string.format("playhead should be at 5000, got %d", timeline_state.get_playhead_position()))
assert(#signal_log > 0, "GoToPrevEdit must emit playhead_changed signal (got 0 emissions)")
assert(signal_log[1].frame == 5000,
    string.format("signal should carry frame 5000, got %s", tostring(signal_log[1].frame)))

-- Test 4: GoToPrevEdit persists playhead to DB
print("Test 4: GoToPrevEdit persists playhead to DB")
seq = Sequence.load("seq1")
assert(seq.playhead_position == 5000,
    string.format("DB playhead should be 5000, got %s", tostring(seq.playhead_position)))

-- Test 5: GoToNextEdit surfaces playhead when target is off-viewport
-- Viewport is [0, 500). Edit at 5000 is off-screen.
print("Test 5: GoToNextEdit surfaces playhead when off-viewport")
timeline_state.set_playhead_position(100)
timeline_state.set_viewport_start_time(0)  -- viewport [0, 500)
signal_log = {}
result = command_manager.execute("GoToNextEdit", { project_id = "proj1" })
assert(result.success, "GoToNextEdit should succeed")
-- Playhead should be at 5000 (start of clip_b)
assert(timeline_state.get_playhead_position() == 5000,
    string.format("playhead should be at 5000, got %d", timeline_state.get_playhead_position()))
-- Viewport should have scrolled so playhead is visible
local vp_start = timeline_state.get_viewport_start_time()
local vp_end = vp_start + timeline_state.get_viewport_duration()
assert(vp_start <= 5000 and 5000 <= vp_end,
    string.format("viewport [%d, %d) should contain playhead 5000", vp_start, vp_end))

-- Test 6: GoToPrevEdit surfaces playhead when target is off-viewport
-- Navigate back: from 5000, viewport is near 5000, go prev to 100 which is off-screen
print("Test 6: GoToPrevEdit surfaces playhead when off-viewport")
-- Viewport is near 5000 from previous test
signal_log = {}
result = command_manager.execute("GoToPrevEdit", { project_id = "proj1" })
assert(result.success, "GoToPrevEdit should succeed")
assert(timeline_state.get_playhead_position() == 100,
    string.format("playhead should be at 100, got %d", timeline_state.get_playhead_position()))
vp_start = timeline_state.get_viewport_start_time()
vp_end = vp_start + timeline_state.get_viewport_duration()
assert(vp_start <= 100 and 100 <= vp_end,
    string.format("viewport [%d, %d) should contain playhead 100", vp_start, vp_end))

print("✅ test_go_to_edit_surfaces_playhead.lua passed")
