#!/usr/bin/env luajit

-- Regression: GoToStart and GoToEnd commands should move the playhead without
-- polluting the undo log or failing with "Unknown command type".

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')

local TEST_DB = "/tmp/jve/test_timeline_navigation.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec([[
    CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        settings TEXT NOT NULL DEFAULT '{}'
    );

            CREATE TABLE IF NOT EXISTS sequences (
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
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        file_path TEXT NOT NULL,
        duration INTEGER NOT NULL,
        frame_rate REAL NOT NULL,
        width INTEGER DEFAULT 0,
        height INTEGER DEFAULT 0,
        audio_channels INTEGER DEFAULT 0,
        codec TEXT DEFAULT '',
        created_at INTEGER DEFAULT 0,
        modified_at INTEGER DEFAULT 0,
        metadata TEXT DEFAULT '{}'
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
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('track_v1', 'default_sequence', 'Track', 'VIDEO', 1, 1);
]])

db:exec([[
    INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, created_at, modified_at, metadata)
    VALUES ('media_clip_a', 'default_project', 'clip_a.mov', '/tmp/jve/clip_a.mov', 1000, 30.0, 0, 0, '{}');
    INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, created_at, modified_at, metadata)
    VALUES ('media_clip_b', 'default_project', 'clip_b.mov', '/tmp/jve/clip_b.mov', 1500, 30.0, 0, 0, '{}');

    INSERT INTO clips (id, track_id, media_id, start_time, duration, source_in, source_out, enabled)
    VALUES ('clip_a', 'track_v1', 'media_clip_a', 0, 1000, 0, 1000, 1);
    INSERT INTO clips (id, track_id, media_id, start_time, duration, source_in, source_out, enabled)
    VALUES ('clip_b', 'track_v1', 'media_clip_b', 2000, 1500, 0, 1500, 1);
]])

local timeline_state = {
    playhead_time = 500,
    clips = {
        {id = 'clip_a', start_time = 0, duration = 1000},
        {id = 'clip_b', start_time = 2000, duration = 1500}
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

print("=== Timeline Navigation Command Tests ===\n")

local result = command_manager.execute("GoToStart")
assert(result.success == true, "GoToStart should succeed")
assert(timeline_state.playhead_time == 0, "GoToStart must set playhead to 0")

timeline_state.playhead_time = 321 -- ensure we move again

result = command_manager.execute("GoToEnd")
assert(result.success == true, "GoToEnd should succeed")
assert(timeline_state.playhead_time == 3500,
    string.format("GoToEnd must set playhead to timeline end (expected 3500, got %d)", timeline_state.playhead_time))

print("✅ GoToStart/GoToEnd navigation commands adjust playhead correctly")
