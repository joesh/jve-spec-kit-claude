--- core.playhead — single source of truth for "move the playhead on a sequence".
---
--- The playhead has one domain invariant:
---
---     sequence.playhead_position >= sequence.start_timecode_frame
---
--- Every write-the-playhead surface (SetPlayhead, MovePlayhead, GoToStart,
--- GoToEnd, GoToMark, the marks park_at helper, ruler clicks, scrub) routes
--- through ``M.set`` so the invariant lives in exactly one place. Per-command
--- clamps elsewhere are wrong by construction — they leak the lower-bound
--- knowledge across the codebase and let a missing one corrupt the model.
---
--- Side effects: writes the sequence row + emits ``playhead_changed``.
--- ``transport``'s listener (registered at init) seeks the bound engines.
--- View modules (timeline_state.surface_playhead, sequence_monitor) react
--- to the signal independently. Callers wanting viewport-surface behavior
--- still call ``timeline_state.surface_playhead()`` themselves — that's a
--- UI concern, not a model one.
---
--- @file playhead.lua
local M = {}

local Sequence = require("models.sequence")
local Signals = require("core.signals")

--- Set the playhead on a sequence, clamping to the timeline's lower bound.
--- @param seq_id string  sequence id (required, non-empty)
--- @param requested_frame number  the frame the caller wants; will be
---     clamped up to ``sequence.start_timecode_frame`` if below.
--- @return number  the actual frame written (== requested_frame if in-range,
---     == sequence.start_timecode_frame if the request was below).
function M.set(seq_id, requested_frame)
    assert(type(seq_id) == "string" and seq_id ~= "",
        "core.playhead.set: seq_id required (non-empty string)")
    assert(type(requested_frame) == "number", string.format(
        "core.playhead.set: requested_frame must be a number; got %s",
        type(requested_frame)))

    local seq = Sequence.load(seq_id)
    assert(seq, "core.playhead.set: sequence not found: " .. seq_id)
    assert(type(seq.start_timecode_frame) == "number",
        "core.playhead.set: sequence missing start_timecode_frame")

    local actual = math.max(seq.start_timecode_frame, requested_frame)
    seq.playhead_position = actual
    assert(seq:save(), "core.playhead.set: save failed for sequence " .. seq_id)

    Signals.emit("playhead_changed", seq_id, actual)
    return actual
end

return M
