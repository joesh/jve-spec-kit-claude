#!/usr/bin/env luajit

package.path = package.path .. ";src/lua/?.lua;src/lua/?/init.lua;./?.lua;./?/init.lua"

local timeline_state = require("ui.timeline.timeline_state")
local time_utils = require("core.time_utils")
local Rational = require("core.rational")
local db = require("core.database") -- Require the actual database module

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("Assertion failed: %s\nExpected: %s\nActual:   %s", message or "", tostring(expected), tostring(actual)))
    end
end

local function assert_true(condition, message)
    if not condition then
        error(string.format("Assertion failed: %s\nCondition was false.", message or ""))
    end
end

-- Mock database functions for testing
local original_load_tracks = db.load_tracks
local original_load_clips = db.load_clips
local original_get_connection = db.get_connection

db.load_tracks = function(sequence_id)
    return {
        {id = "v1", track_type = "VIDEO", track_index = 1, name = "Video 1"},
        {id = "a1", track_type = "AUDIO", track_index = 1, name = "Audio 1"},
    }
end

db.load_clips = function(sequence_id)
    return {
        {id = "clip_test_1", track_id = "v1", timeline_start = time_utils.from_frames(10, 24, 1), duration = time_utils.from_frames(20, 24, 1), source_in = time_utils.from_frames(0, 24, 1), source_out = time_utils.from_frames(20, 24, 1)},
        {id = "clip_test_2", track_id = "a1", timeline_start = time_utils.from_frames(30, 24, 1), duration = time_utils.from_frames(10, 24, 1), source_in = time_utils.from_frames(0, 24, 1), source_out = time_utils.from_frames(10, 24, 1)},
    }
end

-- Mock a minimal statement object for the playhead/selection query

local mock_stmt = {}

mock_stmt.bind_value = function(idx, val) end

mock_stmt.exec = function() return true end

mock_stmt.next = function(self)

    if not self._next_called then

        self._next_called = true

        return true

    end

    return false

end

mock_stmt.value = function(idx)

    -- Simulate data from the sequence query in timeline_state.init()

    if idx == 0 then return 48 end -- playhead_frame

    if idx == 1 then return "[]" end -- selected_clip_ids

    if idx == 2 then return "[]" end -- selected_edge_infos

    if idx == 3 then return 0 end -- view_start_frame

    if idx == 4 then return 300 end -- view_duration_frames (10s at 30fps)

    if idx == 5 then return 24 end -- fps_numerator

    if idx == 6 then return 1 end -- fps_denominator

    if idx == 7 then return nil end -- mark_in_frame

    if idx == 8 then return nil end -- mark_out_frame

    return nil

end

mock_stmt.finalize = function(self) self._next_called = nil end

mock_stmt.last_error = function() return "mock error" end



-- Mock for project_id query

local project_stmt_mock = {}

project_stmt_mock.bind_value = function(...) end

project_stmt_mock.exec = function() return true end

project_stmt_mock.next = function(self) -- Pass self explicitly

    if not self._next_called then

        self._next_called = true

        return true

    end

    return false

end

project_stmt_mock.value = function(idx) return "default_project" end

project_stmt_mock.finalize = function(self) self._next_called = nil end



local mock_conn = {

        prepare = function(self, sql)

            if sql:find("SELECT playhead_frame") then

            return mock_stmt

        elseif sql:find("SELECT project_id") then

            return project_stmt_mock

        end

        return nil -- Fallback for unmocked queries

    end,    exec = function(sql) return true end,
    last_error = function() return "mock error" end,
}

db.get_connection = function() return mock_conn end

-- Restore original db functions after tests (good practice)
local function cleanup_db_mocks()
    db.load_tracks = original_load_tracks
    db.load_clips = original_load_clips
    db.get_connection = original_get_connection
end

-- Reset to an empty in-memory state
timeline_state.reset()
timeline_state.init() -- Initialize the state, loading default sequence data

-- Playhead rational conversion round-trip (frames@24fps)
local sequence_fps_num = timeline_state.get_sequence_fps_numerator()
local sequence_fps_den = timeline_state.get_sequence_fps_denominator()
timeline_state.set_playhead_position(time_utils.from_frames(48, sequence_fps_num, sequence_fps_den)) -- 2s @24fps
local playhead_rt = timeline_state.get_playhead_position()
assert_equal(playhead_rt.fps_numerator, sequence_fps_num, "Playhead RationalTime should use sequence frame rate numerator")
assert_equal(playhead_rt.frames, 48, "Playhead should report native frames")

-- Test set_viewport_start_time
local initial_viewport_start_rational = time_utils.from_frames(24, sequence_fps_num, sequence_fps_den)
timeline_state.set_viewport_start_time(initial_viewport_start_rational)
local viewport_start_after_set = timeline_state.get_viewport_start_time()
assert_equal(viewport_start_after_set.frames, initial_viewport_start_rational.frames, "Viewport start should be set directly")
assert_equal(viewport_start_after_set.fps_numerator, sequence_fps_num, "Viewport start RationalTime should use sequence frame rate numerator")

-- Test set_viewport_duration and its effect on start time (centers around playhead)
local viewport_duration_rational = time_utils.from_frames(48, sequence_fps_num, sequence_fps_den) -- 2s
timeline_state.set_viewport_duration(viewport_duration_rational)

local viewport_duration_after_set = timeline_state.get_viewport_duration()
assert_equal(viewport_duration_after_set.frames, viewport_duration_rational.frames, "Viewport duration should be set directly")
assert_equal(viewport_duration_after_set.fps_numerator, sequence_fps_num, "Viewport duration RationalTime should use sequence frame rate numerator")

-- Expect viewport start to be centered around the playhead (72 - 48/2 = 48)
local expected_start_after_duration_set = 24
local viewport_start_after_duration_set = timeline_state.get_viewport_start_time()
assert_equal(viewport_start_after_duration_set.frames, expected_start_after_duration_set, "Viewport start should be adjusted to center playhead")
assert_equal(viewport_start_after_duration_set.fps_numerator, sequence_fps_num, "Adjusted viewport start RationalTime should use sequence frame rate numerator")

-- Coordinate conversions (RationalTime aware)
local px = timeline_state.time_to_pixel(time_utils.from_frames(36, sequence_fps_num, sequence_fps_den), 240) -- midway through 1s..3s window
local rt_from_px = timeline_state.pixel_to_time(px, 240)
assert_equal(rt_from_px.fps_numerator, sequence_fps_num, "pixel_to_rational should use sequence fps")
assert_equal(rt_from_px.frames, 36, "pixel_to_rational should map back to frame count")
