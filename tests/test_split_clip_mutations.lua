#!/usr/bin/env luajit

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')
local SCHEMA_SQL = require('import_schema')
local Rational = require('core.rational')

local timeline_state = {
    sequence_id = "default_sequence",
    playhead = 0,
    reload_calls = 0,
    applied_buckets = {},
    last_bucket = nil
}

function timeline_state.capture_viewport()
    return {start_value = 0, duration_value = 240, timebase_type = "video_frames", timebase_rate = 1000}
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
function timeline_state.set_playhead_position(ms) timeline_state.playhead = ms end
function timeline_state.get_playhead_position() return timeline_state.playhead end
function timeline_state.get_sequence_frame_rate() return {fps_numerator = 1000, fps_denominator = 1} end
function timeline_state.get_sequence_audio_sample_rate() return 48000 end
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
    assert(db:exec([[
        INSERT INTO projects (id, name, created_at, modified_at)
        VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
        INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, view_start_frame, view_duration_frames, playhead_frame, created_at, modified_at)
        VALUES ('default_sequence', 'default_project', 'Default Sequence', 'timeline', 1000, 1, 48000, 1920, 1080, 0, 240, 0, strftime('%s','now'), strftime('%s','now'));
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
        VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 0, 0);
        INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at, metadata)
        VALUES ('media_stub', 'default_project', 'Stub', '/tmp/jve/stub.mov', 1000, 1000, 1, 1920, 1080, 2, 'prores', strftime('%s','now'), strftime('%s','now'), '{}');
        INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, source_sequence_id, parent_clip_id, owner_sequence_id,
                           timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
        VALUES ('clip_a', 'default_project', 'timeline', 'Clip A', 'track_v1', 'media_stub', NULL, NULL, 'default_sequence',
                0, 1000, 0, 1000, 1000, 1, 1, 0, strftime('%s','now'), strftime('%s','now'));
    ]]))
    return db
end

local TEST_DB = "/tmp/jve/test_split_clip_mutations.db"
local db = init_database(TEST_DB)

command_manager.init("default_sequence", "default_project")
command_manager.activate_timeline_stack("default_sequence")

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

local split_cmd = Command.create("SplitClip", "default_project")
split_cmd:set_parameter("clip_id", "clip_a")
split_cmd:set_parameter("split_value", 600)
split_cmd:set_parameter("sequence_id", "default_sequence")

local split_result = command_manager.execute(split_cmd)
assert(split_result.success, split_result.error_message or "SplitClip execution failed")
assert(timeline_state.reload_calls == 0, "SplitClip should not trigger timeline reload fallback")
assert(timeline_state.last_bucket, "SplitClip should emit timeline mutations")
assert(timeline_state.last_bucket.updates and #timeline_state.last_bucket.updates >= 1,
    "SplitClip should update the original clip")
assert(timeline_state.last_bucket.inserts and #timeline_state.last_bucket.inserts >= 1,
    "SplitClip should insert the new clip")

reset_timeline_stub()

local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "UndoSplitClip failed")

local stmt = db:prepare([[
    SELECT id, timeline_start_frame, duration_frames
    FROM clips
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

os.remove(TEST_DB)
print("✅ SplitClip emits timeline mutations (execute and undo)")
