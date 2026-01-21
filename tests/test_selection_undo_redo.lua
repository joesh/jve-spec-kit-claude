#!/usr/bin/env luajit

-- Verifies that clip selection is restored correctly across
-- multiple undo/redo operations so that the command stream
-- remains idempotent.
--
-- Scenario:
--   1. Execute a command that sets selection to Clip A.
--   2. User manually changes selection to Clip B (no command logged).
--   3. Execute a second command that depends on Clip B being selected.
--   4. Undo twice, then redo twice.
-- Expectation:
--   After the first redo, selection should already be Clip B so that
--   the second redo (or command replay) sees the exact same context
--   that existed originally.

package.path = package.path .. ";../src/lua/?.lua;../src/lua/core/?.lua;../src/lua/models/?.lua;../src/lua/ui/?.lua;../src/lua/ui/timeline/?.lua;../tests/?.lua"

require('test_env')

-- Mock timeline_state to avoid pulling in Qt bindings.
local mock_timeline_state = {
    playhead_value = 0,
    playhead_position = 0,
    clips = {},
    selected_clips = {},
    selected_edges = {},
    selection_log = {},
    viewport_start_value = 0,
    viewport_duration_frames_value = 300
}

function mock_timeline_state.get_playhead_position()
    return mock_timeline_state.playhead_position
end

function mock_timeline_state.set_playhead_position(time)
    mock_timeline_state.playhead_position = time
end

function mock_timeline_state.get_selected_clips()
    return mock_timeline_state.selected_clips
end

local function log_selection(clips)
    local ids = {}
    for _, clip in ipairs(clips or {}) do
        table.insert(ids, clip.id)
    end
    table.insert(mock_timeline_state.selection_log, table.concat(ids, ","))
end

function mock_timeline_state.set_selection(clips)
    mock_timeline_state.selected_clips = clips or {}
    mock_timeline_state.selected_edges = {}
    log_selection(mock_timeline_state.selected_clips)
end

function mock_timeline_state.get_selected_edges()
    return mock_timeline_state.selected_edges
end

function mock_timeline_state.set_edge_selection(edges)
    mock_timeline_state.selected_edges = edges or {}
    mock_timeline_state.selected_clips = {}
    log_selection(mock_timeline_state.selected_clips)
end

function mock_timeline_state.reload_clips()
    -- No-op for tests.
end

function mock_timeline_state.persist_state_to_db()
    -- Not needed for this isolated test.
end

local viewport_guard = 0

function mock_timeline_state.capture_viewport()
    return {
        start_value = mock_timeline_state.viewport_start_value,
        duration_value = mock_timeline_state.viewport_duration_frames_value,
    }
end

function mock_timeline_state.get_sequence_frame_rate()
    return {fps_numerator = 1000, fps_denominator = 1}
end

function mock_timeline_state.get_sequence_audio_sample_rate()
    return 48000
end

function mock_timeline_state.restore_viewport(snapshot)
    if not snapshot then
        return
    end

    if snapshot.duration_value then
        mock_timeline_state.viewport_duration_frames_value = snapshot.duration_value
    end

    if snapshot.start_value then
        mock_timeline_state.viewport_start_value = snapshot.start_value
    end
end

function mock_timeline_state.push_viewport_guard()
    viewport_guard = viewport_guard + 1
    return viewport_guard
end

function mock_timeline_state.pop_viewport_guard()
    if viewport_guard > 0 then
        viewport_guard = viewport_guard - 1
    end
    return viewport_guard
end

package.loaded['ui.timeline.timeline_state'] = mock_timeline_state

local command_manager = require('core.command_manager')
local Clip = require('models.clip')
local _original_clip_load_optional = Clip.load_optional
local clip_catalog = { clip0 = true, clip1 = true, clip2 = true }
Clip.load_optional = function(clip_id)
    if not clip_id then
        return nil
    end
    if clip_catalog[clip_id] then
        return { id = clip_id, clip_kind = 'timeline', owner_sequence_id = 'test_sequence' }
    end
    return _original_clip_load_optional(clip_id)
end

local Command = require('command')
local database = require('core.database')
local Media = require('models.media')

print("=== Selection Undo/Redo Tests ===\n")

-- Set up isolated database backing the CommandManager.
local test_db_path = "/tmp/jve/test_selection_undo_redo.db"
os.remove(test_db_path)

database.init(test_db_path)
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('test_project', 'Test Project', %d, %d);
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('default_project', 'Default Project', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, view_start_frame, view_duration_frames, playhead_frame, created_at, modified_at)
    VALUES ('test_sequence', 'test_project', 'Test Sequence', 'timeline', 1000, 1, 48000, 1920, 1080, 0, 600, 0, %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, view_start_frame, view_duration_frames, playhead_frame, created_at, modified_at)
    VALUES ('default_sequence', 'default_project', 'Default Sequence', 'timeline', 1000, 1, 48000, 1920, 1080, 0, 600, 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan) VALUES ('track_test_v1', 'test_sequence', 'Track', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan) VALUES ('track_default_v1', 'default_sequence', 'Track', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at, metadata)
    VALUES ('media_clip', 'test_project', 'Test Clip', '/tmp/jve/media_clip.mov', 1000, 1000, 1, 1920, 1080, 2, 'prores', %d, %d, '{}');
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled)
    VALUES ('clip0', 'test_project', 'timeline', '', 'track_test_v1', 'media_clip', 'test_sequence', 0, 1000, 0, 1000, 1000, 1, 1);
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled)
    VALUES ('clip1', 'test_project', 'timeline', '', 'track_test_v1', 'media_clip', 'test_sequence', 2000, 1000, 0, 1000, 1000, 1, 1);
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled)
    VALUES ('clip2', 'test_project', 'timeline', '', 'track_test_v1', 'media_clip', 'test_sequence', 4000, 1000, 0, 1000, 1000, 1, 1);
]], now, now, now, now, now, now, now, now, now, now))

command_manager.init('test_sequence', 'test_project')

command_manager.register_executor("TestEnsureMedia", function(cmd)
    local media = Media.create({
        id = cmd:get_parameter("media_id"),
        project_id = cmd:get_parameter("project_id") or 'test_project',
        file_path = cmd:get_parameter("file_path"),
        file_name = cmd:get_parameter("file_name"),
        name = cmd:get_parameter("file_name"),
        duration_frames = cmd:get_parameter("duration_frames") or 1000,
        fps_numerator = 1000,
        fps_denominator = 1
    })
    assert(media, "failed to create media " .. tostring(cmd:get_parameter("media_id")))
    return media:save(db)
end, nil, {
    args = {
        project_id = { required = true },
        media_id = {},
        file_path = {},
        file_name = {},
        duration_frames = {},
        frame_rate = {},
    }
})

local ensure_media_cmd = Command.create("TestEnsureMedia", "test_project")
ensure_media_cmd:set_parameter("media_id", "media_clip")
ensure_media_cmd:set_parameter("file_path", "/tmp/jve/media_clip.mov")
ensure_media_cmd:set_parameter("file_name", "Test Clip")
ensure_media_cmd:set_parameter("duration_frames", 1000)
ensure_media_cmd:set_parameter("frame_rate", 1000)
assert(command_manager.execute(ensure_media_cmd).success)

-- Provide lightweight command executors used only by this test.
command_manager.register_executor("TestSelectClip", function(command)
    local clip_id = command:get_parameter("clip_id")
    local timeline_state = require('ui.timeline.timeline_state')
    timeline_state.set_selection({{id = clip_id}})
    return true
end, function()
    return true
end, {
    args = {
        project_id = { required = true },
        clip_id = {},
    }
})

command_manager.register_executor("TestNoOp", function()
    return true
end, function()
    return true
end, {
    args = {
        project_id = { required = true },
    }
})

local timeline_state = require('ui.timeline.timeline_state')

local function current_selection()
    local clips = timeline_state.get_selected_clips() or {}
    local ids = {}
    for _, clip in ipairs(clips) do
        table.insert(ids, clip.id)
    end
    return table.concat(ids, ",")
end

local function assert_selection(expected, context)
    local actual = current_selection()
    if actual ~= expected then
        print(string.format("❌ FAIL: %s\nExpected selection: %s\nActual selection:   %s", context, expected, actual))
        os.exit(1)
    else
        print(string.format("✅ PASS: %s (%s)", context, expected))
    end
end

-- Initial state mirrors a user with Clip 0 selected.
timeline_state.set_selection({{id = "clip0"}})
assert_selection("clip0", "Initial selection")

-- Command 1 sets selection to Clip 1.
local cmd1 = Command.create("TestSelectClip", "test_project")
cmd1:set_parameter("clip_id", "clip1")
local result1 = command_manager.execute(cmd1)
if not result1.success then
    print("❌ FAIL: Command 1 execution failed: " .. tostring(result1.error_message))
    os.exit(1)
end
assert_selection("clip1", "After command 1")

-- User manually changes selection to Clip 2 (outside of command system).
timeline_state.set_selection({{id = "clip2"}})
assert_selection("clip2", "Manual selection change before command 2")

-- Command 2 records the current selection but does not mutate it.
local cmd2 = Command.create("TestNoOp", "test_project")
local result2 = command_manager.execute(cmd2)
if not result2.success then
    print("❌ FAIL: Command 2 execution failed: " .. tostring(result2.error_message))
    os.exit(1)
end
assert_selection("clip2", "After command 2")

-- Undo twice: should return to initial selection.
command_manager.undo()
assert_selection("clip2", "After undoing command 2 (restores pre-state)")
command_manager.undo()
assert_selection("clip0", "After undoing command 1")

-- Redo command 1.
command_manager.redo()
assert_selection("clip1", "After redoing command 1 (restores command post-state)")

-- Redo command 2.
command_manager.redo()
assert_selection("clip2", "After redoing command 2 (head state)")

-- Regression: redo gracefully handles missing selection clips
print("\nTest 4: Redo skips missing selection clips")
mock_timeline_state.selection_log = {}

local select_clip0 = Command.create("TestSelectClip", "test_project")
select_clip0:set_parameter("clip_id", "clip0")
assert(command_manager.execute(select_clip0).success, "Selecting clip0 should succeed")

local noop_cmd = Command.create("TestNoOp", "test_project")
assert(command_manager.execute(noop_cmd).success, "Executing no-op command should succeed")

assert(db:exec("DELETE FROM clips WHERE id = 'clip0'"), "Failed to delete clip0 from database")
clip_catalog["clip0"] = nil

local undo_result = command_manager.undo()
assert(undo_result.success, "Undo after deleting clip should succeed")

local redo_result = command_manager.redo()
assert(redo_result.success, "Redo should succeed even if selection clip was deleted")

local last_log_entry = mock_timeline_state.selection_log[#mock_timeline_state.selection_log] or ""
assert(last_log_entry == "", string.format("Selection after redo should be empty, got '%s'", last_log_entry))

print("✅ Redo gracefully handles missing selection clips")

command_manager.unregister_executor("TestSelectClip")
command_manager.unregister_executor("TestNoOp")

print("\nAll selection undo/redo assertions passed.")
