#!/usr/bin/env luajit

package.path = package.path
    .. ";./tests/?.lua"
    .. ";./src/lua/?.lua"
    .. ";./src/lua/core/?.lua"
    .. ";./src/lua/models/?.lua"
    .. ";./src/lua/ui/?.lua"
    .. ";./src/lua/ui/timeline/?.lua"

require("test_env")

local event_log_stub = {
    init = function() return true end,
    record_command = function() return true end
}
package.loaded["core.event_log"] = event_log_stub

local database = require("core.database")
local command_manager = require("core.command_manager")
-- core.command_implementations is deleted
-- local command_impl = require("core.command_implementations")
local Command = require("command")
local timeline_state = require("ui.timeline.timeline_state")

local SCHEMA_SQL = require('import_schema')

local BASE_DATA_SQL = [[
    INSERT INTO projects (id, name, created_at, modified_at, settings)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'), '{}');

    INSERT INTO sequences (
        id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos, current_sequence_number, created_at, modified_at
    )
    VALUES ('seq_a', 'default_project', 'Seq A', 'timeline', 30, 1, 48000, 1920, 1080, 0, 10000, 0, '[]', '[]', '[]', 0, strftime('%s','now'), strftime('%s','now'));

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan) VALUES
        ('seq_a_v1', 'seq_a', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0),
        ('seq_a_v2', 'seq_a', 'V2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0),
        ('seq_a_a1', 'seq_a', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0),
        ('seq_a_a2', 'seq_a', 'A2', 'AUDIO', 2, 1, 0, 0, 0, 1.0, 0.0);
]]

local function setup_database(path)
    os.remove(path)
    assert(database.init(path))
    local conn = database.get_connection()
    assert(conn:exec(SCHEMA_SQL))
    assert(conn:exec(BASE_DATA_SQL))
    return conn
end

local function assert_equal(actual, expected, label)
    if actual ~= expected then
        error(string.format("Assertion failed for %s: expected %s, got %s", label, tostring(expected), tostring(actual)))
    end
end

local tmp_db = os.tmpname() .. ".db"
local conn = setup_database(tmp_db)
assert(conn, "failed to initialize test database")

command_manager.init(conn, "seq_a", "default_project")

local function track_id(sequence_id, track_type, index)
    local stmt = conn:prepare([[
        SELECT id FROM tracks
        WHERE sequence_id = ? AND track_type = ? AND track_index = ?
    ]])
    stmt:bind_value(1, sequence_id)
    stmt:bind_value(2, track_type)
    stmt:bind_value(3, index)
    assert(stmt:exec())
    local result = nil
    if stmt:next() then
        result = stmt:value(0)
    end
    stmt:finalize()
    assert(result, string.format("missing track id for %s %s%d", sequence_id, track_type, index))
    return result
end

-- Sequence A: adjust heights and verify persistence
assert(timeline_state.init("seq_a"))
assert_equal(timeline_state.get_track_height("seq_a_v1"), timeline_state.dimensions.default_track_height, "initial V1 height")

local seq_a_v1 = track_id("seq_a", "VIDEO", 1)
local seq_a_v2 = track_id("seq_a", "VIDEO", 2)
local seq_a_a1 = track_id("seq_a", "AUDIO", 1)
local seq_a_a2 = track_id("seq_a", "AUDIO", 2)

timeline_state.set_track_height(seq_a_v1, 96)
timeline_state.set_track_height(seq_a_v2, 64)
timeline_state.set_track_height(seq_a_a1, 40)
timeline_state.set_track_height(seq_a_a2, 28)
timeline_state.persist_state_to_db(true)

timeline_state.init("seq_a")
assert_equal(timeline_state.get_track_height(seq_a_v1), 96, "persisted V1 height")
assert_equal(timeline_state.get_track_height(seq_a_v2), 64, "persisted V2 height")
assert_equal(timeline_state.get_track_height(seq_a_a1), 40, "persisted A1 height")
assert_equal(timeline_state.get_track_height(seq_a_a2), 28, "persisted A2 height")

-- Create Sequence B after customizing template
local create_cmd = Command.create("CreateSequence", "default_project")
create_cmd:set_parameter("project_id", "default_project")
create_cmd:set_parameter("name", "Seq B")
create_cmd:set_parameter("frame_rate", 30)
create_cmd:set_parameter("width", 1920)
create_cmd:set_parameter("height", 1080)
local create_result = command_manager.execute(create_cmd)
assert(create_result.success, "CreateSequence command failed")
local seq_b = create_cmd:get_parameter("sequence_id")
assert(seq_b and seq_b ~= "", "missing seq_b id")

-- Sequence B should adopt template immediately
timeline_state.init(seq_b)
local seq_b_v1 = track_id(seq_b, "VIDEO", 1)
local seq_b_v2 = track_id(seq_b, "VIDEO", 2)
local seq_b_a1 = track_id(seq_b, "AUDIO", 1)
local seq_b_a2 = track_id(seq_b, "AUDIO", 2)

assert_equal(timeline_state.get_track_height(seq_b_v1), 96, "template V1")
assert_equal(timeline_state.get_track_height(seq_b_v2), 64, "template V2")
assert_equal(timeline_state.get_track_height(seq_b_a1), 40, "template A1")
assert_equal(timeline_state.get_track_height(seq_b_a2), 28, "template A2")

-- Sequence B persistence should now be independent
timeline_state.set_track_height(seq_b_v1, 82)
timeline_state.persist_state_to_db(true)
timeline_state.init(seq_b)
assert_equal(timeline_state.get_track_height(seq_b_v1), 82, "seq_b persisted V1")

timeline_state.init("seq_a")
assert_equal(timeline_state.get_track_height(seq_a_v1), 96, "seq_a retained custom height after seq_b edit")

os.remove(tmp_db)
print("✅ track height persistence test passed")
