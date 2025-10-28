#!/usr/bin/env luajit

-- Regression: GoToPrevEdit / GoToNextEdit should move the playhead to the
-- nearest clip boundary without creating undo entries.

require('test_env')

local dkjson = require('dkjson')
local database = require('core.database')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')

local TEST_DB = "/tmp/test_timeline_edit_navigation.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec([[
    CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        settings TEXT NOT NULL DEFAULT '{}'
    );

    CREATE TABLE sequences (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        frame_rate REAL NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        timecode_start INTEGER NOT NULL DEFAULT 0,
        playhead_time INTEGER NOT NULL DEFAULT 0,
        selected_clip_ids TEXT DEFAULT '[]',
        selected_edge_infos TEXT DEFAULT '[]',
        current_sequence_number INTEGER
    );

    CREATE TABLE tracks (
        id TEXT PRIMARY KEY,
        sequence_id TEXT NOT NULL,
        track_type TEXT NOT NULL,
        track_index INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1
    );

    CREATE TABLE clips (
        id TEXT PRIMARY KEY,
        track_id TEXT NOT NULL,
        start_time INTEGER NOT NULL,
        duration INTEGER NOT NULL,
        source_in INTEGER NOT NULL DEFAULT 0,
        source_out INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1
    );

    CREATE TABLE commands (
        id TEXT PRIMARY KEY,
        parent_id TEXT,
        parent_sequence_number INTEGER,
        sequence_number INTEGER UNIQUE NOT NULL,
        command_type TEXT NOT NULL,
        command_args TEXT,
        pre_hash TEXT,
        post_hash TEXT,
        timestamp INTEGER,
        playhead_time INTEGER DEFAULT 0,
        selected_clip_ids TEXT DEFAULT '[]',
        selected_edge_infos TEXT DEFAULT '[]',
        selected_clip_ids_pre TEXT DEFAULT '[]',
        selected_edge_infos_pre TEXT DEFAULT '[]'
    );
]])

db:exec([[
    INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
    INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
    VALUES ('default_sequence', 'default_project', 'Sequence', 30.0, 1920, 1080);
    INSERT INTO tracks (id, sequence_id, track_type, track_index, enabled)
    VALUES ('track_v1', 'default_sequence', 'VIDEO', 1, 1);
    INSERT INTO tracks (id, sequence_id, track_type, track_index, enabled)
    VALUES ('track_v2', 'default_sequence', 'VIDEO', 2, 1);
]])

-- Timeline layout (in ms):
-- V1: clip_a [0, 1500), clip_b [3000, 4500)
-- V2: clip_c [1200, 2400), clip_d [5000, 6200)
db:exec([[
    INSERT INTO clips (id, track_id, start_time, duration, source_in, source_out, enabled)
    VALUES ('clip_a', 'track_v1', 0, 1500, 0, 1500, 1);
    INSERT INTO clips (id, track_id, start_time, duration, source_in, source_out, enabled)
    VALUES ('clip_b', 'track_v1', 3000, 1500, 0, 1500, 1);
    INSERT INTO clips (id, track_id, start_time, duration, source_in, source_out, enabled)
    VALUES ('clip_c', 'track_v2', 1200, 1200, 0, 1200, 1);
    INSERT INTO clips (id, track_id, start_time, duration, source_in, source_out, enabled)
    VALUES ('clip_d', 'track_v2', 5000, 1200, 0, 1200, 1);
]])

local timeline_state = {
    playhead_time = 2500,
    clips = {
        {id = 'clip_a', start_time = 0, duration = 1500},
        {id = 'clip_c', start_time = 1200, duration = 1200},
        {id = 'clip_b', start_time = 3000, duration = 1500},
        {id = 'clip_d', start_time = 5000, duration = 1200},
    },
    viewport_start_time = 0,
    viewport_duration = 10000
}

function timeline_state.get_selected_clips() return {} end
function timeline_state.get_selected_edges() return {} end
function timeline_state.normalize_edge_selection() end
function timeline_state.clear_edge_selection() end
function timeline_state.set_selection(_) end
function timeline_state.reload_clips() end
function timeline_state.persist_state_to_db() end
function timeline_state.get_playhead_time() return timeline_state.playhead_time end
function timeline_state.set_playhead_time(time_ms) timeline_state.playhead_time = time_ms end
function timeline_state.get_clips() return timeline_state.clips end

local viewport_guard = 0

function timeline_state.capture_viewport()
    return {
        start_time = timeline_state.viewport_start_time,
        duration = timeline_state.viewport_duration,
    }
end

function timeline_state.restore_viewport(snapshot)
    if not snapshot then
        return
    end

    if snapshot.duration then
        timeline_state.viewport_duration = snapshot.duration
    end

    if snapshot.start_time then
        timeline_state.viewport_start_time = snapshot.start_time
    end
end

function timeline_state.push_viewport_guard()
    viewport_guard = viewport_guard + 1
    return viewport_guard
end

function timeline_state.pop_viewport_guard()
    if viewport_guard > 0 then
        viewport_guard = viewport_guard - 1
    end
    return viewport_guard
end

package.loaded['ui.timeline.timeline_state'] = timeline_state

local executors = {}
local undoers = {}
command_impl.register_commands(executors, undoers, db)

command_manager.init(db, 'default_sequence', 'default_project')

print("=== Timeline Edit Navigation Tests ===\n")

local result = command_manager.execute("GoToPrevEdit")
assert(result.success == true, "GoToPrevEdit should succeed")
assert(timeline_state.playhead_time == 2400,
    string.format("GoToPrevEdit expected 2400, got %d", timeline_state.playhead_time))

timeline_state.playhead_time = 3200

result = command_manager.execute("GoToNextEdit")
assert(result.success == true, "GoToNextEdit should succeed")
assert(timeline_state.playhead_time == 4500,
    string.format("GoToNextEdit expected 4500, got %d", timeline_state.playhead_time))

timeline_state.playhead_time = 6200
result = command_manager.execute("GoToNextEdit")
assert(result.success == true, "GoToNextEdit should succeed even at timeline end")
assert(timeline_state.playhead_time == 6200,
    string.format("GoToNextEdit at end should stay at 6200, got %d", timeline_state.playhead_time))

print("✅ GoToPrevEdit/GoToNextEdit navigation commands adjust playhead correctly")
