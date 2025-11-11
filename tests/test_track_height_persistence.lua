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
local command_impl = require("core.command_implementations")
local Command = require("command")
local timeline_state = require("ui.timeline.timeline_state")

local SCHEMA_SQL = [[
    CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL DEFAULT 0,
        modified_at INTEGER NOT NULL DEFAULT 0,
        settings TEXT NOT NULL DEFAULT '{}'
    );

    CREATE TABLE sequences (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'timeline',
        frame_rate REAL NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        timecode_start INTEGER NOT NULL DEFAULT 0,
        playhead_time INTEGER NOT NULL DEFAULT 0,
        selected_clip_ids TEXT,
        selected_edge_infos TEXT,
        viewport_start_time INTEGER NOT NULL DEFAULT 0,
        viewport_duration INTEGER NOT NULL DEFAULT 10000,
        mark_in_time INTEGER,
        mark_out_time INTEGER,
        current_sequence_number INTEGER
    );

    CREATE TABLE tracks (
        id TEXT PRIMARY KEY,
        sequence_id TEXT NOT NULL,
        name TEXT NOT NULL,
        track_type TEXT NOT NULL,
        track_index INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        locked INTEGER NOT NULL DEFAULT 0,
        muted INTEGER NOT NULL DEFAULT 0,
        soloed INTEGER NOT NULL DEFAULT 0,
        volume REAL NOT NULL DEFAULT 1.0,
        pan REAL NOT NULL DEFAULT 0.0
    );

    CREATE TABLE media (
        id TEXT PRIMARY KEY,
        project_id TEXT,
        name TEXT,
        file_path TEXT,
        duration INTEGER,
        frame_rate REAL,
        width INTEGER,
        height INTEGER,
        audio_channels INTEGER,
        codec TEXT,
        created_at INTEGER,
        modified_at INTEGER,
        metadata TEXT
    );

    CREATE TABLE clips (
        id TEXT PRIMARY KEY,
        project_id TEXT,
        clip_kind TEXT NOT NULL DEFAULT 'timeline',
        name TEXT DEFAULT '',
        track_id TEXT,
        media_id TEXT,
        source_sequence_id TEXT,
        parent_clip_id TEXT,
        owner_sequence_id TEXT,
        start_time INTEGER NOT NULL,
        duration INTEGER NOT NULL,
        source_in INTEGER NOT NULL DEFAULT 0,
        source_out INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        offline INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT 0,
        modified_at INTEGER NOT NULL DEFAULT 0
    );
]]

local BASE_DATA_SQL = [[
    INSERT INTO projects (id, name, created_at, modified_at, settings)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'), '{}');

    INSERT INTO sequences (id, project_id, name, frame_rate, width, height, selected_clip_ids, selected_edge_infos)
    VALUES ('seq_a', 'default_project', 'Seq A', 30.0, 1920, 1080, '[]', '[]');

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES
        ('seq_a_v1', 'seq_a', 'V1', 'VIDEO', 1, 1),
        ('seq_a_v2', 'seq_a', 'V2', 'VIDEO', 2, 1),
        ('seq_a_a1', 'seq_a', 'A1', 'AUDIO', 1, 1),
        ('seq_a_a2', 'seq_a', 'A2', 'AUDIO', 2, 1);
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

local executors = {}
local undoers = {}
command_impl.register_commands(executors, undoers, conn)

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
assert(executors["CreateSequence"](create_cmd), "CreateSequence command failed")
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
