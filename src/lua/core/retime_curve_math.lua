--- Frame snapping + frame→native conversion for the DRP↔DRT retime-curve
-- round-trip.
--
-- Resolve's Media-Managed exports cut source on whole-frame boundaries, but
-- curve evaluation lands within a few float ULPs of the true seconds value; at
-- native_rate=48000 a 1-ULP miss amplifies to a 1-sample shift.
-- FRAME_SNAP_EPSILON absorbs that sub-ULP undershoot so an "essentially
-- integer" frame-scaled value snaps to the right whole frame.
--
-- Shared by importers.drp_importer (the curve walk that recovers source range)
-- and exporters.drt_writer (the reverse-retime author that inverts it). The
-- snapping tolerance and the frame→native rounding MUST match on both sides or
-- the round-trip drifts by a frame — keeping them here is the single source.
local M = {}

-- Largest sub-ULP undershoot tolerated when snapping a near-integer frame value.
M.FRAME_SNAP_EPSILON = 1e-6

-- Snap a frame-scaled value DOWN to the last whole frame at or below it.
function M.snap_floor(scaled)
    return math.floor(scaled + M.FRAME_SNAP_EPSILON)
end

-- Snap a frame-scaled value UP to the first whole frame at or above it.
function M.snap_ceil(scaled)
    return math.ceil(scaled - M.FRAME_SNAP_EPSILON)
end

-- Convert a sequence-rate frame index to the media's native units (frames for
-- video, samples for audio), rounding to nearest.
function M.frames_to_native(frame, native_rate, frame_rate)
    return math.floor(frame * native_rate / frame_rate + 0.5)
end

return M
