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

local timeline_state = {
    sequence_id = "default_sequence",
    playhead = 0,
    reload_calls = 0,
    applied_buckets = {},
    last_bucket = nil
}

function timeline_state.capture_viewport()
    return {start_time = 0, duration = 10000}
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
function timeline_state.set_playhead_time(ms) timeline_state.playhead = ms end
function timeline_state.get_playhead_time() return timeline_state.playhead end
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
        INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
        VALUES ('default_sequence', 'default_project', 'Default Sequence', 30.0, 1920, 1080);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
        VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 0, 0);
        INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, width, height, audio_channels, codec, created_at, modified_at, metadata)
        VALUES ('media_stub', 'default_project', 'Stub', '/tmp/stub.mov', 2000, 30.0, 1920, 1080, 2, 'prores', strftime('%s','now'), strftime('%s','now'), '{}');
        INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, source_sequence_id, parent_clip_id, owner_sequence_id,
                           start_time, duration, source_in, source_out, enabled, offline, created_at, modified_at)
        VALUES ('clip_a', 'default_project', 'timeline', 'Clip A', 'track_v1', 'media_stub', NULL, NULL, 'default_sequence',
                0, 1000, 0, 1000, 1, 0, strftime('%s','now'), strftime('%s','now'));
    ]]))
    return db
end

local TEST_DB = "/tmp/test_overwrite_mutations.db"
local db = init_database(TEST_DB)

command_manager.init(db, "default_sequence", "default_project")
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

local overwrite_cmd = Command.create("Overwrite", "default_project")
overwrite_cmd:set_parameter("track_id", "track_v1")
overwrite_cmd:set_parameter("sequence_id", "default_sequence")
overwrite_cmd:set_parameter("media_id", "media_stub")
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
    SELECT id, start_time, duration
    FROM clips
    WHERE clip_kind = 'timeline'
    ORDER BY start_time
]])
assert(stmt and stmt:exec(), "Failed to query clips after undo")
local clip_count = 0
while stmt:next() do
    clip_count = clip_count + 1
    local clip_id = stmt:value(0)
    local start_time = tonumber(stmt:value(1)) or -1
    local duration = tonumber(stmt:value(2)) or -1
    assert(clip_id == "clip_a", "Unexpected clip id after undo: " .. tostring(clip_id))
    assert(start_time == 0, "Original clip start_time should be restored to 0 after undo")
    assert(duration == 1000, "Original clip duration should be restored to full length after undo")
end
stmt:finalize()
assert(clip_count == 1, "Undo should leave only the original clip in the timeline")

os.remove(TEST_DB)
print("✅ Overwrite emits and replays timeline mutations (execute and undo)")
