#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s\nExpected: %s\nActual:   %s", message or "assert_equal failed", tostring(expected), tostring(actual)))
    end
end

-- Provide lightweight stubs so replay does not depend on Qt timelines
timeline_state.capture_viewport = function()
    return {start = 0, duration = 1000}
end
timeline_state.push_viewport_guard = function() end
timeline_state.pop_viewport_guard = function() end
timeline_state.restore_viewport = function(_) end
timeline_state.set_selection = function(_) end
timeline_state.get_selected_clips = function() return {} end
timeline_state.set_edge_selection = function(_) end
timeline_state.get_selected_edges = function() return {} end
timeline_state.set_playhead_time = function(_) end
timeline_state.get_playhead_time = function() return 0 end
timeline_state.reload_clips = function() end

local function row_count(db, sql, value)
    local stmt = db:prepare(sql)
    if not stmt then
        error("Failed to prepare statement: " .. sql)
    end
    if value ~= nil then
        stmt:bind_value(1, value)
    end
    local count = 0
    if stmt:exec() and stmt:next() then
        count = stmt:value(0) or 0
    end
    stmt:finalize()
    return count
end

local db_path = "/tmp/jve/test_command_manager_replay_initial_state.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

db:exec([[
    CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        modified_at INTEGER NOT NULL,
        settings TEXT DEFAULT '{}'
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
        enabled BOOLEAN NOT NULL DEFAULT 1,
        locked BOOLEAN NOT NULL DEFAULT 0,
        muted BOOLEAN NOT NULL DEFAULT 0,
        soloed BOOLEAN NOT NULL DEFAULT 0,
        volume REAL NOT NULL DEFAULT 1.0,
        pan REAL NOT NULL DEFAULT 0.0
    );

    CREATE TABLE media (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT,
        file_path TEXT,
        duration INTEGER DEFAULT 0,
        frame_rate REAL DEFAULT 0
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
        source_in INTEGER NOT NULL,
        source_out INTEGER NOT NULL,
        enabled BOOLEAN NOT NULL DEFAULT 1,
        offline BOOLEAN NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        modified_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
    );

    CREATE TABLE properties (
        id TEXT PRIMARY KEY,
        clip_id TEXT NOT NULL,
        property_name TEXT NOT NULL,
        property_value TEXT NOT NULL,
        property_type TEXT NOT NULL CHECK(property_type IN ('STRING', 'NUMBER', 'BOOLEAN', 'COLOR', 'ENUM')),
        default_value TEXT NOT NULL,
        FOREIGN KEY (clip_id) REFERENCES clips(id) ON DELETE CASCADE,
        UNIQUE(clip_id, property_name)
    );

    CREATE INDEX IF NOT EXISTS idx_properties_clip ON properties(clip_id);

    CREATE TABLE commands (
        id TEXT PRIMARY KEY,
        parent_id TEXT,
        parent_sequence_number INTEGER,
        sequence_number INTEGER UNIQUE NOT NULL,
        command_type TEXT NOT NULL,
        command_args TEXT NOT NULL,
        pre_hash TEXT NOT NULL,
        post_hash TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        playhead_time INTEGER NOT NULL DEFAULT 0,
        selected_clip_ids TEXT,
        selected_edge_infos TEXT,
        selected_clip_ids_pre TEXT,
        selected_edge_infos_pre TEXT
    );
]])

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('test_project', 'Replay Test Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, frame_rate, width, height,
        timecode_start, playhead_time, selected_clip_ids, selected_edge_infos,
        viewport_start_time, viewport_duration, current_sequence_number)
    VALUES ('timeline_seq', 'test_project', 'Timeline Seq', 'timeline',
        24.0, 1920, 1080, 0, 0, '[]', '[]', 0, 10000, NULL);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
    VALUES ('track_v1', 'timeline_seq', 'V1', 'VIDEO', 1);

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id,
        start_time, duration, source_in, source_out, enabled)
    VALUES ('clip_001', 'test_project', 'timeline', 'Existing Clip',
        'track_v1', 'timeline_seq', 0, 2000, 0, 2000, 1);
]], now, now))

-- No commands yet, but timeline has existing clip
command_manager.init(db, "timeline_seq", "test_project")
command_manager.activate_timeline_stack("timeline_seq")

local initial_clips = database.load_clips("timeline_seq") or {}
assert_equal(#initial_clips, 1, "Expected database.load_clips to see existing timeline clip")

local before_clip_count = row_count(db, "SELECT COUNT(*) FROM clips WHERE owner_sequence_id = 'timeline_seq'")
assert_equal(before_clip_count, 1, "Expected initial timeline clip to exist before replay")

local replay_success = command_manager.replay_events("timeline_seq", 0)
assert_equal(replay_success, true, "Replay should succeed even when only initial state exists")

local after_clip_count = row_count(db, "SELECT COUNT(*) FROM clips WHERE owner_sequence_id = 'timeline_seq'")
assert_equal(after_clip_count, 1, "Initial timeline clip must persist after replay")

print("✅ command_manager initial state replay test passed")
