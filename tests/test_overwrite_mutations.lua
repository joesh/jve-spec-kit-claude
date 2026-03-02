#!/usr/bin/env luajit

-- Test Overwrite emits and replays timeline mutations (execute and undo)
-- Verifies: mutations-based update path, no reload fallback
-- Uses REAL timeline_state — no mock.

local test_env = require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')
require('ui.timeline.timeline_state')
local Signals = require('core.signals')
local SCHEMA_SQL = require('import_schema')

local TEST_DB = "/tmp/jve/test_overwrite_mutations.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()
db:exec(SCHEMA_SQL)

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    ) VALUES (
        'default_sequence', 'default_project', 'Default Sequence', 'timeline',
        30, 1, 48000, 1920, 1080, 0, 240, 0,
        '[]', '[]', '[]', 0, %d, %d
    );

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
                       width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media_stub', 'default_project', 'Stub', '/tmp/jve/stub.mov', 2000, 30, 1,
            1920, 1080, 2, 'prores', '{}', %d, %d);

    INSERT INTO clips (
        id, project_id, clip_kind, name, track_id, media_id, master_clip_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at
    ) VALUES (
        'clip_a', 'default_project', 'timeline', 'Clip A', 'track_v1', 'media_stub', NULL, 'default_sequence',
        0, 1000, 0, 1000,
        30, 1, 1, 0, %d, %d
    );
]], now, now, now, now, now, now, now, now))

command_manager.init("default_sequence", "default_project")
command_manager.activate_timeline_stack("default_sequence")

-- Create masterclip sequence for the media (required for Overwrite)
local master_clip_id = test_env.create_test_masterclip_sequence(
    'default_project', 'Stub Master', 30, 1, 2000, 'media_stub')

-- Signal-based mutation tracking (replaces mock instrumentation)
local mutation_log = {}
local reload_count = 0

local mutation_conn = Signals.connect("timeline_mutations_applied", function(mutations)
    table.insert(mutation_log, mutations)
end)

local reload_conn = Signals.connect("timeline_clips_reloaded", function()
    reload_count = reload_count + 1
end)

local function reset_tracking()
    mutation_log = {}
    reload_count = 0
end

-- Prime command stack
local prime_cmd = Command.create("ToggleClipEnabled", "default_project")
prime_cmd:set_parameter("clip_ids", {"clip_a"})
prime_cmd:set_parameter("sequence_id", "default_sequence")
local prime_result = command_manager.execute(prime_cmd)
assert(prime_result.success, prime_result.error_message or "Failed to prime command stack")
reset_tracking()

-- Execute Overwrite
local overwrite_cmd = Command.create("Overwrite", "default_project")
overwrite_cmd:set_parameter("track_id", "track_v1")
overwrite_cmd:set_parameter("sequence_id", "default_sequence")
overwrite_cmd:set_parameter("master_clip_id", master_clip_id)
overwrite_cmd:set_parameter("overwrite_time", 400)
overwrite_cmd:set_parameter("duration", 300)
overwrite_cmd:set_parameter("source_in", 0)
overwrite_cmd:set_parameter("source_out", 300)

local overwrite_result = command_manager.execute(overwrite_cmd)
assert(overwrite_result.success, overwrite_result.error_message or "Overwrite execution failed")
assert(reload_count == 0, "Overwrite should rely on timeline mutations, not reload fallback")
assert(#mutation_log >= 1, "Overwrite should emit timeline mutations during execute")
local inserted_clip_id = overwrite_cmd:get_parameter("clip_id")
assert(inserted_clip_id and inserted_clip_id ~= "", "Overwrite should persist inserted clip_id parameter")

reset_tracking()

-- Undo
local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo Overwrite failed")
assert(#mutation_log >= 1, "Undo Overwrite should emit timeline mutations")
local last_mutations = mutation_log[#mutation_log]
local deleted_lookup = {}
for _, clip_id in ipairs(last_mutations.deletes or {}) do
    deleted_lookup[clip_id] = true
end
assert(deleted_lookup[inserted_clip_id],
    "Undo Overwrite should delete the inserted clip without reloading the entire timeline")

-- DB verification
local stmt = db:prepare([[
    SELECT id, timeline_start_frame, duration_frames
    FROM clips
    WHERE clip_kind = 'timeline' AND owner_sequence_id = 'default_sequence'
    ORDER BY timeline_start_frame
]])
assert(stmt and stmt:exec(), "Failed to query clips after undo")
local clip_count = 0
while stmt:next() do
    clip_count = clip_count + 1
    local clip_id = stmt:value(0)
    local start_value = tonumber(stmt:value(1)) or -1
    local duration_value = tonumber(stmt:value(2)) or -1
    assert(clip_id == "clip_a", "Unexpected clip id after undo: " .. tostring(clip_id))
    assert(start_value == 0, "Original clip start_value should be restored to 0 after undo")
    assert(duration_value == 1000, "Original clip duration_value should be restored to full length after undo")
end
stmt:finalize()
assert(clip_count == 1, "Undo should leave only the original clip in the timeline")

Signals.disconnect(mutation_conn)
Signals.disconnect(reload_conn)

os.remove(TEST_DB)
print("✅ Overwrite emits and replays timeline mutations (execute and undo)")
