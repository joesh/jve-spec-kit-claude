#!/usr/bin/env luajit

-- Regression: drag release should move clips by full delta and allow cross-track moves.

package.path = "src/lua/?.lua;src/lua/?/init.lua;tests/?.lua;" .. package.path

local test_env = require("test_env")

local Rational = require("core.rational")

-- Stub timeline geometry
_G.timeline = {
    get_dimensions = function(_) return 1920, 1080 end
}

local _, executed = test_env.mock_command_manager()

-- Minimal Command mock
package.loaded["command"] = {
    create = function(command_type, project_id)
        return {
            type = command_type,
            project_id = project_id,
            params = {},
            set_parameter = function(self, k, v) self.params[k] = v end,
            get_parameter = function(self, k) return self.params[k] end,
            create_undo = function(self) return self end,
            serialize = function() return "{}" end,
        }
    end
}

local drag_handler = require("ui.timeline.view.timeline_view_drag_handler")

local function reset_executed()
    for i = #executed, 1, -1 do executed[i] = nil end
end

-- Common mock view/state
local function make_view(track_at_y, tracks, clips)
    local state = {
        get_sequence_id = function() return "default_sequence" end,
        get_project_id = function() return "default_project" end,
        get_sequence_frame_rate = function() return { fps_numerator = 24, fps_denominator = 1 } end,
        get_all_tracks = function() return tracks or {} end,
        get_clips = function() return clips or {} end,
    }
    local view = {
        widget = {},
        state = state,
        get_track_id_at_y = function(_, _, _) return track_at_y end
    }
    return view
end

-- Test 1: Cross-track drag issues MoveClipToTrack with full delta
do
    reset_executed()
    local clips = {
        {
            id = "clip_a",
            track_id = "track_a",
            timeline_start = Rational.new(0, 24, 1),
            duration = Rational.new(24, 24, 1)
        }
    }
    local view = make_view("track_b", {
        { id = "track_a", track_type = "VIDEO" },
        { id = "track_b", track_type = "VIDEO" }
    }, clips)
    local drag_state = {
        type = "clips",
        clips = clips,
        delta_ms = 20000,
        delta_rational = Rational.new(480, 24, 1), -- 20s @24fps
        current_y = 100,
        start_y = 90,
    }

    drag_handler.handle_release(view, drag_state, {})
    assert(#executed == 1, "expected one command executed")
    local cmd = executed[1]
    assert(cmd.type == "MoveClipToTrack", "expected MoveClipToTrack for cross-track drag")
    assert(cmd.params.target_track_id == "track_b", "target track should be hovered track")
    assert(cmd.params.pending_new_start_rat.frames == 480, "move should apply full delta to start")
end

-- Test 2: Same-track drag issues Nudge with full delta
do
    reset_executed()
    local clips = {
        {
            id = "clip_a",
            track_id = "track_a",
            timeline_start = Rational.new(0, 24, 1),
            duration = Rational.new(24, 24, 1),
        }
    }
    local view = make_view("track_a", {
        { id = "track_a", track_type = "VIDEO" },
        { id = "track_b", track_type = "VIDEO" }
    }, clips)
    local drag_state = {
        type = "clips",
        clips = clips,
        delta_ms = 20000,
        delta_rational = Rational.new(480, 24, 1), -- 20s @24fps
        current_y = 50,
        start_y = 50,
    }

    drag_handler.handle_release(view, drag_state, {})
    assert(#executed == 1, "expected one command executed")
    local cmd = executed[1]
    assert(cmd.type == "Nudge", "expected Nudge for same-track drag")
    local rat = cmd.params.nudge_amount_rat
    assert(rat and rat.frames == 480, "nudge should use full drag delta frames")
end

-- Test 3: Multi-clip cross-track drag moves all clips by delta to the new track
do
    reset_executed()
    local clips = {
        { id = "clip_a", track_id = "track_a", timeline_start = Rational.new(0, 24, 1), duration = Rational.new(24, 24, 1) },
        { id = "clip_b", track_id = "track_b", timeline_start = Rational.new(24, 24, 1), duration = Rational.new(24, 24, 1) },
    }
    local view = make_view("track_b", {
        { id = "track_a", track_type = "VIDEO" },
        { id = "track_b", track_type = "VIDEO" },
        { id = "track_c", track_type = "VIDEO" },
    }, clips)
    local drag_state = {
        type = "clips",
        clips = clips,
        delta_ms = 10000,
        delta_rational = Rational.new(240, 24, 1), -- ~10s
        current_y = 100,
        start_y = 90,
    }

    drag_handler.handle_release(view, drag_state, {})
    assert(#executed == 1, "expected batch move command when shifting track")
    local batch = executed[1]
    assert(batch.type == "BatchCommand", "expected BatchCommand wrapper")
    local specs = require("dkjson").decode(batch.params.commands_json)
    assert(#specs == 2, "expected move specs for both clips")
    local targets = {}
    local expected_frames = {
        clip_a = 240,
        clip_b = 264,
    }
    for _, spec in ipairs(specs) do
        assert(spec.command_type == "MoveClipToTrack", "move specs should be MoveClipToTrack")
        targets[spec.parameters.target_track_id] = true
        local expected = expected_frames[spec.parameters.clip_id]
        assert(spec.parameters.pending_new_start_rat.frames == expected, "move should carry delta start for each clip")
    end
    assert(targets["track_b"] and targets["track_c"], "moves should land on track_b and track_c maintaining offsets")
end

print("✅ Drag handler cross-track and same-track move regressions passed")
