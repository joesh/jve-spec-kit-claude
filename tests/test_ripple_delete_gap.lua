#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')
local Command = require('command')
local Clip = require('models.clip')
local Media = require('models.media')

local TEST_DB = "/tmp/test_ripple_delete_gap.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

assert(db:exec([[
    CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
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
        selected_edge_infos_pre TEXT DEFAULT '[]',
        selected_gap_infos TEXT DEFAULT '[]',
        selected_gap_infos_pre TEXT DEFAULT '[]'
    );

    INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
    INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
    VALUES ('default_sequence', 'default_project', 'Sequence', 30.0, 1920, 1080);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v2', 'default_sequence', 'Video 2', 'VIDEO', 2, 1);
]]))

local function ensure_media(id, duration)
    local media = Media.create({
        id = id,
        project_id = 'default_project',
        name = id,
        file_path = '/tmp/' .. id .. '.mov',
        duration = duration,
        frame_rate = 30,
        width = 1920,
        height = 1080,
    })
    assert(media, "failed to create media")
    assert(media:save(db), "failed to save media")
    return media.id
end

local function insert_clip(id, track_id, start_time, duration)
    local media_id = ensure_media(id .. "_media", duration)
    local clip = Clip.create(id, media_id, {
        id = id,
        project_id = 'default_project',
        track_id = track_id,
        owner_sequence_id = 'default_sequence',
        start_time = start_time,
        duration = duration,
        source_in = 0,
        source_out = duration,
        enabled = true,
    })
    assert(clip:save(db, {skip_occlusion = true}), "failed to save clip " .. id)
end

local function fetch_clip_start(id)
    local stmt = db:prepare("SELECT start_time FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "clip not found: " .. tostring(id))
    local value = stmt:value(0)
    stmt:finalize()
    return value
end

insert_clip("clip_a", "track_v1", 0, 1000)
insert_clip("clip_b", "track_v1", 2000, 500)
insert_clip("clip_c", "track_v2", 2000, 500)

local timeline_state = {
    playhead_time = 0,
}

function timeline_state.get_selected_clips() return {} end
function timeline_state.get_selected_edges() return {} end
function timeline_state.clear_edge_selection() end
function timeline_state.clear_gap_selection() end
function timeline_state.set_selection() end
function timeline_state.reload_clips() end
function timeline_state.persist_state_to_db() end
function timeline_state.apply_mutations(sequence_id, mutations)
    return mutations ~= nil
end
function timeline_state.consume_mutation_failure()
    return nil
end
function timeline_state.get_clips()
    local clips = {}
    local stmt = db:prepare("SELECT id, track_id, start_time, duration FROM clips ORDER BY track_id, start_time")
    if stmt:exec() then
        while stmt:next() do
            clips[#clips + 1] = {
                id = stmt:value(0),
                track_id = stmt:value(1),
                start_time = stmt:value(2),
                duration = stmt:value(3)
            }
        end
    end
    stmt:finalize()
    return clips
end
function timeline_state.get_sequence_id() return "default_sequence" end
function timeline_state.get_project_id() return "default_project" end
function timeline_state.get_playhead_time() return timeline_state.playhead_time end
function timeline_state.set_playhead_time(t) timeline_state.playhead_time = t end
function timeline_state.push_viewport_guard() return 1 end
function timeline_state.pop_viewport_guard() return 0 end
function timeline_state.capture_viewport() return {start_time = 0, duration = 10000} end
function timeline_state.restore_viewport(_) end
function timeline_state.get_viewport_start_time() return 0 end
function timeline_state.get_viewport_duration() return 10000 end
function timeline_state.set_viewport_start_time(_) end
function timeline_state.set_viewport_duration(_) end
function timeline_state.set_dragging_playhead(_) end
function timeline_state.is_dragging_playhead() return false end
function timeline_state.get_selected_gaps() return {} end
function timeline_state.get_all_tracks()
    return {
        {id = "track_v1", track_type = "VIDEO"},
        {id = "track_v2", track_type = "VIDEO"},
    }
end
function timeline_state.get_track_height(_) return 50 end
function timeline_state.time_to_pixel(time_ms, _) return time_ms end
function timeline_state.pixel_to_time(x, _) return x end
function timeline_state.get_sequence_frame_rate() return 30 end

package.loaded['ui.timeline.timeline_state'] = timeline_state

local executors = {}
local undoers = {}
command_impl.register_commands(executors, undoers, db)
command_manager.init(db, 'default_sequence', 'default_project')

local function exec_ripple()
    local cmd = Command.create("RippleDelete", "default_project")
    cmd:set_parameter("track_id", "track_v1")
    cmd:set_parameter("sequence_id", "default_sequence")
    cmd:set_parameter("gap_start", 1000)
    cmd:set_parameter("gap_duration", 1000)
    local result = command_manager.execute(cmd)
    assert(result.success, result.error_message or "RippleDelete failed")
end

local function assert_close(expected, actual, label)
    if math.abs(expected - actual) > 0 then
        error(string.format("%s expected %d, got %d", label, expected, actual))
    end
end

-- Execute ripple delete: both tracks should shift
exec_ripple()
assert_close(1000, fetch_clip_start("clip_b"), "clip_b start")
assert_close(1000, fetch_clip_start("clip_c"), "clip_c start")

-- Undo should restore original positions
local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo failed")
assert_close(2000, fetch_clip_start("clip_b"), "clip_b undo start")
assert_close(2000, fetch_clip_start("clip_c"), "clip_c undo start")

-- Redo should shift again on all tracks
local redo_result = command_manager.redo()
assert(redo_result.success, redo_result.error_message or "Redo failed")
assert_close(1000, fetch_clip_start("clip_b"), "clip_b redo start")
assert_close(1000, fetch_clip_start("clip_c"), "clip_c redo start")

print("✅ RippleDelete gap ripple test passed")
