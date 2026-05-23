#!/usr/bin/env luajit
--
-- BladeAtPlayhead keyboard-adapter regression. Pins the executor path the
-- 2026-05-22 TSO crashed on: pressing Cmd+B tripped a contract assertion
-- inside the adapter because it expected `result.splits` from
-- command_manager.execute, but the executor's secondary return value
-- (Blade's `{splits=...}`) is not propagated through. The adapter now
-- checks `result.success` instead.
--
-- Verifies: adapter resolves blade_frame from the sequence row's
-- playhead_position, dispatches Blade, and surfaces success. Clip on an
-- armed track spanning the playhead gets split into two halves.

require('test_env')

local database        = require("core.database")
local command_manager = require("core.command_manager")
local Sequence        = require("models.sequence")

local TEST_DB = "/tmp/jve/test_blade_at_playhead_executor.db"
os.remove(TEST_DB)
database.init(TEST_DB)
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p1', 'P', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":30,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
                           audio_sample_rate, width, height,
                           playhead_frame, view_start_frame, view_duration_frames,
                           start_timecode_frame, created_at, modified_at)
    VALUES ('seq', 'p1', 'Seq', 'sequence', 30, 1, 48000, 1920, 1080,
            30, 0, 240, 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, autoselect, locked)
    VALUES ('t_v1', 'seq', 'V1', 'VIDEO', 1, 1, 1, 0);
]], now, now, now, now))

-- Placeholder master sequence so a V13 clip has somewhere to point.
local test_env = require("test_env")
test_env.create_test_media({
    id = "m1", project_id = "p1", name = "m1.mov",
    file_path = "/tmp/jve/m1.mov", duration_frames = 1000,
    fps_numerator = 30, fps_denominator = 1, width = 1920, height = 1080,
})
Sequence.ensure_master("m1", "p1", { id = "master" })

-- Insert a clip spanning frames [0, 60). Playhead at 30 sits strictly inside.
local stmt = assert(db:prepare([[
    INSERT INTO clips (id, project_id, name, track_id,
                       owner_sequence_id, sequence_id,
                       sequence_start_frame, duration_frames,
                       source_in_frame, source_out_frame,
                       master_layer_track_id, master_audio_track_id,
                       fps_mismatch_policy,
                       enabled, volume, playhead_frame,
                       created_at, modified_at)
    VALUES ('c1', 'p1', 'C1', 't_v1', 'seq', 'master',
            0, 60, 0, 60, NULL, NULL, 'resample', 1, 1.0, 0, ?, ?)
]]))
assert(stmt:bind_value(1, now))
assert(stmt:bind_value(2, now))
assert(stmt:exec()); stmt:finalize()

command_manager.init('seq', 'p1')

-- Stub timeline_state.get_selected_clips to return no selection so the
-- adapter falls back to "every armed track" (path 2 in its policy).
local timeline_state = require("ui.timeline.timeline_state")
timeline_state.get_selected_clips = function() return {} end

local function count_clips_on_track(track_id)
    local s = assert(db:prepare("SELECT COUNT(*) FROM clips WHERE track_id = ?"))
    assert(s:bind_value(1, track_id))
    assert(s:exec() and s:next())
    local n = s:value(0); s:finalize(); return n
end

print("\n=== BladeAtPlayhead executor regression ===")
assert(count_clips_on_track('t_v1') == 1, "precondition: 1 clip before blade")

local Command = require("command")
local cmd = Command.create("BladeAtPlayhead", "p1")
cmd:set_parameter("sequence_id", "seq")
cmd:set_parameter("project_id",  "p1")
local result = command_manager.execute(cmd)
assert(type(result) == "table",
    "executor returned non-table: " .. type(result))
assert(result.success == true, string.format(
    "BladeAtPlayhead failed: success=%s error=%s",
    tostring(result.success), tostring(result.error_message)))
print("  PASS: adapter executor returned success=true")

assert(count_clips_on_track('t_v1') == 2, string.format(
    "expected 2 clips after blade at frame 30, got %d",
    count_clips_on_track('t_v1')))
print("  PASS: clip at playhead split into two halves")

-- Undo / redo cycle pins behavior of the Blade undoer's reverse path
-- (TSO 2026-05-22: undoer emitted no __timeline_mutations, leaving
-- run_undoer to fall through to a heavy reload + log an error). The DB
-- unwind alone was already passing — what the fix changes is whether
-- the symmetric reverse-mutation bucket is set, which apply_command_mutations
-- consumes. The user-visible regression is clip count flipping between
-- 1 (after undo) and 2 (after redo).
local undo_result = command_manager.undo()
assert(undo_result and undo_result.success, string.format(
    "Blade undo failed: %s",
    undo_result and tostring(undo_result.error_message) or "nil"))
assert(count_clips_on_track('t_v1') == 1, string.format(
    "expected 1 clip after undo, got %d", count_clips_on_track('t_v1')))
print("  PASS: undo restored the original single clip")

local redo_result = command_manager.redo()
assert(redo_result and redo_result.success, string.format(
    "Blade redo failed: %s",
    redo_result and tostring(redo_result.error_message) or "nil"))
assert(count_clips_on_track('t_v1') == 2, string.format(
    "expected 2 clips after redo, got %d", count_clips_on_track('t_v1')))
print("  PASS: redo re-applied the blade (2 clips)")

print("\n✅ test_blade_at_playhead_executor.lua passed")
