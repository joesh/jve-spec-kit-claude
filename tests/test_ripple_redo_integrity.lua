#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;../tests/?.lua"

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')
local timeline_state = require('ui.timeline.timeline_state')
local Media = require('models.media')

local function setup_db(path)
    os.remove(path)
    database.init(path)
    local conn = database.get_connection()

    conn:exec([[
CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, settings TEXT NOT NULL DEFAULT '{}');
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
    name TEXT,
    track_type TEXT NOT NULL,
    track_index INTEGER NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE clips (
    id TEXT PRIMARY KEY,
    track_id TEXT NOT NULL,
    media_id TEXT,
    start_time INTEGER NOT NULL,
    duration INTEGER NOT NULL,
    source_in INTEGER NOT NULL DEFAULT 0,
    source_out INTEGER NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE media (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    file_path TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
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
    ]])

    conn:exec([[
INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
VALUES ('default_sequence', 'default_project', 'Default Sequence', 30.0, 1920, 1080);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
VALUES ('track_default_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1);
    ]])

    command_manager.init(conn, 'default_sequence', 'default_project')
    timeline_state.init('default_sequence')

    command_manager.register_executor("TestCreateMedia", function(cmd)
        local media = Media.create({
            id = cmd:get_parameter("media_id"),
            project_id = cmd:get_parameter("project_id") or 'default_project',
            file_path = cmd:get_parameter("file_path"),
            file_name = cmd:get_parameter("file_name"),
            name = cmd:get_parameter("file_name"),
            duration = cmd:get_parameter("duration"),
            frame_rate = cmd:get_parameter("frame_rate") or 30
        })
        assert(media, "failed to create media " .. tostring(cmd:get_parameter("media_id")))
        return media:save(conn)
    end)

    return conn
end

local db = setup_db("/tmp/test_ripple_redo_integrity.db")

local media_cmd = Command.create("TestCreateMedia", "default_project")
media_cmd:set_parameter("media_id", "media_src")
media_cmd:set_parameter("file_path", "/tmp/media_src.mov")
media_cmd:set_parameter("file_name", "Test Media")
media_cmd:set_parameter("duration", 10000000)
media_cmd:set_parameter("frame_rate", 30)
local media_result = command_manager.execute(media_cmd)
assert(media_result.success, media_result.error_message or "TestCreateMedia failed")


local function exec(cmd)
    local result = command_manager.execute(cmd)
    assert(result.success, "Command failed: " .. tostring(result.error_message))
    return result
end

local function clip_count()
    local stmt = db:prepare("SELECT COUNT(*) FROM clips")
    assert(stmt:exec(), "Failed to count clips")
    assert(stmt:next(), "Count query produced no rows")
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

local insert_cmd = Command.create("Insert", "default_project")
insert_cmd:set_parameter("media_id", "media_src")
insert_cmd:set_parameter("track_id", "track_default_v1")
insert_cmd:set_parameter("insert_time", 0)
insert_cmd:set_parameter("duration", 4543560)
insert_cmd:set_parameter("source_in", 0)
insert_cmd:set_parameter("source_out", 4543560)
insert_cmd:set_parameter("sequence_id", "default_sequence")
exec(insert_cmd)

local stmt = db:prepare("SELECT id FROM clips LIMIT 1")
assert(stmt:exec() and stmt:next(), "Inserted clip not found")
local clip_id = stmt:value(0)
stmt:finalize()

local ripple_cmd = Command.create("RippleEdit", "default_project")
ripple_cmd:set_parameter("edge_info", {clip_id = clip_id, edge_type = "gap_before", track_id = "track_default_v1"})
ripple_cmd:set_parameter("delta_ms", -5000000)  -- Delete the clip entirely
ripple_cmd:set_parameter("sequence_id", "default_sequence")
exec(ripple_cmd)

local function snapshot_clips()
    local stmt = db:prepare("SELECT id, track_id, start_time, duration, source_in, source_out FROM clips ORDER BY track_id, start_time")
    assert(stmt:exec(), "Failed to fetch clips for snapshot")

    local clips = {}
    while stmt:next() do
        clips[#clips + 1] = {
            id = stmt:value(0),
            track_id = stmt:value(1),
            start_time = stmt:value(2),
            duration = stmt:value(3),
            source_in = stmt:value(4),
            source_out = stmt:value(5),
        }
    end
    stmt:finalize()
    return clips
end

local function states_match(expected, actual)
    if #expected ~= #actual then
        return false
    end
    for idx = 1, #expected do
        local want = expected[idx]
        local got = actual[idx]
        for _, field in ipairs({"id", "track_id", "start_time", "duration", "source_in", "source_out"}) do
            if want[field] ~= got[field] then
                return false, string.format(
                    "clip mismatch at index %d field %s (expected=%s, actual=%s)",
                    idx,
                    field,
                    tostring(want[field]),
                    tostring(got[field])
                )
            end
        end
    end
    return true
end

local state_after_ripple = snapshot_clips()
local clip_count_after_ripple = clip_count()

assert(command_manager.undo().success, "Undo failed")
assert(clip_count() == 1, "Undo should restore the original clip")

assert(command_manager.redo().success, "Redo failed")
assert(clip_count() == clip_count_after_ripple, "Redo should return to post-ripple clip count")

local redo_state = snapshot_clips()
local ok, mismatch = states_match(state_after_ripple, redo_state)
assert(ok, mismatch or "Redo clip state differs from original post-ripple state")

print("✅ Ripple redo preserves clip deletions")

-- Regression: extending a clip keeps the downstream neighbour adjacent (no gaps)
db = setup_db("/tmp/test_ripple_gap_alignment.db")

media_cmd = Command.create("TestCreateMedia", "default_project")
media_cmd:set_parameter("media_id", "media_src")
media_cmd:set_parameter("file_path", "/tmp/media_src.mov")
media_cmd:set_parameter("file_name", "Test Media")
media_cmd:set_parameter("duration", 10000000)
media_cmd:set_parameter("frame_rate", 30)
media_result = command_manager.execute(media_cmd)
assert(media_result.success, media_result.error_message or "TestCreateMedia failed")

local function insert_clip(start_time, duration, source_in)
    local cmd = Command.create("Insert", "default_project")
    cmd:set_parameter("media_id", "media_src")
    cmd:set_parameter("track_id", "track_default_v1")
    cmd:set_parameter("insert_time", start_time)
    cmd:set_parameter("duration", duration)
    cmd:set_parameter("source_in", source_in or 0)
    cmd:set_parameter("source_out", (source_in or 0) + duration)
    cmd:set_parameter("sequence_id", "default_sequence")
    exec(cmd)
end

insert_clip(0, 1713800, 0)
insert_clip(1713800, 2332838, 1713800)

local function fetch_clips_ordered()
    local stmt = db:prepare("SELECT id, start_time, duration FROM clips ORDER BY start_time")
    assert(stmt:exec(), "Failed to fetch clip ordering")
    local clips = {}
    while stmt:next() do
        clips[#clips + 1] = {
            id = stmt:value(0),
            start_time = stmt:value(1),
            duration = stmt:value(2)
        }
    end
    stmt:finalize()
    return clips
end

local initial_clips = fetch_clips_ordered()
assert(#initial_clips == 2, string.format("expected two clips before ripple, got %d", #initial_clips))

local first_initial = initial_clips[1]
local second_initial = initial_clips[2]

local extend_delta = 1900329
local extend_cmd = Command.create("RippleEdit", "default_project")
extend_cmd:set_parameter("edge_info", {clip_id = first_initial.id, edge_type = "out", track_id = "track_default_v1"})
extend_cmd:set_parameter("delta_ms", extend_delta)
extend_cmd:set_parameter("sequence_id", "default_sequence")
exec(extend_cmd)

local post_clips = fetch_clips_ordered()
assert(#post_clips == 2, string.format("expected two clips after ripple, got %d", #post_clips))

local first_after = post_clips[1]
local second_after = post_clips[2]
local actual_extension = first_after.duration - first_initial.duration

assert(actual_extension > 0, "expected first clip duration to increase")

local expected_second_start = second_initial.start_time + actual_extension
assert(second_after.start_time == expected_second_start,
    string.format("downstream clip should shift by actual extension (expected %d, got %d)",
        expected_second_start, second_after.start_time))

local first_end = first_after.start_time + first_after.duration
assert(first_end == second_after.start_time,
    string.format("clips should remain touching after ripple (expected contact %d, found %d)",
        first_end, second_after.start_time))

print("✅ Ripple extension maintains adjacency")
