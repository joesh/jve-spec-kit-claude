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
        sequence_id = {},  -- auto-injected by command_manager (displayed side)
        playhead = {},     -- auto-injected from displayed engine's position
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

        -- FR-027 clean no-op: nothing loaded on the displayed side →
        -- sequence_id wasn't injected. Don't crash; just don't move.
        if args.sequence_id == nil or args.sequence_id == "" then return true end
        local seq_id = args.sequence_id
        local current_frame = args.playhead

        local Sequence = require("models.sequence")
        local sequence = Sequence.load(seq_id)
        assert(sequence, "MovePlayhead: sequence not found: " .. tostring(seq_id))
        local fps_num = sequence.frame_rate.fps_numerator
        local fps_den = sequence.frame_rate.fps_denominator
        assert(fps_den > 0,
            string.format("MovePlayhead: sequence fps_den must be > 0, got %s", tostring(fps_den)))
        local fps_float = fps_num / fps_den

        local delta_frames = parse_duration(literal, fps_float)
        if current_frame == nil then current_frame = sequence.playhead_position end
        assert(type(current_frame) == "number", string.format(
            "MovePlayhead: current_frame must be a number; got %s", type(current_frame)))

        -- Lower-bound clamp + model write + playhead_changed emission all
        -- live in the playhead primitive; transport's listener handles
        -- engine sync. The jog-audio burst is command-specific feedback.
        local new_frame = require("core.playhead")
            .set(seq_id, current_frame + delta_frames)

        require("ui.timeline.timeline_state").surface_playhead()
        require("core.playback.transport")
            .play_frame_audio_target_if_loaded(seq_id, new_frame)

        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
