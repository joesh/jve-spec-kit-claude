#!/usr/bin/env luajit

package.path = package.path
    .. ";./tests/?.lua"
    .. ";./src/lua/?.lua"
    .. ";./src/lua/core/?.lua"
    .. ";./src/lua/models/?.lua"
    .. ";./src/lua/ui/?.lua"
    .. ";./src/lua/ui/timeline/?.lua"

require("test_env")

local database = require("core.database")
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
        audio_sample_rate INTEGER NOT NULL DEFAULT 48000,
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
        name TEXT NOT NULL,
        track_type TEXT NOT NULL,
        timebase_type TEXT NOT NULL,
        timebase_rate REAL NOT NULL,
        track_index INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1
    );

    CREATE TABLE clips (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        clip_kind TEXT NOT NULL,
        name TEXT,
        track_id TEXT,
        media_id TEXT,
        source_sequence_id TEXT,
        parent_clip_id TEXT,
        owner_sequence_id TEXT,
        start_value INTEGER NOT NULL,
        duration_value INTEGER NOT NULL,
        source_in_value INTEGER NOT NULL,
        source_out_value INTEGER NOT NULL,
        timebase_type TEXT NOT NULL,
        timebase_rate REAL NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        offline INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE media (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
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
]]

local DATA_SQL = [[
    INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
    INSERT INTO sequences (id, project_id, name, frame_rate, audio_sample_rate, width, height, timecode_start_frame, playhead_frame, viewport_start_frame, viewport_duration_frames)
    VALUES
        ('seq_a', 'default_project', 'Active Seq', 30.0, 48000, 1920, 1080, 0, 0, 0, 240),
        ('seq_b', 'default_project', 'Background Seq', 30.0, 48000, 1920, 1080, 0, 0, 0, 240);
    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled)
    VALUES
        ('seq_a_v1', 'seq_a', 'V1', 'VIDEO', 'video_frames', 30.0, 1, 1),
        ('seq_b_v1', 'seq_b', 'V1', 'VIDEO', 'video_frames', 30.0, 1, 1);
]]

local tmp_db = os.tmpname() .. ".db"
os.remove(tmp_db)
assert(database.init(tmp_db))
local conn = database.get_connection()
assert(conn:exec(SCHEMA_SQL))
assert(conn:exec(DATA_SQL))

assert(timeline_state.init("seq_a"))
assert(timeline_state.get_sequence_id() == "seq_a", "expected active sequence to remain seq_a after init")

local reload_result = timeline_state.reload_clips("seq_b")
assert(reload_result == false, "reload_clips should skip when sequence_id differs")
assert(timeline_state.get_sequence_id() == "seq_a", "reload_clips should not switch active sequence")

local same_result = timeline_state.reload_clips("seq_a")
assert(same_result == true, "reload_clips should succeed for active sequence")
assert(timeline_state.get_sequence_id() == "seq_a", "active sequence should remain seq_a after valid reload")

os.remove(tmp_db)
print("✅ timeline reload guard test passed")
