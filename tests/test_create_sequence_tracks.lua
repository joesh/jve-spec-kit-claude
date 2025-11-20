#!/usr/bin/env luajit

package.path = package.path
    .. ";./tests/?.lua"
    .. ";./src/lua/?.lua"
    .. ";./src/lua/core/?.lua"
    .. ";./src/lua/models/?.lua"

require("test_env")

local database = require("core.database")
local command_impl = require("core.command_implementations")
local Command = require("command")

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
        frame_rate REAL NOT NULL, audio_sample_rate INTEGER NOT NULL DEFAULT 48000,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        timecode_start_frame INTEGER NOT NULL DEFAULT 0,
        playhead_frame INTEGER NOT NULL DEFAULT 0,
        selected_clip_ids TEXT,
        selected_edge_infos TEXT,
        viewport_start_frame INTEGER NOT NULL DEFAULT 0,
        viewport_duration_frames INTEGER NOT NULL DEFAULT 240,
        current_sequence_number INTEGER
    );

    CREATE TABLE tracks (
        id TEXT PRIMARY KEY,
        sequence_id TEXT NOT NULL,
        name TEXT NOT NULL, track_type TEXT NOT NULL, timebase_type TEXT NOT NULL, timebase_rate REAL NOT NULL, track_index INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        locked INTEGER NOT NULL DEFAULT 0,
        muted INTEGER NOT NULL DEFAULT 0,
        soloed INTEGER NOT NULL DEFAULT 0,
        volume REAL NOT NULL DEFAULT 1.0,
        pan REAL NOT NULL DEFAULT 0.0
    );
]]

local DATA_SQL = [[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
]]

local function run_test()
    local tmp_db = os.tmpname() .. ".db"
    os.remove(tmp_db)
    assert(database.init(tmp_db))
    local conn = database.get_connection()
    assert(conn:exec(SCHEMA_SQL))
    assert(conn:exec(DATA_SQL))

    local executors = {}
    local undoers = {}
    command_impl.register_commands(executors, undoers, conn)

    local cmd = Command.create("CreateSequence", "default_project")
    cmd:set_parameter("project_id", "default_project")
    cmd:set_parameter("name", "Sequence Under Test")
    cmd:set_parameter("frame_rate", 30)
    cmd:set_parameter("width", 1920)
    cmd:set_parameter("height", 1080)

    assert(executors["CreateSequence"](cmd), "CreateSequence executor failed")
    local sequence_id = cmd:get_parameter("sequence_id")
    assert(sequence_id and sequence_id ~= "", "sequence_id was not set")

    local count_stmt = conn:prepare([[
        SELECT track_type, COUNT(*)
        FROM tracks
        WHERE sequence_id = ?
        GROUP BY track_type
    ]])
    count_stmt:bind_value(1, sequence_id)
    assert(count_stmt:exec())

    local counts = {}
    while count_stmt:next() do
        counts[count_stmt:value(0)] = count_stmt:value(1)
    end
    count_stmt:finalize()

    assert(counts["VIDEO"] == 3, string.format("expected 3 video tracks, found %s", tostring(counts["VIDEO"])))
    assert(counts["AUDIO"] == 3, string.format("expected 3 audio tracks, found %s", tostring(counts["AUDIO"])))

    os.remove(tmp_db)
end

run_test()
print("✅ create sequence default tracks test passed")
