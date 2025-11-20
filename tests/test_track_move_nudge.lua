#!/usr/bin/env luajit

-- Regression test: moving a clip to another track and nudging it in a
-- single BatchCommand must not trim the clip that already lives on the
-- destination track. This used to happen because the MoveClipToTrack
-- command ran occlusion resolution before the follow-up nudge supplied
-- the clip's new time position.

require('test_env')

local dkjson = require('dkjson')
local database = require('core.database')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')
local Command = require('command')

local TEST_DB = "/tmp/jve/test_track_move_nudge.db"
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
        frame_rate REAL NOT NULL, audio_sample_rate INTEGER NOT NULL DEFAULT 48000,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        timecode_start_frame INTEGER NOT NULL DEFAULT 0,
        playhead_frame INTEGER NOT NULL DEFAULT 0,
        selected_clip_ids TEXT,
        selected_edge_infos TEXT,
        viewport_start_frame INTEGER NOT NULL DEFAULT 0,
        viewport_duration_frames INTEGER NOT NULL DEFAULT 240,
        mark_in_time INTEGER,
        mark_out_time INTEGER,
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

    CREATE TABLE media (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        file_path TEXT NOT NULL,
        duration_value INTEGER NOT NULL,
        frame_rate REAL NOT NULL,
        width INTEGER DEFAULT 0,
        height INTEGER DEFAULT 0,
        audio_channels INTEGER DEFAULT 0,
        codec TEXT DEFAULT '',
        created_at INTEGER DEFAULT 0,
        modified_at INTEGER DEFAULT 0,
        metadata TEXT DEFAULT '{}' NOT NULL
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
            duration INTEGER NOT NULL,
            source_in_value INTEGER NOT NULL DEFAULT 0,
            source_out_value INTEGER NOT NULL,
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
    INSERT INTO sequences (id, project_id, name, frame_rate, audio_sample_rate, width, height, timecode_start_frame, playhead_frame, viewport_start_frame, viewport_duration_frames)
    VALUES ('default_sequence', 'default_project', 'Sequence', 30.0, 48000, 1920, 1080, 0, 0, 0, 240);
    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled) VALUES ('track_v1', 'default_sequence', 'Track', 'VIDEO', 'video_frames', 30.0, 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('track_v2', 'default_sequence', 'Track', 'VIDEO', 'video_frames', 30.0, 2, 1);
]])

-- Existing clips:
--   track_v2: clip_dest (500-3000)
--   track_v1: clip_keep (0-2000), clip_move (2000-3500)
local clip_move_start = 2000
local clip_move_duration = 1500
local nudge_amount_ms = 2000

db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, created_at, modified_at, metadata)
    VALUES ('media_dest', 'default_project', 'clip_dest.mov', '/tmp/jve/clip_dest.mov', 2500, 30.0, 0, 0, '{}');
    INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, created_at, modified_at, metadata)
    VALUES ('media_keep', 'default_project', 'clip_keep.mov', '/tmp/jve/clip_keep.mov', 2000, 30.0, 0, 0, '{}');
    INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, created_at, modified_at, metadata)
    VALUES ('media_move', 'default_project', 'clip_move.mov', '/tmp/jve/clip_move.mov', %d, 30.0, 0, 0, '{}');
]], clip_move_duration))

db:exec(string.format([[
    INSERT INTO clips (id, track_id, media_id, start_time, duration, source_in, source_out)
    VALUES ('clip_dest', 'track_v2', 'media_dest', 500, 2500, 0, 2500);
    INSERT INTO clips (id, track_id, media_id, start_time, duration, source_in, source_out)
    VALUES ('clip_keep', 'track_v1', 'media_keep', 0, 2000, 0, 2000);
    INSERT INTO clips (id, track_id, media_id, start_time, duration, source_in, source_out)
    VALUES ('clip_move', 'track_v1', 'media_move', %d, %d, 0, %d);
]], clip_move_start, clip_move_duration, clip_move_duration))

-- Minimal stub for timeline state used by command_manager internals.
local timeline_state = {
    get_selected_clips = function() return {} end,
    get_selected_edges = function() return {} end,
    normalize_edge_selection = function() end,
    clear_edge_selection = function() end,
    set_selection = function() end,
    reload_clips = function() end,
    persist_state_to_db = function() end,
    get_playhead_time = function() return 0 end,
    set_playhead_time = function() end,
    viewport_start_time = 0,
    viewport_duration = 10000,
    get_clips = function()
        local clips = {}
        local stmt = db:prepare("SELECT id FROM clips ORDER BY start_time")
        if stmt and stmt:exec() then
            while stmt:next() do
                clips[#clips + 1] = { id = stmt:value(0) }
            end
        end
        return clips
    end
}

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

print("=== MoveClipToTrack + Nudge Regression ===\n")

local function fetch_clip(id)
    local stmt = db:prepare("SELECT start_time, duration FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "clip not found: " .. id)
    return stmt:value(0), stmt:value(1)
end

local original_start, original_duration = fetch_clip('clip_dest')

local commands_json = dkjson.encode({
    {
        command_type = "MoveClipToTrack",
        parameters = {
            clip_id = "clip_move",
            target_track_id = "track_v2",
            skip_occlusion = true,
            pending_new_start_time = clip_move_start + nudge_amount_ms,
            pending_duration = clip_move_duration
        }
    },
    {
        command_type = "Nudge",
        parameters = {
            nudge_amount_ms = nudge_amount_ms, -- move to the right, clearing the overlap
            selected_clip_ids = {"clip_move"}
        }
    }
})

local batch_cmd = Command.create("BatchCommand", "default_project")
batch_cmd:set_parameter("commands_json", commands_json)

local result = command_manager.execute(batch_cmd)
assert(result.success, "BatchCommand execution failed: " .. tostring(result.error_message))

local new_start, new_duration = fetch_clip('clip_dest')

assert(new_start == original_start,
    string.format("Destination clip start changed: %d -> %d", original_start, new_start))
assert(new_duration == original_duration,
    string.format("Destination clip duration changed: %d -> %d", original_duration, new_duration))

print("✅ MoveClipToTrack + Nudge preserves upstream clip on destination track")
