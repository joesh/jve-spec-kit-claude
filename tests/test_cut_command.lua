#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')
local Command = require('command')

local TEST_DB = "/tmp/test_cut_command.db"
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
        media_id TEXT,
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

local function clips_snapshot()
    local clips = {}
    local stmt = db:prepare("SELECT id, track_id, start_time, duration FROM clips ORDER BY track_id, start_time")
    assert(stmt:exec())
    while stmt:next() do
        clips[#clips + 1] = {
            id = stmt:value(0),
            track_id = stmt:value(1),
            start_time = stmt:value(2),
            duration = stmt:value(3)
        }
    end
    return clips
end

local function clip_exists(id)
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next())
    return stmt:value(0) > 0
end

local timeline_state = {
    playhead_time = 0,
    selected_clips = {}
}

local function load_clips_into_state()
    timeline_state.clips = clips_snapshot()
end

load_clips_into_state()

function timeline_state.get_selected_clips() return timeline_state.selected_clips end
function timeline_state.get_selected_edges() return {} end
function timeline_state.normalize_edge_selection() end
function timeline_state.clear_edge_selection() timeline_state.selected_clips = {} end
function timeline_state.set_selection(clips) timeline_state.selected_clips = clips or {} end
function timeline_state.reload_clips() load_clips_into_state() end
function timeline_state.persist_state_to_db() end
function timeline_state.get_playhead_time() return timeline_state.playhead_time end
function timeline_state.set_playhead_time(time_ms) timeline_state.playhead_time = time_ms end
function timeline_state.get_clips()
    load_clips_into_state()
    return timeline_state.clips
end

local viewport_guard = 0
timeline_state.viewport_start_time = timeline_state.viewport_start_time or 0
timeline_state.viewport_duration = timeline_state.viewport_duration or 10000

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

-- Helper command to create clips via command system so undo/redo replay works
local function create_clip_command(params)
    local clip_id = params.clip_id
    local clip_start = params.start_time
    local clip_duration = params.duration
    local track_id = params.track_id

    local Clip = require('models.clip')
    local clip = Clip.create('Test Clip', nil)
    clip.id = clip_id
    clip.track_id = track_id
    clip.start_time = clip_start
    clip.duration = clip_duration
    clip.source_in = 0
    clip.source_out = clip_duration
    clip.enabled = true
    clip:save(db, {skip_occlusion = true})
    return true
end

command_manager.register_executor("TestCreateClip", function(cmd)
    return create_clip_command({
        clip_id = cmd:get_parameter("clip_id"),
        start_time = cmd:get_parameter("start_time"),
        duration = cmd:get_parameter("duration"),
        track_id = cmd:get_parameter("track_id")
    })
end)

-- Create four clips as setup
local clip_specs = {
    {id = "clip_a", track = "track_v1", start = 0,    duration = 1500},
    {id = "clip_b", track = "track_v1", start = 3000, duration = 1500},
    {id = "clip_c", track = "track_v2", start = 1200, duration = 1200},
    {id = "clip_d", track = "track_v2", start = 5000, duration = 1500},
}

for _, spec in ipairs(clip_specs) do
    local cmd = Command.create("TestCreateClip", "default_project")
    cmd:set_parameter("clip_id", spec.id)
    cmd:set_parameter("track_id", spec.track)
    cmd:set_parameter("start_time", spec.start)
    cmd:set_parameter("duration", spec.duration)
    assert(command_manager.execute(cmd).success)
end

load_clips_into_state()

print("=== Cut Command Tests ===\n")

-- Test 1: Cut deletes selected clips
timeline_state.set_selection({
    {id = "clip_a"},
    {id = "clip_c"},
})

local result = command_manager.execute("Cut")
assert(result.success, "Cut with selection should succeed")
assert(not clip_exists("clip_a"), "clip_a should be removed")
assert(not clip_exists("clip_c"), "clip_c should be removed")
assert(clip_exists("clip_b"), "clip_b should remain")
assert(clip_exists("clip_d"), "clip_d should remain")

local undo_result = command_manager.undo()
assert(undo_result.success, "Undo Cut should succeed")
assert(clip_exists("clip_a"), "clip_a should be restored after undo")
assert(clip_exists("clip_c"), "clip_c should be restored after undo")

-- Test 2: Cut with no selection is a no-op
timeline_state.set_selection({})
timeline_state.playhead_time = 1300
local before = clips_snapshot()
result = command_manager.execute("Cut")
assert(result.success, "Cut with no selection should still succeed")
local after = clips_snapshot()

assert(#before == #after, "No clips should be removed when nothing is selected")
print("✅ Cut removes only selected clips and does nothing when nothing is selected")
