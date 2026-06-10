--- Timeline view renderer: draws tracks, clips, gaps, selection
--- highlights, drag previews, and offline/codec overlays into the
--- timeline widget. Reads model state via an injected state_module
--- (normally ui.timeline.timeline_state; tests inject a stub) so the
--- renderer itself has no singleton dependency on live state. Never
--- mutates the model; pure read → Qt-binding-draw.
---
--- @file timeline_view_renderer.lua
local M = {}
local media_status = require("core.media.media_status")
local offline_note = require("core.media.offline_note")
local edge_drag_renderer = require("ui.timeline.edge_drag_renderer")
local color_utils = require("ui.color_utils")
local Command = require("command")
local command_manager = require("core.command_manager")
local log = require("core.logger").for_area("timeline")
local perf_log = require("core.logger").for_area("ui.scroll_perf")
local waveform_color = require("core.media.waveform_color")
local waveform_utils = require("core.media.waveform_utils")
local waveform_layout = require("ui.timeline.view.waveform_layout")
local track_state = require("ui.timeline.state.track_state")
local duplicate_track_map = require("core.duplicate_track_map")
local peak_cache = require("core.media.peak_cache")
local peak_constants = require("core.media.peak_constants")
local Signals = require("core.signals")

-- Throttle waveform diagnostics: once per media_id per project session.
-- Two distinct conditions, tracked separately so a coverage gap doesn't
-- mask a subsequent TC bug on the same media (or vice versa).
--   waveform_tc_drift_warned  — start_drift > threshold OR actual_end
--                               overshoots requested_end. Real bug; warn.
--   waveform_coverage_logged  — actual_end < requested_end by more than
--                               threshold. Expected after Media-Managed
--                               trims (Resolve ships a shorter file than
--                               the DRP claimed); event-level.
local waveform_tc_drift_warned = {}
local waveform_coverage_logged = {}
Signals.connect("project_changed", function()
    waveform_tc_drift_warned = {}
    waveform_coverage_logged = {}
end, 99)  -- low priority: cosmetic, after all model updates

-- Compare the source-sample range the renderer requested against what
-- peak_cache actually returned, and classify any disagreement. Called
-- once per clip per render tick after a successful peak fetch; throttled
-- to once per media_id per session via the module-level flag tables.
local function log_waveform_range_anomalies(
        media_id, peak_start, peak_end, actual_start, actual_end, max_drift)
    local start_drift = math.abs(actual_start - peak_start)

    -- Start-side drift = TC origin bug. Real regression; warn.
    if start_drift > max_drift and not waveform_tc_drift_warned[media_id] then
        waveform_tc_drift_warned[media_id] = true
        log.warn("waveform TC drift: requested_start=%d actual_start=%d drift=%d threshold=%d clip=%s",
            peak_start, actual_start, start_drift, max_drift, media_id)
    end

    -- End-side: actual_end < peak_end means the file is shorter than
    -- the clip's requested range. Expected after a Resolve Media-Manage
    -- trim (file shipped shorter than DRP claimed). Log at event level.
    -- actual_end > peak_end is genuinely unexpected — warn.
    if actual_end < peak_end and (peak_end - actual_end) > max_drift then
        if not waveform_coverage_logged[media_id] then
            waveform_coverage_logged[media_id] = true
            log.event("waveform coverage gap: requested_end=%d actual_end=%d gap=%d clip=%s",
                peak_end, actual_end, peak_end - actual_end, media_id)
        end
    elseif actual_end > peak_end and (actual_end - peak_end) > max_drift then
        if not waveform_tc_drift_warned[media_id] then
            waveform_tc_drift_warned[media_id] = true
            log.warn("waveform end overshoot: requested_end=%d actual_end=%d overshoot=%d threshold=%d clip=%s",
                peak_end, actual_end, actual_end - peak_end, max_drift, media_id)
        end
    end
end

local function build_edge_signature(edges)
    local parts = {}
    for _, edge in ipairs(edges or {}) do
        local clip_id = edge.clip_id or ""
        local edge_type = edge.edge_type or ""
        table.insert(parts, clip_id .. ":" .. edge_type)
    end
    return table.concat(parts, "|")
end

local IMPLIED_EDGE_DIM_FACTOR = 0.55

local function coerce_clip_entries(entries)
    if not entries then
        return nil
    end
    if entries.clip_id then
        return {entries}
    end
    return entries
end

local function is_gap_preview(entry)
    if not entry then return false end
    if entry.is_gap then return true end
    if type(entry.clip_id) == "string" and entry.clip_id:find("^gap_") then return true end
    return false
end

-- All coords are integer frames - no conversion needed
local function normalize_preview_entries(entries)
    local normalized = {}
    for _, entry in ipairs(coerce_clip_entries(entries) or {}) do
        local start_value = entry.new_start_value or entry.sequence_start or entry.start_value
        local duration_value = entry.new_duration or entry.duration
        assert(type(start_value) == "number", "normalize_preview_entries: start_value must be integer")
        assert(type(duration_value) == "number", "normalize_preview_entries: duration_value must be integer")
        table.insert(normalized, {
            clip_id = entry.clip_id,
            new_start_value = start_value,
            new_duration = duration_value,
            edge_type = entry.edge_type,
            raw_edge_type = entry.raw_edge_type,
            is_gap = is_gap_preview(entry)
        })
    end
    return normalized
end

local function build_preview_from_payload(payload)
    if type(payload) ~= "table" then
        return nil
    end
    local affected_entries = normalize_preview_entries(payload.affected_clips or payload.affected_clip) or {}
    local preview = {
        affected_clips = {},
        shifted_clips = normalize_preview_entries(payload.shifted_clips) or {},
        shift_blocks = payload.shift_blocks or {},
        off_tracks = payload.off_tracks or {},
        clamped_edges = payload.clamped_edges or {},
        edge_preview = payload.edge_preview
    }
    -- Keep only non-gap affected entries — gaps are not the user's
    -- direct gesture target visually, and downstream movers are
    -- represented by the unified block bbox, not by per-clip outlines.
    -- (Pre-block-bbox there was a fallback copying shifted_clips into
    -- affected_clips so pure-gap drags still showed something; the
    -- bbox makes that fallback obsolete and harmful — it caused every
    -- downstream clip to get its own per-clip outline.)
    for _, entry in ipairs(affected_entries) do
        if not entry.is_gap then
            table.insert(preview.affected_clips, entry)
        end
    end
    return preview
end

-- All coords are integer frames - no coercion needed
local function assert_integer(value, context)
    if value == nil then return nil end
    assert(type(value) == "number", context .. ": value must be integer, got " .. type(value))
    return value
end

local function get_preview_clip(state_module, preview_clip_cache, preview_entry)
    if not preview_entry or not preview_entry.clip_id then
        return nil
    end
    local clip = preview_clip_cache and preview_clip_cache[preview_entry.clip_id] or nil
    if clip then
        return clip
    end
    if state_module then
        clip = state_module.get_tab_strip():clip_by_id(preview_entry.clip_id)
        if clip then
            return clip
        end
    end
    return nil
end

local PREVIEW_RECT_COLOR = "#ffff00"

-- Width of the bars used by stroke_outline_rect. Selection, preview, and
-- shift-block outlines all share this; tweaking one place changes them all.
local OUTLINE_THICKNESS = 2

-- Stroke a 4-sided rectangular outline (top/bottom/left/right) using
-- OUTLINE_THICKNESS-wide bars drawn INSIDE the bounds. Caller passes the
-- full content rect; helper validates dimensions and emits nothing if the
-- rect is too small to contain the bars meaningfully.
local function stroke_outline_rect(view, x, y, w, h, color)
    local t = OUTLINE_THICKNESS
    if w < 1 or h < 1 then return end
    timeline.add_rect(view.widget, x,         y,         w, t, color)
    timeline.add_rect(view.widget, x,         y + h - t, w, t, color)
    timeline.add_rect(view.widget, x,         y,         t, h, color)
    timeline.add_rect(view.widget, x + w - t, y,         t, h, color)
end

-- Horizontal pixel span of a clip in the current viewport. Returns
-- visible_x, draw_width, x, clip_width — x/clip_width are the unclamped
-- pixel position/width (callers need them for waveform source windows
-- and edge-dash decisions) — or nil when the clip lies fully outside the
-- viewport horizontally. Exposed on M so the draw-stability contract
-- test can pin it directly (same pattern as lower_bound_start_frames).
--
-- Sliver floor: a clip that overlaps the visible time window is ALWAYS
-- drawn, at minimum one pixel column. On the absolute pixel grid (see
-- viewport_state.time_to_pixel) a sub-pixel clip's width comes out 0 or
-- 1 depending on where its start lands relative to the grid lines, and
-- the grid re-aligns whenever pixels-per-frame changes — without the
-- floor, thin clips strobe on/off during a continuous zoom drag.
local function clip_h_span(state_module, clip_start, clip_duration, width)
    local x = state_module.time_to_pixel(clip_start, width)
    local clip_end_px = state_module.time_to_pixel(clip_start + clip_duration, width)
    local clip_width = clip_end_px - x
    if x + clip_width < 0 or x > width then return nil end
    local visible_x = x
    local visible_width = clip_width
    if visible_x < 0 then
        visible_width = visible_width + visible_x
        visible_x = 0
    end
    if visible_x + visible_width > width then
        visible_width = width - visible_x
    end
    if visible_width < 1 then
        visible_width = 1
        -- A clip whose first visible frame is the last frame of the
        -- window maps to x == width; the sliver shifts back onto the
        -- final pixel column instead of landing offscreen.
        if visible_x + visible_width > width then
            visible_x = width - 1
        end
    end
    return visible_x, visible_width, x, clip_width
end

local function draw_preview_outline(view, clip, start_value, duration_value, state_module, width, height)
    assert(clip, "draw_preview_outline: clip is required (caller must filter nil)")
    assert(clip.track_id, "draw_preview_outline: clip.track_id missing (clip_id="
        .. tostring(clip.id) .. "); model invariant violated")
    assert(type(start_value) == "number",
        "draw_preview_outline: start_value must be a number (clip_id=" .. tostring(clip.id) .. ")")
    assert(type(duration_value) == "number",
        "draw_preview_outline: duration_value must be a number (clip_id=" .. tostring(clip.id) .. ")")

    -- Track layout may legitimately be absent during reflow / first-frame
    -- races; silent skip matches the convention at every other callsite
    -- of get_track_y_by_id in this renderer.
    local track_y = view.get_track_y_by_id(clip.track_id, height)
    if track_y < 0 then return end
    local track_height = view.get_track_visual_height(clip.track_id)
    if not track_height or track_height <= 0 then return end

    -- Shared cull + clamp + sliver floor; avoids drawing thousands of
    -- offscreen outlines during ripple previews while keeping sub-pixel
    -- preview targets visible.
    local visible_x, visible_w = clip_h_span(state_module, start_value, duration_value, width)
    if not visible_x then return end

    local clip_y = track_y + 5
    local clip_height = track_height - 10
    stroke_outline_rect(view, visible_x, clip_y, visible_w, clip_height, PREVIEW_RECT_COLOR)
end

-- Boundary check: every preview entry produced by BRE / nudge / similar
-- commands MUST carry new_start_value and new_duration. Asserting at the
-- consumer surfaces producer contract violations loudly; the renderer
-- never silently substitutes a default. Exposed on M as the named
-- contract so both production and tests reference the same predicate.
local function assert_affected_clip_entry(entry)
    assert(type(entry) == "table",
        "preview affected_clips: entry must be a table (got " .. type(entry) .. ")")
    assert(entry.clip_id,
        "preview affected_clips: entry missing clip_id")
    assert(type(entry.new_start_value) == "number",
        "preview affected_clips: entry missing new_start_value (clip_id="
        .. tostring(entry.clip_id) .. "); producer contract violated")
    assert(type(entry.new_duration) == "number",
        "preview affected_clips: entry missing new_duration (clip_id="
        .. tostring(entry.clip_id) .. "); producer contract violated")
end

-- Outline the clips whose edges the user is directly dragging (the
-- gesture's manipulation target). Downstream clips that shift as a
-- consequence of the ripple are NOT outlined here — they are
-- represented as a single bounding block by render_shift_block_outlines.
local function render_preview_rectangles(view, preview_data, preview_clip_cache, state_module, width, height)
    if not preview_data then return end
    local affected = preview_data.affected_clips
    if not affected and preview_data.affected_clip then
        affected = {preview_data.affected_clip}
    end

    for _, entry in ipairs(affected or {}) do
        if not entry.is_gap then
            assert_affected_clip_entry(entry)
            local clip = get_preview_clip(state_module, preview_clip_cache, entry)
            if clip then
                draw_preview_outline(view, clip, entry.new_start_value, entry.new_duration,
                                     state_module, width, height)
            end
        end
    end
end

local function lower_bound_start_frames(clips, start_frames)
    if type(clips) ~= "table" or #clips == 0 then
        return 1
    end
    local lo = 1
    local hi = #clips + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        local clip = clips[mid]
        assert(clip, "lower_bound_start_frames: nil entry at index " .. mid
            .. " of " .. #clips .. "; track clip index corrupt")
        assert(type(clip.sequence_start) == "number",
            "lower_bound_start_frames: clip.sequence_start must be a number at index "
            .. mid .. " (clip_id=" .. tostring(clip.id) .. ", got "
            .. type(clip.sequence_start) .. "); track clip index corrupt")
        if clip.sequence_start < start_frames then
            lo = mid + 1
        else
            hi = mid
        end
    end
    return lo
end

-- Coalescing threshold for downstream preview outlines, expressed as a
-- fraction of the viewport's pixel width. Adjacent downstream clips on
-- the same track whose pixel gap is below this threshold merge into one
-- visual outline run — a giant bbox over the whole shift extent is
-- mostly offscreen and uninformative; tight contours that follow the
-- actual clips are what tells the user what's moving.
local SHIFT_OUTLINE_COALESCE_FRACTION = 1 / 20

--- Walk a track's clips and return the pixel x-intervals to outline.
-- Inputs are already filtered for "this track is part of a shift
-- block"; this function does the per-clip math: skip excluded/gaps,
-- shift by delta, cull entirely offscreen, clip to viewport bounds,
-- and return one {x_start, x_end} per surviving clip in left-to-right
-- order.
local function collect_shifted_runs_for_track(track_clips, block_start, delta_frames,
                                              excluded, time_to_pixel,
                                              width, viewport_start, viewport_end)
    local runs = {}
    local start_index = lower_bound_start_frames(track_clips, block_start)
    if start_index > 1 then
        start_index = start_index - 1
    end
    for i = start_index, #track_clips do
        local clip = track_clips[i]
        assert(clip, "collect_shifted_runs_for_track: nil entry at index " .. i
            .. "; track clip index corrupt")
        assert(type(clip.sequence_start) == "number",
            "collect_shifted_runs_for_track: clip.sequence_start must be a number (clip_id="
            .. tostring(clip.id) .. "); track clip index corrupt")
        assert(type(clip.duration) == "number",
            "collect_shifted_runs_for_track: clip.duration must be a number (clip_id="
            .. tostring(clip.id) .. "); track clip index corrupt")
        if clip.sequence_start >= block_start
            and not clip.is_gap
            and not (clip.id and excluded[clip.id])
        then
            local shifted_start = clip.sequence_start + delta_frames
            if shifted_start < 0 then shifted_start = 0 end
            local shifted_end = shifted_start + clip.duration
            -- Viewport cull (frame coords)
            if shifted_end > viewport_start and shifted_start < viewport_end then
                local x0 = time_to_pixel(shifted_start, width)
                local x1 = time_to_pixel(shifted_end, width)
                if x0 < 0 then x0 = 0 end
                if x1 > width then x1 = width end
                if x1 - x0 >= 1 then
                    table.insert(runs, {x_start = x0, x_end = x1})
                end
            end
        end
    end
    return runs
end

--- Merge adjacent runs whose pixel gap is below the threshold. Runs are
-- already in left-to-right order; a single linear pass suffices.
local function coalesce_runs(runs, threshold_px)
    if #runs == 0 then return runs end
    local merged = {{x_start = runs[1].x_start, x_end = runs[1].x_end}}
    for i = 2, #runs do
        local last = merged[#merged]
        local r = runs[i]
        if (r.x_start - last.x_end) < threshold_px then
            if r.x_end > last.x_end then last.x_end = r.x_end end
        else
            table.insert(merged, {x_start = r.x_start, x_end = r.x_end})
        end
    end
    return merged
end

-- Partition preview_data.shift_blocks into (global, per_track) — a block
-- with a track_id binds to that track; a block without one applies to
-- every track that has no per-track override (the "global" fallback).
local function partition_shift_blocks(shift_blocks)
    local global_block = nil
    local per_track = {}
    for _, block in ipairs(shift_blocks) do
        if type(block) == "table" then
            if block.track_id then
                per_track[block.track_id] = block
            elseif not global_block then
                global_block = block
            end
        end
    end
    return global_block, per_track
end

-- Build the {clip_id → true} set of clips that are user-directly-dragged
-- and therefore handled by render_preview_rectangles, not by the shift
-- block contour.
local function build_excluded_clip_set(affected_clips)
    local excluded = {}
    for _, entry in ipairs(affected_clips or {}) do
        if entry and entry.clip_id then excluded[entry.clip_id] = true end
    end
    return excluded
end

-- Draw the contoured outline for one track of one shift block. Returns
-- nothing; emits zero or more outline rects via stroke_outline_rect.
local function render_shift_block_for_track(view, track_id, block, excluded,
                                            state_module, width,
                                            viewport_start, viewport_end,
                                            threshold_px, height)
    local track_clips = state_module.get_tab_strip():track_clip_index(track_id) or {}
    if #track_clips == 0 then return end

    local runs = collect_shifted_runs_for_track(
        track_clips, block.start_frames, block.delta_frames,
        excluded, state_module.time_to_pixel,
        width, viewport_start, viewport_end)
    local coalesced = coalesce_runs(runs, threshold_px)
    if #coalesced == 0 then return end

    local ty = view.get_track_y_by_id(track_id, height)
    local th = view.get_track_visual_height(track_id)
    if ty < 0 or not th or th <= 0 then return end

    local clip_y = ty + 5
    local clip_h = th - 10
    if clip_h < 1 then return end

    for _, run in ipairs(coalesced) do
        stroke_outline_rect(view, run.x_start, clip_y,
                            run.x_end - run.x_start, clip_h, PREVIEW_RECT_COLOR)
    end
end

--- Outline downstream movers per track, tightly contoured.
-- For each visible track that participates in a shift block, walk its
-- downstream clips, cull what's offscreen, coalesce neighbors that are
-- visually adjacent (gap < width × SHIFT_OUTLINE_COALESCE_FRACTION),
-- and draw one 4-sided outline per coalesced run. This replaces the
-- prior single-bbox-across-all-tracks approach which produced an
-- outline that was mostly offscreen on long timelines.
local function render_shift_block_outlines(view, preview_data, state_module, width, height, viewport_start, viewport_end)
    if not preview_data or type(preview_data.shift_blocks) ~= "table" or #preview_data.shift_blocks == 0 then
        return
    end
    if type(viewport_start) ~= "number" or type(viewport_end) ~= "number" then
        return
    end
    assert(state_module, "timeline_view_renderer: state_module required for shift block previews")

    local global_block, per_track = partition_shift_blocks(preview_data.shift_blocks)
    if not global_block and not next(per_track) then return end

    local excluded = build_excluded_clip_set(preview_data.affected_clips)
    local threshold_px = width * SHIFT_OUTLINE_COALESCE_FRACTION
    local off_tracks = preview_data.off_tracks or {}

    for _, track in ipairs(view.filtered_tracks or {}) do
        local track_id = track and track.id
        if track_id and not off_tracks[track_id] then
            local block = per_track[track_id] or global_block
            if block and block.start_frames and block.delta_frames and block.delta_frames ~= 0 then
                render_shift_block_for_track(view, track_id, block, excluded,
                                             state_module, width,
                                             viewport_start, viewport_end,
                                             threshold_px, height)
            end
        end
    end
end

local function render_edge_handle(view, clip, normalized_edge, raw_edge_type, start_value, duration_value, color, state_module, width, height, viewport_duration)
    if not clip or not clip.track_id or not start_value or not duration_value then
        return
    end
    local cy = view.get_track_y_by_id(clip.track_id, height)
    if cy < 0 then return end
    local th = view.get_track_visual_height(clip.track_id)
    if not th or th <= 0 then return end

    local sx = state_module.time_to_pixel(start_value, width)
    local cw = math.floor((duration_value / viewport_duration) * width) - 1
    if cw < 0 then cw = 0 end
    local ch = th - 10
    local handle_y = cy + 5
    local ex = (normalized_edge == "in") and sx or (sx + cw)
    local is_in = (normalized_edge == "in")
    local bw = 8
    local bt = 2
    if is_in then
        timeline.add_rect(view.widget, ex, handle_y, bt, ch, color)
        timeline.add_rect(view.widget, ex, handle_y, bw, bt, color)
        timeline.add_rect(view.widget, ex, handle_y + ch - bt, bw, bt, color)
    else
        timeline.add_rect(view.widget, ex - bt, handle_y, bt, ch, color)
        timeline.add_rect(view.widget, ex - bw, handle_y, bw, bt, color)
        timeline.add_rect(view.widget, ex - bw, handle_y + ch - bt, bw, bt, color)
    end
end

local function normalize_lead_edge(lead_edge, clip_lookup)
    assert(lead_edge and lead_edge.clip_id, "lead_edge is required for edge preview")
    return {
        clip_id = lead_edge.clip_id,
        edge_type = lead_edge.edge_type,
        track_id = lead_edge.track_id or clip_lookup[lead_edge.clip_id],
        trim_type = lead_edge.trim_type
    }
end

local function ensure_edge_preview(drag_state, state_module)

    local function clear_preview_state()
        if drag_state then
            drag_state.preview_data = nil
            drag_state.preview_request_token = nil
            drag_state.preview_clamped_delta_frames = nil
            drag_state.clamped_edges = nil
        end
    end

    if not drag_state or drag_state.type ~= "edges" then
        clear_preview_state()
        log.detail("no drag_state or not edges; skipping preview")
        return
    end

    local edges = drag_state.edges or {}
    if #edges == 0 then
        clear_preview_state()
        log.detail("no edges available")
        return
    end

    local sequence_id = state_module.get_tab_strip():active_sequence_id()
    local project_id = state_module.get_project_id and state_module.get_project_id()
    if not sequence_id or sequence_id == "" or not project_id or project_id == "" then
        clear_preview_state()
        log.detail("missing sequence/project id")
        return
    end

    -- delta_frames is now an integer directly from drag state
    local delta_frames = assert_integer(drag_state.delta_frames, "ensure_edge_preview: delta_frames")
    if not delta_frames then
        clear_preview_state()
        log.detail("missing delta (delta_frames)")
        return
    end

    local signature = build_edge_signature(edges)
    local token = string.format("%s@%d", signature, delta_frames)
    if drag_state.preview_request_token == token and drag_state.preview_data then
        log.detail("preview already computed for token %s", token)
        return
    end

    log.detail("requesting preview for token %s", token)

    local snapshot = drag_state.preloaded_clip_snapshot
    local active_region = drag_state.timeline_active_region
    if type(snapshot) ~= "table" or type(active_region) ~= "table" then
        clear_preview_state()
        log.detail("missing preloaded snapshot or active region")
        return
    end

    local clip_track_lookup = snapshot.clip_track_lookup or {}
    assert(drag_state.lead_edge, "edge drag should always provide a lead_edge")

    local normalized_lead = normalize_lead_edge(drag_state.lead_edge, clip_track_lookup)

    local edge_infos = {}
    for _, edge in ipairs(edges) do
        local resolved_track_id = edge.track_id
        if not resolved_track_id and edge.clip_id then
            resolved_track_id = clip_track_lookup[edge.clip_id]
            if not resolved_track_id then
                local clip = state_module.get_tab_strip():clip_by_id(edge.clip_id)
                resolved_track_id = clip and clip.track_id
            end
        end
        table.insert(edge_infos, {
            clip_id = edge.clip_id,
            edge_type = edge.edge_type,
            track_id = resolved_track_id,
            trim_type = edge.trim_type
        })
    end
    local cmd = Command.create("BatchRippleEdit", project_id)
    cmd:set_parameters({
        ["edge_infos"] = edge_infos,
        ["sequence_id"] = sequence_id,
        ["delta_frames"] = delta_frames,
        ["dry_run"] = true,
        ["__preloaded_clip_snapshot"] = snapshot,
        ["__timeline_active_region"] = active_region,
    })
    if normalized_lead then
        cmd:set_parameter("lead_edge", normalized_lead)
    end
    local executor = command_manager.get_executor("BatchRippleEdit")

    if not executor then
        clear_preview_state()
        log.detail("executor not available for dry run")
        return
    end

    local ok, result, payload = pcall(executor, cmd)
    if not ok then
        clear_preview_state()
        log.detail("dry run threw error: %s", tostring(result))
        return
    end

    if result == false then
        clear_preview_state()
        log.detail("dry run returned false")
        return
    end

    local preview_payload = nil
    if type(payload) == "table" then
        preview_payload = payload
    elseif type(result) == "table" then
        preview_payload = result
    end

    local preview_data = build_preview_from_payload(preview_payload)
    assert(preview_data, "Edge preview dry run must return preview payload")
    assert(type(preview_data.edge_preview) == "table"
            and type(preview_data.edge_preview.edges) == "table",
        "ensure_edge_preview: BatchRippleEdit dry-run payload missing edge_preview.edges")
    drag_state.preview_data = preview_data
    drag_state.clamped_edges = (drag_state.preview_data and drag_state.preview_data.clamped_edges) or {}

    drag_state.preview_request_token = token
    log.detail("preview ready; affected=%d", #(drag_state.preview_data.affected_clips or {}))

    -- Clamped delta is integer frames
    local clamped_frames = cmd.get_parameter and cmd:get_parameter("clamped_delta_frames")
    drag_state.preview_clamped_delta_frames = clamped_frames
end

-- Per-clip destination tracks for the clip-drag GHOST, computed by the SAME
-- algorithm the commit uses (core.duplicate_track_map) so the preview can
-- never show a placement DuplicateClips wouldn't produce. Only the owning
-- pane (the one under the cursor) computes this; it stashes the map on the
-- drag state so the non-owning pane (video↔audio split) reuses it.
--
-- Returns the map { [clip_id] = track_id | needs_create_descriptor } or nil
-- when there's no anchor to map from. The cursor's target track shares the
-- anchor's type (split panes guarantee it); with no track under the cursor
-- yet, the anchor's own track stands in so the ghost shows a time-only move.
local function compute_clip_drag_target_map(view, drag_state, height, state_module)
    local anchor_clip
    local aid = drag_state.anchor_clip_id
    if aid then
        for _, c in ipairs(drag_state.clips) do
            if c.id == aid then anchor_clip = c; break end
        end
    end
    anchor_clip = anchor_clip or drag_state.clips[1]
    if not anchor_clip then return nil end

    local tracks = state_module.get_tab_strip():displayed_tracks()
    local by_id = {}
    for _, t in ipairs(tracks) do by_id[t.id] = t end

    local anchor_track = by_id[anchor_clip.track_id]
    if not anchor_track then return nil end

    local current_y = drag_state.current_y or drag_state.start_y
    local target_tid = view.get_track_id_at_y(current_y, height)
    local target_track = (target_tid and by_id[target_tid]) or anchor_track

    return duplicate_track_map.map_duplicate_targets(
        tracks, anchor_track, target_track, drag_state.clips)
end

local function truncate_label(label, max_width)
    if not label or label == "" or max_width <= 0 then return "" end
    local approx_char_width = 7
    local max_chars = math.floor(max_width / approx_char_width)
    if max_chars <= 0 then return "" end
    if #label <= max_chars then return label end
    if max_chars <= 3 then return label:sub(1, max_chars) end
    return label:sub(1, max_chars - 3) .. "..."
end

-- Draw alternating-row background fills + track separator lines for every
-- visible track. Layout came from view.update_layout_cache; this is pure
-- iteration + draw. Off-screen rows are skipped.
local function render_track_backgrounds(view, state_module, layout_by_index, width, height)
    for i, _track in ipairs(view.filtered_tracks) do
        local entry = layout_by_index[i]
        if entry then
            local y = entry.y
            local h = entry.height
            state_module.debug_record_track_layout(view.debug_id, _track.id, y, h)
            if y + h > 0 and y < height then
                local color = (i % 2 == 0) and state_module.colors.track_even or state_module.colors.track_odd
                timeline.add_rect(view.widget, 0, y, width, h, color)
                timeline.add_line(view.widget, 0, y, width, y, state_module.colors.grid_line, 1)
            end
        end
    end
end

-- Draw the selection outline rectangle around every currently-selected
-- gap. Thin-row degenerate case (gh < 2*thick or w < 2*thick) falls back
-- to a single filled rect since 4 separate strokes would over-draw.
local function render_selected_gaps_overlay(view, state_module, width, height)
    local selected_gaps = state_module.get_selected_gaps and state_module.get_selected_gaps() or {}
    if #selected_gaps == 0 then return end
    for _, gap in ipairs(selected_gaps) do
        local gap_start = gap.start_value
        local gap_duration = gap.duration
        assert(type(gap_start) == "number", "timeline_view_renderer: gap.start_value must be integer")
        assert(type(gap_duration) == "number", "timeline_view_renderer: gap.duration must be integer")
        local gap_y = view.get_track_y_by_id(gap.track_id, height)
        if gap_y >= 0 then
            local th = view.get_track_visual_height(gap.track_id)
            local sx = state_module.time_to_pixel(gap_start, width)
            local ex = state_module.time_to_pixel(gap_start + gap_duration, width)
            local w = ex - sx
            if w > 0 then
                local gt = gap_y + 5
                local gh = th - 10
                local outline = state_module.colors.gap_selected_outline or state_module.colors.clip_selected
                local thick = math.max(1, math.floor((state_module.dimensions.clip_outline_thickness or 4)/2))
                if gh > thick*2 and w > thick*2 then
                    timeline.add_rect(view.widget, sx, gt, w, thick, outline)
                    timeline.add_rect(view.widget, sx, gt + gh - thick, w, thick, outline)
                    timeline.add_rect(view.widget, sx, gt, thick, gh, outline)
                    timeline.add_rect(view.widget, sx + w - thick, gt, thick, gh, outline)
                else
                    timeline.add_rect(view.widget, sx, gt, w, math.max(thick, gh), outline)
                end
            end
        end
    end
end

-- Diagonal hash stripes across every locked track row. Premiere-style
-- read-only indicator that shows regardless of clip content.
local function render_lock_overlay(view, layout_by_index, width, height)
    local LOCK_HASH_COLOR = 0x55ccaa00
    local LOCK_HASH_SPACING = 12
    for i, track in ipairs(view.filtered_tracks) do
        if track.locked then
            local entry = layout_by_index[i]
            if entry and entry.y + entry.height > 0 and entry.y < height then
                local row_y = entry.y
                local row_h = entry.height
                local start_x = -row_h
                local x = start_x
                while x < width do
                    timeline.add_line(view.widget,
                        x, row_y + row_h,
                        x + row_h, row_y,
                        LOCK_HASH_COLOR, 1)
                    x = x + LOCK_HASH_SPACING
                end
            end
        end
    end
end

-- Render one clip instance into the timeline view. The render_ctx
-- bundles the per-frame captures the closure used to take from its
-- enclosing scope: view, state_module, pixel dimensions, the layout
-- index, and the per-id selection lookup. `outline_only` is used by
-- the clip-drag preview path which draws just the selection outline
-- at the cursor position over the base render.
local function draw_clip_instance(ctx, clip, render_track_id, clip_start, clip_duration, outline_only)
    if not clip or not render_track_id or not clip_start or not clip_duration then
        return
    end
    if clip_duration <= 0 then return end
    local layout_by_id = ctx.layout_by_id
    local track_layout = layout_by_id and layout_by_id[render_track_id]
    if not track_layout then return end

    local view, state_module = ctx.view, ctx.state_module
    local width, height = ctx.width, ctx.height
    local selected_lookup = ctx.selected_lookup

    local y = track_layout.y + 5
    local clip_height = track_layout.height - 10
    if y + clip_height <= 0 or y >= height then return end

    local visible_x, draw_width, x, clip_width =
        clip_h_span(state_module, clip_start, clip_duration, width)
    if not visible_x then return end
    local clip_enabled = clip.enabled ~= false

    media_status.ensure_clip_status(clip)

    local is_audio = (track_layout.track_type == "AUDIO")
    local body_color, text_color
    local label_prefix = ""
    if clip.offline then
        body_color = is_audio and state_module.colors.clip_audio_offline or state_module.colors.clip_video_offline
        text_color = state_module.colors.clip_offline_text
        local is_codec = (clip.error_code == "Unsupported" or clip.error_code == "DecodeFailed")
        label_prefix = is_codec and "CODEC UNAVAIL - " or "OFFLINE - "
        -- Offline + disabled: dim the bright red so the clip reads
        -- as "not participating in the cut right now" rather than
        -- demanding attention. Standard NLE convention.
        if not clip_enabled then
            body_color = color_utils.dim_hex(body_color, 0.5)
            text_color = color_utils.dim_hex(text_color, 0.7)
        end
    elseif clip_enabled then
        body_color = is_audio and state_module.colors.clip_audio or state_module.colors.clip_video
        text_color = state_module.colors.text
    else
        body_color = is_audio and state_module.colors.clip_audio_disabled or state_module.colors.clip_video_disabled
        text_color = state_module.colors.clip_disabled_text
    end
    if not body_color then body_color = state_module.colors.clip end

    if not outline_only then
        timeline.add_rect(view.widget, visible_x, y, draw_width, clip_height, body_color)

        local has_waveform = false
        local label_visible = true

        if is_audio and not clip.offline
                and track_state.get_waveform_enabled(render_track_id)
                and (clip.resolved_media and clip.resolved_media.id) and draw_width > 1 and clip_width > 0 then
            local vis_src_in, vis_src_out = waveform_utils.visible_source_range(
                clip.source_in, clip.source_out, x, visible_x, clip_width, draw_width)

            -- Reverse clips: vis_src_in > vis_src_out. Peak cache wants
            -- forward-ordered [start, end]; normalize for the query and
            -- set reversed so the renderer draws peaks right-to-left.
            local reversed = vis_src_in > vis_src_out
            local peak_start = reversed and vis_src_out or vis_src_in
            local peak_end = reversed and vis_src_in or vis_src_out

            -- Peak queries are per whole pixel column; draw coords are
            -- float (exact time→pixel map), so round the column count at
            -- this boundary only.
            local wave_px = math.floor(draw_width + 0.5)
            local peaks, count, actual_start, actual_end = peak_cache.get_visible_peaks(
                (clip.resolved_media and clip.resolved_media.id), peak_start, peak_end, wave_px)
            if peaks and count > 0 then
                local samples_per_pixel = (peak_end - peak_start) / wave_px
                local mip_level = peak_constants.select_level(samples_per_pixel)
                local max_drift = peak_constants.SAMPLES_PER_LEVEL[mip_level]
                log_waveform_range_anomalies((clip.resolved_media and clip.resolved_media.id),
                    peak_start, peak_end, actual_start, actual_end, max_drift)

                -- In-progress peak generation returns peaks whose actual
                -- range is clamped to the decoder frontier. Draw the
                -- waveform only over the corresponding pixel sub-window
                -- so the unwritten tail stays blank and reveals as
                -- generation advances — NLE convention.
                local wave_x, wave_w = waveform_utils.partial_waveform_window(
                    peak_start, peak_end, actual_start, actual_end,
                    visible_x, draw_width, reversed)
                local wave_col = waveform_color.derive(body_color)
                local wave_y_offset, wave_height, lbl_vis =
                    waveform_layout.compute(clip_height)
                label_visible = lbl_vis
                timeline.add_waveform(view.widget, wave_x, y + wave_y_offset,
                    wave_w, wave_height, peaks, count, wave_col, reversed)
                has_waveform = true
            end
        end

        local label_padding = 10
        local max_label_width = draw_width - label_padding
        if max_label_width > 35 then
            -- Audio clips store source_in/source_out in SAMPLES; the raw
            -- shortfall in samples displayed as "Nf" reads as video
            -- frames. display_rate (= sequence fps) rescales the delta
            -- into timeline-frame units for both audio and video.
            local rate = state_module.get_sequence_frame_rate
                and state_module.get_sequence_frame_rate()
            local display_rate
            if rate and rate.fps_numerator and rate.fps_denominator
                and rate.fps_denominator > 0 then
                display_rate = rate.fps_numerator / rate.fps_denominator
            end
            local label_suffix = offline_note.short_suffix(
                clip.offline_note, clip.source_in, clip.source_out,
                display_rate)
            local display_label = truncate_label(
                label_prefix .. (clip.label or clip.name or clip.id or "") .. label_suffix,  -- lint-allow: R010 display label fallback chain; gap clips have no label/name
                max_label_width)
            if display_label ~= "" and label_visible then
                local label_baseline
                if has_waveform then
                    label_baseline = y + clip_height - 4
                else
                    label_baseline = y + math.min(clip_height - 10, 22)
                end
                timeline.add_text(view.widget, visible_x + 5, label_baseline, display_label, text_color)
            end
        end
    end

    local is_selected = selected_lookup[clip.id] == true

    if is_selected or outline_only then
        stroke_outline_rect(view, visible_x, y, draw_width, clip_height,
                            state_module.colors.clip_selected)
    elseif draw_width ~= clip_width or visible_x ~= x then
        local dash_height = math.min(clip_height, 12)
        local dash_col = state_module.colors.clip_selected
        if x < 0 then timeline.add_rect(view.widget, 0, y + (clip_height - dash_height)/2, OUTLINE_THICKNESS, dash_height, dash_col) end
        if x + clip_width > width then timeline.add_rect(view.widget, width - OUTLINE_THICKNESS, y + (clip_height - dash_height)/2, OUTLINE_THICKNESS, dash_height, dash_col) end
    end

    -- draw_width > 1, not > 0: on a 1px sliver the stripe would overpaint
    -- the entire body and the sliver would twinkle in the boundary color.
    if not outline_only and draw_width > 1 then
        local boundary_col = assert(state_module.colors.clip_boundary,
            "timeline_view_renderer: state_module.colors.clip_boundary is nil " ..
            "— expected color for the right-edge boundary stripe on each clip")
        timeline.add_rect(view.widget, visible_x + draw_width - 1, y, 1, clip_height, boundary_col)
    end
end

-- Iterate every visible track and draw its clips. Uses the per-track
-- index (track_clip_index) — never bulk-scans displayed_clips (which
-- the strip's forbid_bulk_clip_read scope enforces). The visible-window
-- slice via lower_bound_start_frames skips clips entirely before the
-- viewport in one binary-search step, with a back-off by 1 to catch a
-- clip whose start is upstream of the viewport but whose end is inside.
local function draw_visible_clips(ctx, viewport_start, viewport_end)
    assert(type(viewport_start) == "number" and type(viewport_end) == "number",
        "timeline_view_renderer: viewport frames are required")
    local view, state_module = ctx.view, ctx.state_module
    local layout_by_id = ctx.layout_by_id

    for _, track in ipairs(view.filtered_tracks) do
        local track_id = track and track.id
        local track_layout = track_id and layout_by_id and layout_by_id[track_id] or nil
        if track_id and track_layout and track_layout.y < ctx.height and (track_layout.y + track_layout.height) > 0 then
            local track_clips = state_module.get_tab_strip():track_clip_index(track_id)
            if track_clips and #track_clips > 0 then
                local start_index = lower_bound_start_frames(track_clips, viewport_start)
                if start_index > 1 then start_index = start_index - 1 end
                for i = start_index, #track_clips do
                    local clip = track_clips[i]
                    if clip and type(clip.sequence_start) == "number"
                            and type(clip.duration) == "number"
                            and not clip.is_gap then
                        local clip_start = clip.sequence_start
                        if clip_start >= viewport_end then break end
                        local clip_end = clip_start + clip.duration
                        if clip_end > viewport_start then
                            draw_clip_instance(ctx, clip, track_id, clip_start, clip.duration, false)
                        end
                    end
                end
            end
        end
    end
end

-- Mark In/Out range highlight.
--
-- Open-ended mark range domain rule (mirrored in monitor_mark_bar.lua;
-- both surfaces draw the same range). A user can set only one of mark
-- in / mark out and the range is well-defined:
--   • mark_in present, mark_out nil  → range is [mark_in, end-of-domain)
--   • mark_in nil, mark_out present  → range is [start-of-domain, mark_out)
--   • both present                   → range is [mark_in, mark_out)
--   • neither present                → no range (early-return above)
--
-- "End-of-domain" / "start-of-domain" depend on which surface is drawing:
-- the timeline renderer uses the viewport (mark range clipped to what's
-- visible), the monitor mark bar uses the loaded clip's [start_frame,
-- total_frames). The `or 0` / `or viewport_end` below are the domain
-- floor / ceiling for THIS surface — NOT silent fallbacks per rule 2.13.
-- Removing them would mis-render single-ended marks as empty ranges.
local function render_mark_overlay(view, state_module, width, height, viewport_start, viewport_end, mark_in, mark_out)
    if not mark_in and not mark_out then return end
    local eff_in = mark_in or 0
    local eff_out = mark_out or viewport_end
    if eff_out <= eff_in then return end
    local visible_start = math.max(eff_in, viewport_start)
    local visible_end = math.min(eff_out, viewport_end)
    if visible_end <= visible_start then return end

    local start_x = state_module.time_to_pixel(visible_start, width)
    local end_x = state_module.time_to_pixel(visible_end, width)
    if end_x <= start_x then end_x = start_x + 1 end
    local region_width = math.max(1, end_x - start_x)
    timeline.add_rect(view.widget, start_x, 0, region_width, height, state_module.colors.mark_range_fill)
end

-- Build the per-frame render context. Captures viewport state, mark
-- frames, layout cache, selection lookup, and the resolved drag states
-- so phase helpers can each take a single `ctx` arg (rule 2.5 — top-level
-- M.render reads as an algorithm, phases handle the dirty work).
--
-- Owns the clip vs edge drag-state resolution: prefer this view's local
-- drag_state when it owns the gesture; otherwise consult the shared
-- state so the non-owning pane (video↔audio) still renders previews.
local function build_render_ctx(view)
    local state_module = view.state
    local width, height = timeline.get_dimensions(view.widget)

    state_module.debug_begin_layout_capture(view.debug_id, width, height)

    local viewport_start    = assert(state_module.get_viewport_start_time(), "timeline_view_renderer: viewport_start_time is nil")
    local viewport_duration = assert(state_module.get_viewport_duration(), "timeline_view_renderer: viewport_duration is nil")
    local viewport_end      = viewport_start + viewport_duration

    assert(state_module.get_display_mark_in,
        "timeline_view_renderer: state_module missing get_display_mark_in — timeline_state required")
    assert(state_module.get_display_mark_out,
        "timeline_view_renderer: state_module missing get_display_mark_out — timeline_state required")

    view.update_layout_cache(height)

    local selected_lookup = {}
    for _, sel in ipairs(state_module.get_selected_clips()) do
        if sel and sel.id then selected_lookup[sel.id] = true end
    end

    local clip_drag_state, clip_drag_owns = nil, false
    if view.drag_state and view.drag_state.type == "clips" then
        clip_drag_state, clip_drag_owns = view.drag_state, true
    elseif state_module.get_active_clip_drag_state then
        clip_drag_state = state_module.get_active_clip_drag_state()
    end

    local edge_drag_state = nil
    if view.drag_state and view.drag_state.type == "edges" then
        edge_drag_state = view.drag_state
    elseif state_module.get_active_edge_drag_state then
        edge_drag_state = state_module.get_active_edge_drag_state()
    end

    return {
        view              = view,
        state_module      = state_module,
        width             = width,
        height            = height,
        layout_by_index   = view.track_layout_cache.by_index,
        layout_by_id      = view.track_layout_cache.by_id,
        selected_lookup   = selected_lookup,
        viewport_start    = viewport_start,
        viewport_duration = viewport_duration,
        viewport_end      = viewport_end,
        playhead_position = state_module.get_playhead_position(),
        mark_in           = state_module.get_display_mark_in(),
        mark_out          = state_module.get_display_mark_out(),
        clip_drag_state   = clip_drag_state,
        clip_drag_owns    = clip_drag_owns,
        edge_drag_state   = edge_drag_state,
        dragging_edges    = edge_drag_state and edge_drag_state.type == "edges",
        perf_t0           = os.clock(),
    }
end

-- Phase: clip-drag preview overlay. Draws outline-only copies of the
-- dragged clips at the destination tracks the COMMIT will use (shared
-- core.duplicate_track_map), plus the time delta.
local function render_clip_drag_preview(ctx)
    local cd = ctx.clip_drag_state
    if not cd or cd.type ~= "clips" then return end
    assert(type(cd.delta_frames) == "number",
        "timeline_view_renderer: clip drag state missing delta_frames")

    -- Owning pane computes the per-clip target map and stashes it; the
    -- non-owning pane (V↔A split) reuses it so both render the same plan.
    local target_map
    if ctx.clip_drag_owns then
        target_map = compute_clip_drag_target_map(ctx.view, cd, ctx.height, ctx.state_module)
        cd._preview_target_map = target_map
    else
        target_map = cd._preview_target_map
    end
    if not target_map then return end

    for _, clip in ipairs(cd.clips) do
        if clip and clip.id then
            local target = target_map[clip.id]
            -- A `needs_create` descriptor (table) names a track that doesn't
            -- exist yet; the commit auto-creates it, but the ghost has no row
            -- to draw on, so that half is omitted from the preview.
            if type(target) == "string" then
                local start_value = clip.sequence_start + cd.delta_frames
                draw_clip_instance(ctx, clip, target, start_value, clip.duration, true)
            end
        end
    end
end

-- Sub-phase: edge handles during an active drag — read preview_data
-- for clamped/applied deltas + per-edge limiter colors.
local function render_edge_handles_during_drag(ctx, edge_drag_state, preview_clip_cache)
    local preview_data = assert(edge_drag_state and edge_drag_state.preview_data,
        "timeline_view_renderer: missing preview_data")
    local edge_preview = preview_data.edge_preview
    assert(type(edge_preview) == "table"
            and type(edge_preview.edges) == "table"
            and #edge_preview.edges > 0,
        "timeline_view_renderer: missing edge_preview.edges")

    for _, entry in ipairs(edge_preview.edges) do
        if type(entry) == "table" and entry.clip_id and entry.raw_edge_type and entry.normalized_edge then
            local clip = get_preview_clip(ctx.state_module, preview_clip_cache, {clip_id = entry.clip_id})
            if clip then
                local applied_delta = tonumber(entry.applied_delta_frames) or 0
                local start_value, duration_value, normalized_edge =
                    edge_drag_renderer.compute_preview_geometry(
                        clip, entry.normalized_edge, applied_delta, entry.raw_edge_type)
                if start_value and duration_value then
                    local color = (entry.is_limiter and ctx.state_module.colors.edge_selected_limit)
                        or ctx.state_module.colors.edge_selected_available
                    if entry.is_implied then
                        color = color_utils.dim_hex(color, IMPLIED_EDGE_DIM_FACTOR)
                    end
                    render_edge_handle(ctx.view, clip, normalized_edge, entry.raw_edge_type,
                        start_value, duration_value, color,
                        ctx.state_module, ctx.width, ctx.height, ctx.viewport_duration)
                end
            end
        end
    end
end

-- Sub-phase: static edge handles when no drag is active — selection
-- rendering at zero delta with default available color.
local function render_static_edge_handles(ctx, edges_to_render, edge_delta, edge_drag_state, preview_clip_cache)
    local previews = edge_drag_renderer.build_preview_edges(
        edges_to_render, edge_delta, {},
        ctx.state_module.colors,
        (edge_drag_state and edge_drag_state.lead_edge) or nil)

    for _, p in ipairs(previews) do
        local clip = get_preview_clip(ctx.state_module, preview_clip_cache, p)
        if clip then
            local start_value, duration_value, normalized_edge =
                edge_drag_renderer.compute_preview_geometry(
                    clip, p.edge_type, p.delta, p.raw_edge_type)
            if start_value and duration_value then
                local color = p.color or ctx.state_module.colors.edge_selected_available
                render_edge_handle(ctx.view, clip, normalized_edge, p.raw_edge_type,
                    start_value, duration_value, color,
                    ctx.state_module, ctx.width, ctx.height, ctx.viewport_duration)
            end
        end
    end
end

-- Phase: edge-drag preview overlay. Drives the drag-state preview
-- rectangles + shift-block outlines when active, then renders the
-- edge handles themselves (drag or static branch).
local function render_edge_drag_preview(ctx)
    local edge_drag_state = ctx.edge_drag_state
    local preview_clip_cache = {}
    local edge_delta = 0
    local edges_to_render = ctx.state_module.get_selected_edges() or {}

    if ctx.dragging_edges then
        ensure_edge_preview(edge_drag_state, ctx.state_module)
        local requested_delta = assert_integer(edge_drag_state.delta_frames, "render: edge delta_frames")
        local clamped_delta = assert_integer(edge_drag_state.preview_clamped_delta_frames, "render: clamped_delta_frames")
        edge_delta = clamped_delta or requested_delta or 0
        edges_to_render = edge_drag_state.edges or edges_to_render

        local preview_data = edge_drag_state.preview_data
        if preview_data then
            render_preview_rectangles(ctx.view, preview_data, preview_clip_cache,
                ctx.state_module, ctx.width, ctx.height)
            render_shift_block_outlines(ctx.view, preview_data, ctx.state_module,
                ctx.width, ctx.height, ctx.viewport_start, ctx.viewport_end)
        end
    end

    if edges_to_render and #edges_to_render > 0 then
        if ctx.dragging_edges then
            render_edge_handles_during_drag(ctx, edge_drag_state, preview_clip_cache)
        else
            render_static_edge_handles(ctx, edges_to_render, edge_delta, edge_drag_state, preview_clip_cache)
        end
    end
end

-- Phase: playhead vertical line. Skipped when offscreen.
local function render_playhead(ctx)
    if ctx.playhead_position < ctx.viewport_start
        or ctx.playhead_position > ctx.viewport_end then return end
    local px = ctx.state_module.time_to_pixel(ctx.playhead_position, ctx.width)
    log.detail("TIMELINE[%s]: width=%d playhead_x=%d playhead_frames=%d",
        ctx.view.debug_id or "?", ctx.width, px, ctx.playhead_position)
    timeline.add_line(ctx.view.widget, px, 0, px, ctx.height,
        ctx.state_module.colors.playhead, 2)
end

-- Phase: snap indicator line during edge drag when the drag is snapped.
local function render_snap_indicator(ctx)
    local eds = ctx.edge_drag_state
    if not (eds and eds.snap_info and eds.snap_info.snapped) then return end
    local st = eds.snap_info.snap_point.time
    if st < ctx.viewport_start or st > ctx.viewport_end then return end
    local sx = ctx.state_module.time_to_pixel(st, ctx.width)
    timeline.add_line(ctx.view.widget, sx, 0, sx, ctx.height, 0x00FFFF, 2)
end

function M.render(view)
    if not view.widget then return end
    local ctx = build_render_ctx(view)
    if not ctx then return end

    timeline.clear_commands(view.widget)
    -- Paint-time x-snapping anchors to the content grid so panning is a
    -- rigid translation (clip widths can't breathe ±1 device px as the
    -- fractional phase walks during scroll). The renderer needs the pan
    -- offset in float pixels: viewport_start at the current px/frame scale.
    timeline.set_pan_offset_px(view.widget,
        ctx.viewport_start * (ctx.width / ctx.viewport_duration))
    render_track_backgrounds(view, ctx.state_module, ctx.layout_by_index, ctx.width, ctx.height)

    -- Base rendering must never bulk-scan all clips — per-track iteration
    -- via track_clip_index is the contract. forbid_bulk_clip_read flips a
    -- flag on the strip; displayed_clips() asserts on it.
    ctx.state_module.get_tab_strip():forbid_bulk_clip_read(function()
        draw_visible_clips(ctx, ctx.viewport_start, ctx.viewport_end)
    end)

    render_selected_gaps_overlay(view, ctx.state_module, ctx.width, ctx.height)
    render_clip_drag_preview(ctx)
    render_edge_drag_preview(ctx)
    render_lock_overlay(view, ctx.layout_by_index, ctx.width, ctx.height)
    render_mark_overlay(view, ctx.state_module, ctx.width, ctx.height,
        ctx.viewport_start, ctx.viewport_end, ctx.mark_in, ctx.mark_out)
    render_playhead(ctx)
    render_snap_indicator(ctx)

    timeline.update(view.widget)
    perf_log.detail("timeline_view.render: %.3fms viewport_start=%d duration=%d",
        (os.clock() - ctx.perf_t0) * 1000, ctx.viewport_start, ctx.viewport_duration)
end

-- Named contract boundaries. Exposed so producer-side tests can pin
-- the contract directly without staging full preview-data through the
-- renderer dispatch (which rebuilds preview_data via ensure_edge_preview
-- on every render and would clobber a test fixture).
M.assert_affected_clip_entry = assert_affected_clip_entry
M.lower_bound_start_frames = lower_bound_start_frames
M.clip_h_span = clip_h_span

return M
