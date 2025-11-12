#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local Command = require('command')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')

local TEST_DB = "/tmp/test_timeline_mutation_hydration.db"

local function setup_db()
    os.remove(TEST_DB)
    assert(database.init(TEST_DB))
    local conn = database.get_connection()
    assert(conn:exec([[
        CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT, settings TEXT DEFAULT '{}');
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
            selected_clip_ids TEXT DEFAULT '[]',
            selected_edge_infos TEXT DEFAULT '[]',
            viewport_start_time INTEGER DEFAULT 0,
            viewport_duration INTEGER DEFAULT 10000,
            mark_in_time INTEGER,
            mark_out_time INTEGER,
            current_sequence_number INTEGER DEFAULT 0
        );
        CREATE TABLE tracks (
            id TEXT PRIMARY KEY,
            sequence_id TEXT NOT NULL,
            name TEXT,
            track_type TEXT NOT NULL,
            track_index INTEGER NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1,
            locked INTEGER NOT NULL DEFAULT 0,
            muted INTEGER NOT NULL DEFAULT 0,
            soloed INTEGER NOT NULL DEFAULT 0,
            volume REAL DEFAULT 0,
            pan REAL DEFAULT 0
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
            created_at INTEGER DEFAULT 0,
            modified_at INTEGER DEFAULT 0
        );
        CREATE TABLE media (
            id TEXT PRIMARY KEY,
            project_id TEXT,
            file_path TEXT,
            name TEXT,
            duration INTEGER,
            frame_rate REAL,
            width INTEGER,
            height INTEGER,
            audio_channels INTEGER DEFAULT 0,
            codec TEXT DEFAULT '',
            created_at INTEGER DEFAULT 0,
            modified_at INTEGER DEFAULT 0,
            metadata TEXT DEFAULT '{}'
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
    ]]))

    assert(conn:exec([[
        INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
        INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
        VALUES ('default_sequence', 'default_project', 'Timeline', 30.0, 1920, 1080);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1);
        INSERT INTO media (id, project_id, file_path, name, duration, frame_rate)
        VALUES ('media_a', 'default_project', '/tmp/a.mov', 'Media A', 4000, 30.0);
        INSERT INTO media (id, project_id, file_path, name, duration, frame_rate)
        VALUES ('media_b', 'default_project', '/tmp/b.mov', 'Media B', 4000, 30.0);
        INSERT INTO clips (id, project_id, track_id, owner_sequence_id, start_time, duration, source_in, source_out, media_id)
        VALUES ('clip_a', 'default_project', 'track_v1', 'default_sequence', 0, 4000, 0, 4000, 'media_a');
        INSERT INTO clips (id, project_id, track_id, owner_sequence_id, start_time, duration, source_in, source_out, media_id)
        VALUES ('clip_b', 'default_project', 'track_v1', 'default_sequence', 4000, 4000, 0, 4000, 'media_b');
    ]]))

    command_impl.register_commands({}, {}, conn)
    command_manager.init(conn, 'default_sequence', 'default_project')
end

setup_db()

local timeline_state = require('ui.timeline.timeline_state')
local original_reload = timeline_state.reload_clips
local reload_count = 0
timeline_state.reload_clips = function(sequence_id, opts)
    reload_count = reload_count + 1
    if original_reload then
        return original_reload(sequence_id, opts)
    end
    return true
end

assert(timeline_state.init('default_sequence'))

assert(timeline_state.get_clip_by_id('clip_b') ~= nil, "clip_b should load initially")
timeline_state._internal_remove_clip_from_command('clip_b')
assert(timeline_state.get_clip_by_id('clip_b') == nil, "clip_b should be missing before mutation")

local ripple_cmd = Command.create("RippleEdit", "default_project")
ripple_cmd:set_parameter("edge_info", {
    clip_id = "clip_b",
    edge_type = "out",
    track_id = "track_v1"
})
ripple_cmd:set_parameter("delta_ms", -250)
ripple_cmd:set_parameter("sequence_id", "default_sequence")

local result = command_manager.execute(ripple_cmd)
assert(result.success, result.error_message or "RippleEdit should succeed")
assert(reload_count == 0, "Hydrated mutation should not trigger reload fallback")

local hydrated_clip = timeline_state.get_clip_by_id('clip_b')
assert(hydrated_clip, "clip_b should be hydrated back into state")
assert(hydrated_clip.duration < 4000, "Ripple trim should update hydrated clip")

print("✅ Timeline state hydrates missing clips during mutation replay without reload fallback")
