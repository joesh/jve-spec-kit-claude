--- Waveform utility functions — coordinate mapping for viewport-clipped waveform rendering.
--- @module waveform_utils
local M = {}

--- Compute the visible source sample range for a viewport-clipped clip.
---
--- When a clip extends beyond the viewport edges, only a portion is visible.
--- This function maps the visible pixel region back to the corresponding
--- source sample range, so peak data is queried only for what's on screen.
---
--- @param source_in number clip source start (absolute TC samples)
--- @param source_out number clip source end (absolute TC samples)
--- @param x number unclipped clip left edge in pixels (can be negative)
--- @param visible_x number clamped clip left edge (>= 0)
--- @param clip_width number full clip width in pixels
--- @param draw_width number visible portion width in pixels
--- @return number visible_source_in
--- @return number visible_source_out
function M.visible_source_range(source_in, source_out, x, visible_x, clip_width, draw_width)
    assert(type(source_in) == "number", "waveform_utils.visible_source_range: source_in must be number")
    assert(type(source_out) == "number", "waveform_utils.visible_source_range: source_out must be number")
    assert(source_out > source_in, "waveform_utils.visible_source_range: source_out must be > source_in")
    assert(clip_width > 0, "waveform_utils.visible_source_range: clip_width must be > 0")
    assert(draw_width > 0, "waveform_utils.visible_source_range: draw_width must be > 0")

    local total_source = source_out - source_in
    local samples_per_pixel = total_source / clip_width

    local left_clip_px = visible_x - x
    local right_clip_px = (x + clip_width) - (visible_x + draw_width)

    local vis_in = source_in + math.floor(left_clip_px * samples_per_pixel)
    local vis_out = source_out - math.floor(right_clip_px * samples_per_pixel)

    if vis_in < source_in then vis_in = source_in end
    if vis_out > source_out then vis_out = source_out end

    return vis_in, vis_out
end

return M
