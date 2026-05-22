--- SetPlayhead Command — persist absolute playhead + emit playhead_changed.
--
-- Two equivalent forms (callers pick whichever reads better):
--   • named:      { playhead_position = N }     -- integer TC-absolute frame
--   • positional: { _positional = {"01:00:05:12"} } -- HH:MM:SS:FF parsed at
--                                                     sequence frame_rate
-- Exactly one must be supplied. The string form is a thin convenience layer:
-- both resolve to the same integer frame, then delegate to core.playhead.set
-- which owns the lower-bound clamp + emits the playhead_changed signal.
-- Engine sync follows via transport's listener.
--
-- @file set_playhead.lua
local M = {}

local SPEC = {
    undoable = false,
    mutates_clips = false,
    args = {
        _positional       = {},
        project_id        = { required = true, kind = "string" },
        sequence_id       = { kind = "string" },
        playhead_position = {},
    },
}

-- Resolve the target frame from whichever form the caller used. Asserts on
-- both-supplied (ambiguous) and neither-supplied (missing arg). Returns the
-- integer TC-absolute frame.
local function resolve_target_frame(args, sequence)
    local tc_string = (args._positional or {})[1]
    local frame     = args.playhead_position

    assert((tc_string == nil) ~= (frame == nil), string.format(
        "SetPlayhead: provide exactly one of positional TC string "
        .. '(e.g. "01:00:05:12") OR playhead_position (integer frame); '
        .. "got tc=%s, playhead_position=%s",
        tostring(tc_string), tostring(frame)))

    if tc_string ~= nil then
        assert(type(tc_string) == "string", string.format(
            "SetPlayhead: positional arg must be a TC string; got %s",
            type(tc_string)))
        local frame_utils = require("core.frame_utils")
        local parsed = frame_utils.parse_timecode(tc_string, sequence.frame_rate)
        assert(parsed and type(parsed.frames) == "number", string.format(
            "SetPlayhead: failed to parse TC string %q (expected HH:MM:SS:FF)",
            tc_string))
        frame = parsed.frames
    end

    assert(type(frame) == "number", string.format(
        "SetPlayhead: resolved playhead must be a number; got %s (type %s)",
        tostring(frame), type(frame)))
    return frame
end

function M.register(executors, undoers, db)
    executors["SetPlayhead"] = function(command)
        local args = command:get_all_parameters()
        assert(args.sequence_id and args.sequence_id ~= "",
            "SetPlayhead: sequence_id is required")

        -- Sequence load only needed to resolve the TC-string positional
        -- against the right frame_rate; the actual write is delegated.
        local Sequence = require("models.sequence")
        local sequence = Sequence.load(args.sequence_id)
        assert(sequence,
            "SetPlayhead: sequence not found: " .. tostring(args.sequence_id))

        local frame = resolve_target_frame(args, sequence)
        require("core.playhead").set(args.sequence_id, frame)
        return { success = true }
    end

    return {
        ["SetPlayhead"] = { executor = executors["SetPlayhead"], spec = SPEC },
    }
end

return M
