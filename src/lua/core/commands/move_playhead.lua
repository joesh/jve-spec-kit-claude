--- MovePlayhead command: move the playhead by a duration literal.
--
-- Positional arg is a duration literal: "1f" (1 frame), "-1s" (minus 1 second),
-- "30f" (30 frames). Suffix "f" = frames, "s" = seconds (converted via fps).
--
-- Non-undoable. Replaces StepFrame for TOML-driven dispatch.
--
-- @file move_playhead.lua
local M = {}

local SPEC = {
    undoable = false,
    mutates_clips = false,
    args = {
        _positional = {},  -- duration literal as first positional arg
        project_id = {},
    }
}

--- Parse a duration literal string into a frame count.
-- "1f" → 1, "-1f" → -1, "1s" → fps, "-1s" → -fps
local function parse_duration(literal, fps)
    assert(type(literal) == "string" and literal ~= "",
        "MovePlayhead: duration literal required (e.g. 1f, -1s)")

    local num_str, unit = literal:match("^(-?%d+)(%a)$")
    assert(num_str and unit,
        "MovePlayhead: malformed duration literal: " .. literal)

    local num = tonumber(num_str)
    assert(num, "MovePlayhead: bad number in duration: " .. literal)

    if unit == "f" then
        return num
    elseif unit == "s" then
        assert(fps and fps > 0, "MovePlayhead: fps required for second-based duration")
        return num * math.floor(fps + 0.5)
    else
        error("MovePlayhead: unknown duration unit '" .. unit .. "' (expected f or s)")
    end
end

function M.register(executors, undoers, db)
    local function executor(command)
        local args = command:get_all_parameters()
        local positional = args._positional or {}
        assert(#positional >= 1, "MovePlayhead: duration literal required (e.g. 1f, -1s)")
        local literal = positional[1]

        local pm = require('ui.panel_manager')
        local sv = pm.get_active_sequence_monitor()
        assert(sv and sv.sequence_id, "MovePlayhead: no sequence loaded in active view")
        local engine = sv.engine

        assert(engine.fps_den > 0,
            string.format("MovePlayhead: engine.fps_den must be > 0, got %s", tostring(engine.fps_den)))
        local fps_float = engine.fps_num / engine.fps_den

        -- Read current position from engine (view) to compute target.
        -- NOTE: this relies on signals firing synchronously — engine position
        -- is updated by the playhead_changed handler before the next keystroke.
        local delta_frames = parse_duration(literal, fps_float)
        local current_frame = engine:get_position()
        local new_frame = math.max(0, current_frame + delta_frames)

        -- Update model — playhead_changed signal drives view (seek + display)
        local Sequence = require("models.sequence")
        local sequence = Sequence.load(sv.sequence_id)
        assert(sequence, "MovePlayhead: sequence not found: " .. tostring(sv.sequence_id))
        sequence.playhead_position = new_frame
        sequence:save()
        local Signals = require("core.signals")
        Signals.emit("playhead_changed", sv.sequence_id, new_frame)

        -- Scroll timeline viewport to keep playhead visible
        local timeline_state = require("ui.timeline.timeline_state")
        timeline_state.surface_playhead()

        -- Jog audio: play short audio burst for frame-step feel.
        -- Runs after signal (engine already seeked to new_frame).
        if engine.play_frame_audio then
            engine:play_frame_audio(new_frame)
        end

        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
