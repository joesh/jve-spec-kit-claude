#!/usr/bin/env luajit

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

local test_env = require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')
local SCHEMA_SQL = require('import_schema')

local timeline_state = {
    sequence_id = "default_sequence",
    playhead = 0,
    reload_calls = 0,
    applied_buckets = {},
    last_bucket = nil
}

function timeline_state.capture_viewport()
    return {start_value = 0, duration_value = 240, timebase_type = "video_frames", timebase_rate = 30}
end
function timeline_state.push_viewport_guard() end
function timeline_state.pop_viewport_guard() end
function timeline_state.restore_viewport(_) end
function timeline_state.set_selection(_) end
function timeline_state.set_edge_selection(_) end
function timeline_state.set_gap_selection(_) end
function timeline_state.get_selected_clips() return {} end
function timeline_state.get_selected_edges() return {} end
function timeline_state.clear_edge_selection() end
function timeline_state.clear_gap_selection() end
function timeline_state.set_playhead_position(val) timeline_state.playhead = val end
function timeline_state.get_playhead_position() return timeline_state.playhead end
function timeline_state.get_sequence_frame_rate()
    return {fps_numerator = 30, fps_denominator = 1}
end
function timeline_state.get_sequence_id() return timeline_state.sequence_id end
function timeline_state.normalize_edge_selection() return false end
function timeline_state.persist_state_to_db() end
function timeline_state.consume_mutation_failure() return nil end
function timeline_state.apply_mutations(sequence_id, bucket)
    timeline_state.sequence_id = sequence_id or timeline_state.sequence_id
    timeline_state.last_bucket = bucket
    table.insert(timeline_state.applied_buckets, bucket)
    return true
end
function timeline_state.reload_clips(sequence_id)
    timeline_state.reload_calls = timeline_state.reload_calls + 1
    if sequence_id and sequence_id ~= "" then
        timeline_state.sequence_id = sequence_id
    end
end

package.loaded['ui.timeline.timeline_state'] = timeline_state

local function init_database(path)
    os.remove(path)
    assert(database.init(path))
    local db = database.get_connection()
    assert(db:exec(SCHEMA_SQL))
    local now = os.time()
    assert(db:exec(([[
        INSERT INTO projects (id, name, created_at, modified_at)
        VALUES ('default_project', 'Default Project', %d, %d);
    ]]):format(now, now)))
    assert(db:exec(([[
        INSERT INTO sequences (
            id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_rate,
            width, height, view_start_frame, view_duration_frames, playhead_frame,
            created_at, modified_at
        ) VALUES (
            'default_sequence', 'default_project', 'Default Sequence', 'timeline',
            30, 1, 48000,
            1920, 1080, 0, 240, 0,
            %d, %d
        );
    ]]):format(now, now)))
    assert(db:exec(([[
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
        VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    ]])))
    assert(db:exec(([[
        INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
        VALUES ('media_stub', 'default_project', 'Stub', '/tmp/jve/stub.mov', 2000, 30, 1, 1920, 1080, 2, 'prores', '{}', %d, %d);
    ]]):format(now, now)))
    assert(db:exec(([[
        INSERT INTO clips (
            id, project_id, clip_kind, name, track_id, media_id, master_clip_id, owner_sequence_id,
            timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
            fps_numerator, fps_denominator, enabled, offline, created_at, modified_at
        ) VALUES (
            'clip_a', 'default_project', 'timeline', 'Clip A', 'track_v1', 'media_stub', NULL, 'default_sequence',
            0, 1000, 0, 1000,
            30, 1, 1, 0, %d, %d
        );
    ]]):format(now, now)))
    return db
end

local TEST_DB = "/tmp/jve/test_overwrite_mutations.db"
local db = init_database(TEST_DB)

command_manager.init("default_sequence", "default_project")
command_manager.activate_timeline_stack("default_sequence")

-- Create masterclip sequence for the media (required for Overwrite)
local master_clip_id = test_env.create_test_masterclip_sequence(
    'default_project', 'Stub Master', 30, 1, 2000, 'media_stub')

local function reset_timeline_stub()
    timeline_state.reload_calls = 0
    timeline_state.applied_buckets = {}
    timeline_state.last_bucket = nil
end

local prime_cmd = Command.create("ToggleClipEnabled", "default_project")
prime_cmd:set_parameter("clip_ids", {"clip_a"})
prime_cmd:set_parameter("sequence_id", "default_sequence")
local prime_result = command_manager.execute(prime_cmd)
assert(prime_result.success, prime_result.error_message or "Failed to prime command stack")
reset_timeline_stub()

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
assert(timeline_state.reload_calls == 0, "Overwrite should rely on timeline mutations, not reload fallback")
assert(#timeline_state.applied_buckets >= 1, "Overwrite should emit timeline mutations during execute")
local inserted_clip_id = overwrite_cmd:get_parameter("clip_id")
assert(inserted_clip_id and inserted_clip_id ~= "", "Overwrite should persist inserted clip_id parameter")

reset_timeline_stub()

local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo Overwrite failed")
assert(timeline_state.last_bucket, "Undo Overwrite should emit timeline mutations")
local undo_bucket = timeline_state.last_bucket
local deleted_lookup = {}
for _, clip_id in ipairs(undo_bucket.deletes or {}) do
    deleted_lookup[clip_id] = true
end
assert(deleted_lookup[inserted_clip_id], "Undo Overwrite should delete the inserted clip without reloading the entire timeline")

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

os.remove(TEST_DB)
print("✅ Overwrite emits and replays timeline mutations (execute and undo)")
