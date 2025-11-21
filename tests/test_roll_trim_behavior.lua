#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")
local Command = require("command")

local TEST_DB = "/tmp/jve/test_roll_trim_behavior.db"
os.remove(TEST_DB)

assert(database.init(TEST_DB))
local db = database.get_connection()

local schema = [[
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
        audio_sample_rate INTEGER NOT NULL DEFAULT 48000,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        timecode_start_frame INTEGER NOT NULL DEFAULT 0,
        playhead_value INTEGER NOT NULL DEFAULT 0,
        selected_clip_ids TEXT,
        selected_edge_infos TEXT,
        viewport_start_value INTEGER NOT NULL DEFAULT 0,
        viewport_duration_frames_value INTEGER NOT NULL DEFAULT 240,
        mark_in_value INTEGER,
        mark_out_value INTEGER,
        current_sequence_number INTEGER
    );

    CREATE TABLE tracks (
        id TEXT PRIMARY KEY,
        sequence_id TEXT NOT NULL,
        name TEXT NOT NULL,
        track_type TEXT NOT NULL,
        timebase_type TEXT NOT NULL,
        timebase_rate REAL NOT NULL,
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
        duration_value INTEGER,
        timebase_type TEXT NOT NULL,
        timebase_rate REAL NOT NULL,
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
        start_value INTEGER NOT NULL,
        duration_value INTEGER NOT NULL,
        source_in_value INTEGER NOT NULL DEFAULT 0,
        source_out_value INTEGER NOT NULL,
        timebase_type TEXT NOT NULL,
        timebase_rate REAL NOT NULL,
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
        playhead_value INTEGER DEFAULT 0,
        playhead_rate REAL DEFAULT 0,
        selected_clip_ids TEXT DEFAULT '[]',
        selected_edge_infos TEXT DEFAULT '[]',
        selected_gap_infos TEXT DEFAULT '[]',
        selected_clip_ids_pre TEXT DEFAULT '[]',
        selected_edge_infos_pre TEXT DEFAULT '[]',
        selected_gap_infos_pre TEXT DEFAULT '[]'
    );
]]

assert(db:exec(schema))

local now = os.time()

local seed = string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, frame_rate, audio_sample_rate, width, height, timecode_start_frame, playhead_value, viewport_start_value, viewport_duration_frames_value)
    VALUES ('default_sequence', 'default_project', 'Timeline', 'timeline', 30.0, 48000, 1920, 1080, 0, 0, 0, 240);

    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled)
    VALUES ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 'video_frames', 30.0, 1, 1);

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id,
                       start_value, duration_value, source_in_value, source_out_value, timebase_type, timebase_rate, enabled, offline,
                       created_at, modified_at)
    VALUES
        ('clip_left', 'default_project', 'timeline', 'Left', 'track_v1', 'default_sequence',
         0, 1000, 0, 1000, 'video_frames', 30.0, 1, 0, %d, %d),
        ('clip_right', 'default_project', 'timeline', 'Right', 'track_v1', 'default_sequence',
         1000, 1000, 0, 1000, 'video_frames', 30.0, 1, 0, %d, %d),
        ('clip_downstream', 'default_project', 'timeline', 'Downstream', 'track_v1', 'default_sequence',
         2000, 1000, 0, 1000, 'video_frames', 30.0, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now)

assert(db:exec(seed))

-- Minimal timeline_state stubs (command_manager expects these callbacks)
timeline_state.get_project_id = function() return "default_project" end
timeline_state.get_sequence_id = function() return "default_sequence" end
timeline_state.reload_clips = function() end
timeline_state.set_playhead_value = function(_) end
timeline_state.capture_viewport = function() return {start_value = 0, duration_value = 3000, timebase_type = "video_frames", timebase_rate = 30.0} end
timeline_state.push_viewport_guard = function() end
timeline_state.pop_viewport_guard = function() end
timeline_state.restore_viewport = function(_) end
timeline_state.set_selection = function(_) end
timeline_state.set_edge_selection = function(_) end
timeline_state.set_gap_selection = function(_) end

command_manager.init(db, "default_sequence", "default_project")

local function fetch_start(clip_id)
    local stmt = db:prepare("SELECT start_value FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next(), "missing clip " .. tostring(clip_id))
    local value = tonumber(stmt:value(0))
    stmt:finalize()
    return value
end

local function fetch_duration(clip_id)
    local stmt = db:prepare("SELECT duration_value FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next(), "missing clip " .. tostring(clip_id))
    local value = tonumber(stmt:value(0))
    stmt:finalize()
    return value
end

local roll_edges = {
    {clip_id = "clip_left", edge_type = "out", track_id = "track_v1", trim_type = "roll"},
    {clip_id = "clip_right", edge_type = "in", track_id = "track_v1", trim_type = "roll"},
}

local cmd = Command.create("BatchRippleEdit", "default_project")
cmd:set_parameter("edge_infos", roll_edges)
cmd:set_parameter("delta_ms", 120)
cmd:set_parameter("sequence_id", "default_sequence")

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit execution failed")

-- Expected roll behaviour: downstream clip stays anchored, combined boundary shifts locally.
assert(fetch_start("clip_downstream") == 2000, "Roll edit should not ripple downstream clips")
assert(fetch_duration("clip_left") == 1120, "Roll edit should extend left clip duration")
assert(fetch_start("clip_right") == 1120, "Roll edit should adjust right clip start")

local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo failed after roll edit")
assert(fetch_start("clip_downstream") == 2000, "Undo should restore downstream clip position")
assert(fetch_duration("clip_left") == 1000, "Undo should restore left clip duration")
assert(fetch_start("clip_right") == 1000, "Undo should restore right clip start")

os.remove(TEST_DB)
print("✅ Roll trim regression fixed")
