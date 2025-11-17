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

local function init_database(path)
    os.remove(path)
    assert(database.init(path))
    local db = database.get_connection()
    assert(db:exec(SCHEMA_SQL))
    assert(db:exec([[
        INSERT INTO projects (id, name, created_at, modified_at)
        VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
        INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
        VALUES ('default_sequence', 'default_project', 'Default Sequence', 25.0, 1920, 1080);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
        VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 0, 0);
        INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, width, height, audio_channels, codec, created_at, modified_at, metadata)
        VALUES ('media_a', 'default_project', 'A', '/tmp/a.mov', 10000, 25.0, 1920, 1080, 2, 'prores', strftime('%s','now'), strftime('%s','now'), '{}');
        INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, width, height, audio_channels, codec, created_at, modified_at, metadata)
        VALUES ('media_b', 'default_project', 'B', '/tmp/b.mov', 10000, 25.0, 1920, 1080, 2, 'prores', strftime('%s','now'), strftime('%s','now'), '{}');
        INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                           start_time, duration, source_in, source_out, enabled, offline, created_at, modified_at)
        VALUES ('clip_a', 'default_project', 'timeline', 'Clip A', 'track_v1', 'media_a', 'default_sequence',
                0, 3000, 1000, 4000, 1, 0, strftime('%s','now'), strftime('%s','now'));
        INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                           start_time, duration, source_in, source_out, enabled, offline, created_at, modified_at)
        VALUES ('clip_b', 'default_project', 'timeline', 'Clip B', 'track_v1', 'media_b', 'default_sequence',
                3000, 2000, 500, 2500, 1, 0, strftime('%s','now'), strftime('%s','now'));
    ]]))
    return db
end

local TEST_DB = "/tmp/test_roll_drag_undo.db"
local db = init_database(TEST_DB)
command_manager.init(db, "default_sequence", "default_project")
command_manager.activate_timeline_stack("default_sequence")

-- Simulate roll selection across clip_a out / clip_b in (adjacent)
local edges = {
    {clip_id = "clip_a", edge_type = "out", track_id = "track_v1", trim_type = "roll"},
    {clip_id = "clip_b", edge_type = "in", track_id = "track_v1", trim_type = "roll"},
}

-- Perform roll drag: move boundary left by 500ms
local roll_cmd = Command.create("BatchRippleEdit", "default_project")
roll_cmd:set_parameter("sequence_id", "default_sequence")
roll_cmd:set_parameter("edge_infos", edges)
roll_cmd:set_parameter("delta_ms", -500)

local result = command_manager.execute(roll_cmd)
assert(result.success, result.error_message or "Roll execution failed")

-- Validate post-roll state
local function fetch_clip(id)
    local stmt = db:prepare("SELECT start_time, duration FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt and stmt:exec() and stmt:next(), "Failed to load clip " .. id)
    local start_time = tonumber(stmt:value(0))
    local duration = tonumber(stmt:value(1))
    stmt:finalize()
    return start_time, duration
end

local a_start, a_dur = fetch_clip("clip_a")
assert(math.abs(a_start - 0) < 1, "clip_a start should stay fixed after roll")
assert(math.abs(a_dur - 2500) < 1, "clip_a duration should shrink by 500")

local b_start, b_dur = fetch_clip("clip_b")
assert(math.abs(b_start - 2500) < 1, "clip_b start should move left by 500 in roll")
assert(math.abs(b_dur - 2500) < 1, "clip_b duration should grow by 500 in roll")

-- Undo the roll
local undo = command_manager.undo()
assert(undo.success, undo.error_message or "Undo failed for roll")

a_start, a_dur = fetch_clip("clip_a")
assert(math.abs(a_start - 0) < 1, "clip_a start should restore to 0 after undo")
assert(math.abs(a_dur - 3000) < 1, "clip_a duration should restore after undo")

b_start, b_dur = fetch_clip("clip_b")
assert(math.abs(b_start - 3000) < 1, "clip_b start should restore after undo")
assert(math.abs(b_dur - 2000) < 1, "clip_b duration should restore after undo")

os.remove(TEST_DB)
print("❌ Roll drag undo currently fails (expected until fix)")

-- NOTE: This test is expected to fail until roll undo restores original clip states without
-- persisting gap materialization.
