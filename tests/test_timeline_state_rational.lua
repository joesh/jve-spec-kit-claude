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
local original_load_sequence_track_heights = db.load_sequence_track_heights
local original_set_sequence_track_heights = db.set_sequence_track_heights
local original_set_project_setting = db.set_project_setting
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

db.load_sequence_track_heights = function(_sequence_id)
    return {}
end

db.set_sequence_track_heights = function(_sequence_id, _track_heights)
    return true
end

db.set_project_setting = function(_project_id, _key, _value)
    return true
end

-- Mock a minimal statement object for the playhead/selection query

local mock_stmt_sequence = {

    _results = {

        [0] = 48,   -- playhead_frame

        [1] = "[]", -- selected_clip_ids

        [2] = "[]", -- selected_edge_infos

        [3] = 0,    -- view_start_frame

        [4] = 300,  -- view_duration_frames

        [5] = 24,   -- fps_numerator

        [6] = 1,    -- fps_denominator

        [7] = nil,  -- mark_in_frame

        [8] = nil,  -- mark_out_frame

    },

    _next_called = false,

    bind_value = function(idx, val) end,

    exec = function() return true end,

    next = function(self)

        if not self._next_called then

            self._next_called = true

            return true

        end

        return false

    end,

    value = function(self, idx) return self._results[idx] end,

    finalize = function(self) self._next_called = false end,

}



-- Mock for project_id query

local project_stmt_mock = {

    _next_called = false,

    bind_value = function(...) end,

    exec = function() return true end,

    next = function(self)

        if not self._next_called then

            self._next_called = true

            return true

        end

        return false

    end,

    value = function(idx) return "default_project" end,

    finalize = function(self) self._next_called = false end,

}



-- Mock for Sequence.load query (SELECT id, project_id, name, kind, fps_numerator, ...)
local sequence_load_mock = {
    _next_called = false,
    bind_value = function(...) end,
    exec = function() return true end,
    next = function(self)
        if not self._next_called then
            self._next_called = true
            return true
        end
        return false
    end,
    value = function(self, idx)
        -- Sequence.load column order: id, project_id, name, kind, fps_numerator, fps_denominator,
        -- width, height, playhead_frame, view_start_frame, view_duration_frames,
        -- mark_in_frame, mark_out_frame, audio_rate, selected_clip_ids, selected_edge_infos
        local values = {
            [0] = "default_sequence",  -- id
            [1] = "default_project",   -- project_id
            [2] = "Test Sequence",     -- name
            [3] = "timeline",          -- kind
            [4] = 24,                  -- fps_numerator
            [5] = 1,                   -- fps_denominator
            [6] = 1920,                -- width
            [7] = 1080,                -- height
            [8] = 48,                  -- playhead_frame
            [9] = 0,                   -- view_start_frame
            [10] = 300,                -- view_duration_frames
            [11] = nil,                -- mark_in_frame
            [12] = nil,                -- mark_out_frame
            [13] = 48000,              -- audio_rate
            [14] = "[]",               -- selected_clip_ids
            [15] = "[]",               -- selected_edge_infos
        }
        return values[idx]
    end,
    finalize = function(self) self._next_called = false end,
}

local mock_conn = {
    prepare = function(self, sql)
        if sql:find("SELECT playhead_frame") then
            return mock_stmt_sequence
        elseif sql:find("SELECT project_id") then
            return project_stmt_mock
        elseif sql:find("FROM sequences WHERE") then
            return sequence_load_mock
        end
        return nil -- Fallback for unmocked queries
    end,
    exec = function(sql) return true end,
    last_error = function() return "mock error" end,
}



db.get_connection = function() return mock_conn end



-- Restore original db functions after tests (good practice)

local function cleanup_db_mocks()

    db.load_tracks = original_load_tracks

    db.load_clips = original_load_clips

    db.load_sequence_track_heights = original_load_sequence_track_heights
    db.set_sequence_track_heights = original_set_sequence_track_heights
    db.set_project_setting = original_set_project_setting

    db.get_connection = original_get_connection

end



-- Reset to an empty in-memory state

timeline_state.reset()

timeline_state.init("default_sequence") -- Initialize the state, loading default sequence data

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
