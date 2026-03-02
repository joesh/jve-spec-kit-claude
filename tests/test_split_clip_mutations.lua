#!/usr/bin/env luajit

-- Test SplitClip emits timeline mutations (execute and undo)
-- Verifies: mutations-based update path, no reload fallback
-- Uses REAL timeline_state — no mock.

require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')
local Signals = require('core.signals')
local SCHEMA_SQL = require('import_schema')

local TEST_DB = "/tmp/jve/test_split_clip_mutations.db"
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
    VALUES ('media_stub', 'default_project', 'Stub', '/tmp/jve/stub.mov', 1000, 30, 1,
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

-- Execute SplitClip
local split_cmd = Command.create("SplitClip", "default_project")
split_cmd:set_parameter("clip_id", "clip_a")
split_cmd:set_parameter("split_value", 600)
split_cmd:set_parameter("sequence_id", "default_sequence")

local split_result = command_manager.execute(split_cmd)
assert(split_result.success, split_result.error_message or "SplitClip execution failed")
assert(reload_count == 0, "SplitClip should not trigger timeline reload fallback")
assert(#mutation_log >= 1, "SplitClip should emit timeline mutations")
local last_mutations = mutation_log[#mutation_log]
assert(last_mutations.updates and #last_mutations.updates >= 1,
    "SplitClip should update the original clip")
assert(last_mutations.inserts and #last_mutations.inserts >= 1,
    "SplitClip should insert the new clip")

reset_tracking()

-- Undo
local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "UndoSplitClip failed")

-- DB verification
local stmt = db:prepare([[
    SELECT id, timeline_start_frame, duration_frames
    FROM clips
    WHERE owner_sequence_id = 'default_sequence'
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
    assert(start_value == 0, "Original clip start_value should be 0 after undo")
    assert(duration_value == 1000, "Original clip duration_value should be restored after undo")
end
stmt:finalize()
assert(clip_count == 1, "Undo should leave exactly one clip in the timeline")

Signals.disconnect(mutation_conn)
Signals.disconnect(reload_conn)

os.remove(TEST_DB)
print("✅ SplitClip emits timeline mutations (execute and undo)")
