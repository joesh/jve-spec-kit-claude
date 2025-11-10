#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')
local Command = require('command')
local Media = require('models.media')

local TEST_DB = "/tmp/test_ripple_delete_selection.db"
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

local function clips_snapshot()
    local clips = {}
    local stmt = db:prepare("SELECT id, track_id, start_time, duration FROM clips ORDER BY start_time")
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

local function find_clip(id)
    for _, clip in ipairs(clips_snapshot()) do
        if clip.id == id then
            return clip
        end
    end
    return nil
end

local timeline_state = {
    clips = {},
    selected_clips = {},
    selected_edges = {},
    selected_gaps = {},
    playhead_time = 0,
    viewport_start_time = 0,
    viewport_duration = 10000,
}

local function reload_state_clips()
    timeline_state.clips = clips_snapshot()
end

function timeline_state.get_selected_clips() return timeline_state.selected_clips end
function timeline_state.get_selected_edges() return timeline_state.selected_edges end
function timeline_state.clear_edge_selection() timeline_state.selected_edges = {} end
function timeline_state.clear_gap_selection() timeline_state.selected_gaps = {} end
function timeline_state.get_selected_gaps() return timeline_state.selected_gaps end
function timeline_state.set_selection(clips) timeline_state.selected_clips = clips or {} end
function timeline_state.reload_clips() reload_state_clips() end
function timeline_state.persist_state_to_db() end
function timeline_state.get_clips()
    reload_state_clips()
    return timeline_state.clips
end
function timeline_state.get_sequence_id() return "default_sequence" end
function timeline_state.get_playhead_time() return timeline_state.playhead_time end
function timeline_state.set_playhead_time(time_ms) timeline_state.playhead_time = time_ms end
function timeline_state.push_viewport_guard() return 1 end
function timeline_state.pop_viewport_guard() return 0 end
function timeline_state.capture_viewport()
    return {
        start_time = timeline_state.viewport_start_time,
        duration = timeline_state.viewport_duration,
    }
end
function timeline_state.restore_viewport(snapshot)
    if not snapshot then return end
    timeline_state.viewport_start_time = snapshot.start_time or timeline_state.viewport_start_time
    timeline_state.viewport_duration = snapshot.duration or timeline_state.viewport_duration
end

local function reset_timeline_state()
    while command_manager.can_undo and command_manager.can_undo() do
        local result = command_manager.undo()
        if not result.success then
            break
        end
    end
    db:exec("DELETE FROM clips;")
    db:exec("DELETE FROM media;")
    timeline_state.selected_clips = {}
    timeline_state.selected_edges = {}
    timeline_state.selected_gaps = {}
    timeline_state.playhead_time = 0
end

package.loaded['ui.timeline.timeline_state'] = timeline_state

local executors = {}
local undoers = {}
command_impl.register_commands(executors, undoers, db)
command_manager.init(db, 'default_sequence', 'default_project')

local function create_clip_command(params)
    local clip_id = params.clip_id
    local clip_duration = params.duration
    local media_id = params.media_id or (clip_id .. "_media")

    local media = Media.create({
        id = media_id,
        project_id = 'default_project',
        file_path = '/tmp/' .. clip_id .. '.mov',
        file_name = clip_id .. '.mov',
        duration = clip_duration,
        frame_rate = 30
    })
    assert(media, "failed to create media for clip " .. tostring(clip_id))
    assert(media:save(db), "failed to save media for clip " .. tostring(clip_id))

    local clip = require('models.clip').create("Test Clip", media_id)
    clip.id = params.clip_id
    clip.track_id = params.track_id
    clip.start_time = params.start_time
    clip.duration = params.duration
    clip.source_in = 0
    clip.source_out = params.duration
    clip.enabled = true
    return clip:save(db, {skip_occlusion = true})
end

command_manager.register_executor("TestCreateClip", function(cmd)
    return create_clip_command({
        clip_id = cmd:get_parameter("clip_id"),
        track_id = cmd:get_parameter("track_id"),
        start_time = cmd:get_parameter("start_time"),
        duration = cmd:get_parameter("duration"),
        media_id = cmd:get_parameter("media_id")
    })
end)

local clip_specs = {
    {id = "clip_a", start = 0, duration = 1000},
    {id = "clip_b", start = 1000, duration = 1000},
    {id = "clip_c", start = 2000, duration = 1000},
}

for _, spec in ipairs(clip_specs) do
    local cmd = Command.create("TestCreateClip", "default_project")
    cmd:set_parameter("clip_id", spec.id)
    cmd:set_parameter("track_id", "track_v1")
    cmd:set_parameter("start_time", spec.start)
    cmd:set_parameter("duration", spec.duration)
    assert(command_manager.execute(cmd).success)
end

reload_state_clips()

timeline_state.selected_clips = {
    {id = "clip_b"}
}

local function execute_ripple_delete(ids)
    local cmd = Command.create("RippleDeleteSelection", "default_project")
    cmd:set_parameter("clip_ids", ids)
    cmd:set_parameter("sequence_id", "default_sequence")
    local result = command_manager.execute(cmd)
    assert(result.success, result.error_message or "RippleDeleteSelection failed")
end

-- Test: Ripple delete removes clip and shifts downstream clips
local original_playhead = 43210
timeline_state.playhead_time = original_playhead
execute_ripple_delete({"clip_b"})

local after_delete = clips_snapshot()
assert(#after_delete == 2, "Expected 2 clips after ripple delete")

local clip_a = after_delete[1]
local clip_c = after_delete[2]

assert(clip_a.id == "clip_a", "Clip A should remain first")
assert(clip_c.id == "clip_c", "Clip C should remain after ripple")
assert(clip_c.start_time == 1000, string.format("Clip C start_time expected 1000, got %d", clip_c.start_time))

-- Undo restores original state
local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo failed for RippleDeleteSelection")
assert(timeline_state.playhead_time == original_playhead,
    string.format("Undo should restore playhead to %d, got %d", original_playhead, timeline_state.playhead_time))

local after_undo = clips_snapshot()
assert(#after_undo == 3, "Expected 3 clips after undo")

local clip_b_restored = nil
for _, clip in ipairs(after_undo) do
    if clip.id == "clip_b" then
        clip_b_restored = clip
    end
end
assert(clip_b_restored, "Clip B should be restored after undo")
assert(clip_b_restored.start_time == 1000, string.format("Clip B start_time expected 1000, got %d", clip_b_restored.start_time))

-- Redo reapplies ripple delete
local redo_result = command_manager.redo()
assert(redo_result.success, redo_result.error_message or "Redo failed for RippleDeleteSelection")

local after_redo = clips_snapshot()
assert(#after_redo == 2, "Expected 2 clips after redo")
local clip_c_after_redo = after_redo[2]
assert(clip_c_after_redo.id == "clip_c", "Clip C should still be present after redo")
assert(clip_c_after_redo.start_time == 1000, string.format("Clip C start_time expected 1000 after redo, got %d", clip_c_after_redo.start_time))

-- Regression setup: reset timeline with non-adjacent selection
assert(command_manager.undo().success, "Failed to undo ripple delete before regression setup")
db:exec("DELETE FROM clips;")
db:exec("DELETE FROM media;")
timeline_state.selected_clips = {}
timeline_state.selected_edges = {}
timeline_state.selected_gaps = {}
timeline_state.playhead_time = 0

local regression_specs = {
    {id = "clip_1", start = 0, duration = 500},   -- selected
    {id = "clip_2", start = 500, duration = 2000}, -- not selected, sits between selections
    {id = "clip_3", start = 2500, duration = 1000},-- selected (non-adjacent to clip_1)
    {id = "clip_4", start = 3500, duration = 800}, -- trailing clip to verify shifts
}

for _, spec in ipairs(regression_specs) do
    local cmd = Command.create("TestCreateClip", "default_project")
    cmd:set_parameter("clip_id", spec.id)
    cmd:set_parameter("track_id", "track_v1")
    cmd:set_parameter("start_time", spec.start)
    cmd:set_parameter("duration", spec.duration)
    assert(command_manager.execute(cmd).success)
end

reload_state_clips()

timeline_state.selected_clips = {
    {id = "clip_1"},
    {id = "clip_3"},
}

execute_ripple_delete({"clip_1", "clip_3"})

local regression_after_delete = clips_snapshot()
assert(#regression_after_delete == 2, "Expected 2 clips after ripple delete of non-adjacent selection")

local first_clip = regression_after_delete[1]
local second_clip = regression_after_delete[2]

assert(first_clip.id == "clip_2", "Clip 2 should remain and shift to the start")
assert(first_clip.start_time == 0, string.format("Clip 2 expected to start at 0, got %d", first_clip.start_time))

assert(second_clip.id == "clip_4", "Clip 4 should remain after ripple delete")
local expected_second_start = first_clip.start_time + first_clip.duration
assert(second_clip.start_time == expected_second_start,
    string.format("Clip 4 expected to start at %d, got %d", expected_second_start, second_clip.start_time))

local gap_between = second_clip.start_time - (first_clip.start_time + first_clip.duration)
assert(gap_between >= 0, "Clips should not overlap after ripple delete")

-- Multi-track regression: ripple delete shifts other tracks + restores selection on undo
reset_timeline_state()

local multi_specs = {
    {id = "mt_v1_pre", track_id = "track_v1", start = 0, duration = 500},
    {id = "mt_v1_target", track_id = "track_v1", start = 500, duration = 500},
    {id = "mt_v1_post", track_id = "track_v1", start = 1500, duration = 500},
    {id = "mt_v2_pre", track_id = "track_v2", start = 0, duration = 500},
    {id = "mt_v2_post", track_id = "track_v2", start = 2000, duration = 500},
}

for _, spec in ipairs(multi_specs) do
    local cmd = Command.create("TestCreateClip", "default_project")
    cmd:set_parameter("clip_id", spec.id)
    cmd:set_parameter("track_id", spec.track_id)
    cmd:set_parameter("start_time", spec.start)
    cmd:set_parameter("duration", spec.duration)
    assert(command_manager.execute(cmd).success)
end

reload_state_clips()

local selection_before = {{id = "mt_v1_target"}}
timeline_state.selected_clips = selection_before
local selection_playhead = 24680
timeline_state.playhead_time = selection_playhead

execute_ripple_delete({"mt_v1_target"})

local shifted_v2 = find_clip("mt_v2_post")
local expected_shift = 1500  -- downstream clip should move left by target duration (500ms)
assert(shifted_v2.start_time == expected_shift,
    string.format("Multi-track ripple should shift downstream clips on other tracks. Expected %d, got %d",
        expected_shift, shifted_v2.start_time))

local undo_multi = command_manager.undo()
assert(undo_multi.success, undo_multi.error_message or "Undo failed for multi-track ripple")
assert(timeline_state.selected_clips and timeline_state.selected_clips[1]
    and timeline_state.selected_clips[1].id == "mt_v1_target",
    "Undo should restore original selection for ripple delete")
assert(timeline_state.playhead_time == selection_playhead,
    string.format("Undo should restore playhead to %d, got %d",
        selection_playhead, timeline_state.playhead_time))

local restored_v2 = find_clip("mt_v2_post")
assert(restored_v2.start_time == 2000,
    string.format("Undo should restore downstream clip position on other tracks (expected 2000, got %d)",
        restored_v2.start_time))

print("✅ test_ripple_delete_selection.lua passed")
