--- Waveform utility functions — coordinate mapping for viewport-clipped waveform rendering.
--- @module waveform_utils
local M = {}

--- Compute the visible source sample range for a viewport-clipped clip.
---
--- When a clip extends beyond the viewport edges, only a portion is visible.
--- This function maps the visible pixel region back to the corresponding
--- source sample range, so peak data is queried only for what's on screen.
---
--- Direction is preserved: for a forward clip (source_in < source_out), the
--- returned vis_in <= vis_out. For a reverse clip (source_in > source_out),
--- vis_in >= vis_out. Zero-range clips are rejected.
---
--- @param source_in number clip source start (absolute TC samples) — may be > source_out for reverse clips
--- @param source_out number clip source end (absolute TC samples)
--- @param x number unclipped clip left edge in pixels (can be negative)
--- @param visible_x number clamped clip left edge (>= 0)
--- @param clip_width number full clip width in pixels
--- @param draw_width number visible portion width in pixels
--- @return number visible_source_in — source sample at left visible pixel
--- @return number visible_source_out — source sample at right visible pixel
function M.visible_source_range(source_in, source_out, x, visible_x, clip_width, draw_width)
    assert(type(source_in) == "number", "waveform_utils.visible_source_range: source_in must be number")
    assert(type(source_out) == "number", "waveform_utils.visible_source_range: source_out must be number")
    assert(source_in ~= source_out,
        "waveform_utils.visible_source_range: source range must be non-zero (source_in=" ..
        tostring(source_in) .. " source_out=" .. tostring(source_out) .. ")")
    assert(clip_width > 0, "waveform_utils.visible_source_range: clip_width must be > 0")
    assert(draw_width > 0, "waveform_utils.visible_source_range: draw_width must be > 0")

    local total_source = source_out - source_in          -- signed: negative for reverse clips
    local samples_per_pixel = total_source / clip_width  -- signed

    local left_clip_px = visible_x - x
    local right_clip_px = (x + clip_width) - (visible_x + draw_width)

    -- Fractional source positions at left/right visible pixel edges.
    local vis_in_f = source_in + left_clip_px * samples_per_pixel
    local vis_out_f = source_out - right_clip_px * samples_per_pixel

    -- Round to over-include slightly at each endpoint: vis_in toward source_in,
    -- vis_out toward source_out. Direction of rounding depends on clip direction.
    local vis_in, vis_out
    if source_out > source_in then
        -- Forward: source_in is lower bound, source_out is upper bound.
        vis_in = math.floor(vis_in_f)
        vis_out = math.ceil(vis_out_f)
    else
        -- Reverse: source_in is upper bound, source_out is lower bound.
        vis_in = math.ceil(vis_in_f)
        vis_out = math.floor(vis_out_f)
    end

    -- Clamp within overall source range regardless of direction.
    local lo = math.min(source_in, source_out)
    local hi = math.max(source_in, source_out)
    if vis_in < lo then vis_in = lo end
    if vis_in > hi then vis_in = hi end
    if vis_out < lo then vis_out = lo end
    if vis_out > hi then vis_out = hi end

    return vis_in, vis_out
end

--- Compute the on-screen sub-rectangle for a peak-query result whose
--- range was clamped by in-progress peak generation.
---
--- During generation, peak_cache.get_visible_peaks returns peaks whose
--- actual_start/actual_end may not cover the full requested range —
--- the peak frontier is only partway through the source file. The
--- waveform must be drawn ONLY over the corresponding pixel sub-window
--- so the unrendered tail stays blank (revealing as generation
--- continues), not stretched across the clip body.
---
--- Forward clips (peak_start < peak_end, reversed=false): the partial
--- frontier moves left→right; anchor the partial waveform at visible_x.
--- Reverse clips (reversed=true): the source increases left→right in
--- file order but the renderer draws peaks right-to-left, so the
--- partial frontier appears at the RIGHT edge of the visible window.
---
--- Returns x, width — pass these to add_waveform in place of the full
--- visible_x / draw_width when the result is partial. When the result
--- covers the full requested range, returns visible_x, draw_width
--- unchanged.
---
--- @param peak_start number requested source-sample start
--- @param peak_end number requested source-sample end (peak_start < peak_end)
--- @param actual_start number peaks-actual source-sample start
--- @param actual_end number peaks-actual source-sample end (clamped)
--- @param visible_x number on-screen pixel x of the full visible window
--- @param draw_width number on-screen pixel width of the full visible window
--- @param reversed boolean true for reverse clips
--- @return number x, number width — sub-rectangle for the partial waveform
function M.partial_waveform_window(peak_start, peak_end, actual_start, actual_end,
                                   visible_x, draw_width, reversed)
    assert(type(peak_start) == "number" and type(peak_end) == "number",
        "waveform_utils.partial_waveform_window: peak_start/peak_end must be numbers")
    assert(peak_end > peak_start,
        "waveform_utils.partial_waveform_window: peak_end must be > peak_start "
        .. "(caller is expected to have normalized reversed ranges before query)")
    assert(actual_end >= actual_start,
        "waveform_utils.partial_waveform_window: actual_end must be >= actual_start")
    assert(draw_width > 0,
        "waveform_utils.partial_waveform_window: draw_width must be > 0")

    local full_range = peak_end - peak_start
    local actual_range = actual_end - actual_start
    if actual_range >= full_range then
        return visible_x, draw_width
    end

    local fraction = actual_range / full_range
    local partial_width = math.floor(draw_width * fraction + 0.5)
    if partial_width < 1 then partial_width = 1 end
    if partial_width >= draw_width then
        return visible_x, draw_width
    end

    if reversed then
        return visible_x + (draw_width - partial_width), partial_width
    end
    return visible_x, partial_width
end

return M
