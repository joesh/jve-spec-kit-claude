#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s\nExpected: %s\nActual:   %s", message or "assert_equal failed", tostring(expected), tostring(actual)))
    end
end

-- Provide lightweight stubs so replay does not depend on Qt timelines
timeline_state.capture_viewport = function()
    return {start_value = 0, duration_value = 1000, timebase_type = "video_frames", timebase_rate = 24.0}
end
timeline_state.push_viewport_guard = function() end
timeline_state.pop_viewport_guard = function() end
timeline_state.restore_viewport = function(_) end
timeline_state.set_selection = function(_) end
timeline_state.get_selected_clips = function() return {} end
timeline_state.set_edge_selection = function(_) end
timeline_state.get_selected_edges = function() return {} end
timeline_state.set_playhead_position = function(_) end
timeline_state.get_playhead_position = function() return 0 end
timeline_state.reload_clips = function() end

local function row_count(db, sql, value)
    local stmt = db:prepare(sql)
    if not stmt then
        error("Failed to prepare statement: " .. sql)
    end
    if value ~= nil then
        stmt:bind_value(1, value)
    end
    local count = 0
    if stmt:exec() and stmt:next() then
        count = stmt:value(0) or 0
    end
    stmt:finalize()
    return count
end

local db_path = "/tmp/jve/test_command_manager_replay_initial_state.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()
local exec_result, exec_err = db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('test_project', 'Replay Test Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
        playhead_frame, selected_clip_ids, selected_edge_infos,
        view_start_frame, view_duration_frames, current_sequence_number, created_at, modified_at)
    VALUES ('timeline_seq', 'test_project', 'Timeline Seq', 'timeline',
        24, 1, 48000, 1920, 1080, 0, '[]', '[]', 0, 240, NULL, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
    VALUES ('track_v1', 'timeline_seq', 'V1', 'VIDEO', 1);

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, created_at, modified_at)
    VALUES ('clip_001', 'test_project', 'timeline', 'Existing Clip',
        'track_v1', 'timeline_seq', 0, 2000, 0, 2000, 24, 1, 1, %d, %d);
]], now, now, now, now, now, now))

if not exec_result then
    error(string.format("Failed to execute test setup SQL: %s", tostring(exec_err)))
end

-- No commands yet, but timeline has existing clip
command_manager.init("timeline_seq", "test_project")
command_manager.activate_timeline_stack("timeline_seq")

local initial_clips = database.load_clips("timeline_seq") or {}
assert_equal(#initial_clips, 1, "Expected database.load_clips to see existing timeline clip")

local before_clip_count = row_count(db, "SELECT COUNT(*) FROM clips WHERE owner_sequence_id = 'timeline_seq'")
assert_equal(before_clip_count, 1, "Expected initial timeline clip to exist before replay")

local replay_result = command_manager.replay_from_sequence(0)
assert_equal(replay_result.success, true, "Replay should succeed even when only initial state exists")

local after_clip_count = row_count(db, "SELECT COUNT(*) FROM clips WHERE owner_sequence_id = 'timeline_seq'")
assert_equal(after_clip_count, 1, "Initial timeline clip must persist after replay")

print("✅ command_manager initial state replay test passed")
