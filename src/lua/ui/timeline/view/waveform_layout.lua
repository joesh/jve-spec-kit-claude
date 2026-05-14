--- Audio clip waveform layout decisions.
--
-- A clip body of `clip_height` px normally splits into
--   [ wave area (top)            ][ label reserve (bottom, label_reserve px) ]
-- For tall clips this gives the label a stable home and the waveform a wide
-- area centred within it. As the track shrinks the wave area is the first
-- thing squeezed; below a usability threshold the label reservation eats
-- almost the whole clip and the wave collapses into a couple of pixels
-- stuck against the top edge. NLE convention at small heights is to drop
-- the label and let the waveform use the full clip height — visually it
-- "re-centres" because the wave area now spans the same range that center_y
-- already sits at.
--
-- Single decision point so it can be tested in isolation; callers only
-- consume `wave_y_offset`, `wave_height`, `label_visible`.
local M = {}

-- Pixel reserve normally taken from the bottom of an audio clip body for
-- the clip's name label. Co-located with MIN_WAVE_HEIGHT because they
-- jointly drive the single layout decision below — splitting them across
-- modules was a rule 2.5/2.6 smell from the first pass.
M.LABEL_RESERVE = 16

-- Minimum vertical space we want for a waveform before we'd rather sacrifice
-- the label entirely.
M.MIN_WAVE_HEIGHT = 12

--- Compute the waveform sub-rect inside a clip body.
-- @param clip_height number  pixel height of the clip body
-- @return wave_y_offset, wave_height, label_visible
function M.compute(clip_height)
    assert(type(clip_height) == "number" and clip_height > 0,
        "waveform_layout.compute: clip_height must be positive number, got "
        .. tostring(clip_height))

    local roomy = clip_height - M.LABEL_RESERVE
    if roomy >= M.MIN_WAVE_HEIGHT then
        return 0, roomy, true
    end
    -- Tight: drop the label, hand the waveform the whole clip body so it
    -- draws centred on the clip's vertical midline instead of squashed
    -- against the top.
    return 0, clip_height, false
end

return M
