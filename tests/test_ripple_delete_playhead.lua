#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')
local Command = require('command')
local Media = require('models.media')
local Clip = require('models.clip')
local timeline_state = require('ui.timeline.timeline_state')

local TEST_DB = "/tmp/jve/test_ripple_delete_playhead.db"
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

    CREATE TABLE media (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        file_path TEXT NOT NULL,
        duration INTEGER NOT NULL,
        frame_rate REAL NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        audio_channels INTEGER NOT NULL DEFAULT 0,
        codec TEXT,
        created_at INTEGER,
        modified_at INTEGER,
        metadata TEXT
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
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v2', 'default_sequence', 'Video 2', 'VIDEO', 2, 1);
]])

local function create_media(id, duration)
    local media = Media.create({
        id = id,
        project_id = 'default_project',
        file_path = '/tmp/jve/' .. id .. '.mov',
        name = id .. '.mov',
        duration = duration,
        frame_rate = 30,
        width = 1920,
        height = 1080,
        audio_channels = 2
    })
    assert(media, "failed to create media " .. id)
    assert(media:save(db), "failed to save media " .. id)
end

local function create_clip(id, track_id, start_time, duration, media_id)
    local clip = Clip.create("Clip " .. id, media_id, {
        id = id,
        project_id = 'default_project',
        track_id = track_id,
        owner_sequence_id = 'default_sequence',
        start_time = start_time,
        duration = duration,
        source_in = 0,
        source_out = duration,
        enabled = true,
        offline = false
    })
    assert(clip, "failed to allocate clip " .. id)
    assert(clip:save(db, {skip_occlusion = true}), "failed to persist clip " .. id)
end

local clip_specs = {
    {id = "clip_a", track = "track_v1", start = 0, duration = 1000},
    {id = "clip_b", track = "track_v1", start = 1000, duration = 1200},
    {id = "clip_c", track = "track_v1", start = 2200, duration = 800},
    {id = "clip_d", track = "track_v2", start = 900, duration = 1600},
}

for index, spec in ipairs(clip_specs) do
    local media_id = "media_" .. spec.id
    create_media(media_id, spec.duration)
    create_clip(spec.id, spec.track, spec.start, spec.duration, media_id)
end

timeline_state.init('default_sequence')

local executors = {}
local undoers = {}
command_impl.register_commands(executors, undoers, db)
command_manager.init(db, 'default_sequence', 'default_project')

local original_playhead = 8888
timeline_state.set_playhead_time(original_playhead)

local cmd = Command.create("RippleDeleteSelection", "default_project")
cmd:set_parameter("sequence_id", "default_sequence")
cmd:set_parameter("clip_ids", {"clip_b", "clip_d"})
local exec_result = command_manager.execute(cmd)
assert(exec_result.success, exec_result.error_message or "RippleDeleteSelection failed")

local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo failed for ripple delete")

local restored = timeline_state.get_playhead_time()
assert(restored == original_playhead,
    string.format("Undo should restore playhead to %d, got %d", original_playhead, restored))

print("✅ RippleDeleteSelection undo restores playhead using real timeline_state")
