-- @file sequence_frame_rate.lua
--
-- Required state helper: sequence frame rate must exist and be well-formed.
local M = {}

function M.require_sequence_frame_rate(timeline_state, context_label)
    context_label = context_label or "sequence_frame_rate"
    if type(timeline_state) ~= "table" then
        error(string.format("%s: timeline_state must be a table (got %s)", context_label, type(timeline_state)))
    end
    if type(timeline_state.get_sequence_frame_rate) ~= "function" then
        error(string.format("%s: timeline_state.get_sequence_frame_rate missing", context_label))
    end

    local rate = timeline_state.get_sequence_frame_rate()
    if type(rate) ~= "table" then
        error(string.format("%s: get_sequence_frame_rate must return a table", context_label))
    end
    if rate.fps_numerator == nil or rate.fps_denominator == nil then
        error(string.format("%s: frame rate missing fps_numerator/fps_denominator", context_label))
    end

    return rate.fps_numerator, rate.fps_denominator
end

return M
