#!/usr/bin/env luajit

-- Regression: drag with mixed-track selection should use the anchor (clicked) clip to determine track offset.

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

_G.timeline = {
    get_dimensions = function() return 1000, 1000 end
}

local executed = {}
package.loaded["core.command_manager"] = {
    execute = function(cmd)
        table.insert(executed, cmd)
        return {success = true}
    end
}

local Rational = require("core.rational")
local drag_handler = require("ui.timeline.view.timeline_view_drag_handler")

local state = {
    get_sequence_id = function() return "seq" end,
    get_project_id = function() return "proj" end,
    get_sequence_frame_rate = function() return {fps_numerator = 24, fps_denominator = 1} end,
    get_all_tracks = function()
        return {
            {id = "v1", track_type = "VIDEO"},
            {id = "v2", track_type = "VIDEO"},
        }
    end,
    get_clips = function()
        return {
            {id = "c1", track_id = "v1", timeline_start = Rational.new(0,24,1), duration = Rational.new(24,24,1)},
            {id = "c2", track_id = "v2", timeline_start = Rational.new(48,24,1), duration = Rational.new(24,24,1)},
        }
    end
}

local view = {
    state = state,
    widget = {},
    get_track_id_at_y = function(y, h) return "v2" end
}

-- Anchor on c2 (track v2), mixed selection, move in time (delta_ms non-zero) but same track.
local drag_state = {
    type = "clips",
    clips = {
        {id = "c1"},
        {id = "c2"},
    },
    anchor_clip_id = "c2",
    delta_ms = 1000, -- move in time, not across tracks
    delta_rational = Rational.from_seconds(1, 24, 1),
    current_y = 10,
    start_y = 0
}

drag_handler.handle_release(view, drag_state, {})

assert(#executed == 1, "Expected a single command")
assert(executed[1].type == "Nudge", "Expected time move (Nudge), got " .. tostring(executed[1].type))
print("✅ Drag uses anchor clip for track offset (no unintended cross-track move)")
