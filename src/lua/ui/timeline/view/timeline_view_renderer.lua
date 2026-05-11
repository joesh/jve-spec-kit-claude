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
local track_state = require("ui.timeline.state.track_state")
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
        local start_value = entry.new_start_value or entry.timeline_start or entry.start_value
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
    for _, entry in ipairs(affected_entries) do
        if not entry.is_gap then
            table.insert(preview.affected_clips, entry)
        end
    end
    if (#preview.affected_clips == 0) and (#preview.shifted_clips > 0) then
        for _, entry in ipairs(preview.shifted_clips) do
            table.insert(preview.affected_clips, {
                clip_id = entry.clip_id,
                new_start_value = entry.new_start_value,
                new_duration = entry.new_duration,
                edge_type = entry.edge_type,
                raw_edge_type = entry.raw_edge_type,
                is_gap = false
            })
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
    if state_module and state_module.get_clip_by_id then
        clip = state_module.get_clip_by_id(preview_entry.clip_id)
        if clip then
            return clip
        end
    end
    return nil
end

local PREVIEW_RECT_COLOR = "#ffff00"

local function draw_preview_outline(view, clip, start_value, duration_value, state_module, width, height, viewport_duration)
    if not clip or not clip.track_id or not start_value or not duration_value then
        return
    end
    local track_y = view.get_track_y_by_id(clip.track_id, height)
    if track_y < 0 then return end
    local track_height = view.get_track_visual_height(clip.track_id)
    if not track_height or track_height <= 0 then return end

    local end_value = start_value + duration_value
    local start_px = state_module.time_to_pixel(start_value, width)
    local end_px = state_module.time_to_pixel(end_value, width)
    local width_px = end_px - start_px
    if width_px < 1 then width_px = 1 end

    -- Viewport cull + clip-to-viewport to avoid drawing thousands of offscreen
    -- outlines during ripple previews.
    local visible_x = start_px
    local visible_w = width_px
    if visible_x > width or (visible_x + visible_w) < 0 then
        return
    end
    if visible_x < 0 then
        visible_w = visible_w + visible_x
        visible_x = 0
    end
    if visible_x + visible_w > width then
        visible_w = width - visible_x
    end
    if visible_w < 1 then
        return
    end

    local clip_y = track_y + 5
    local clip_height = track_height - 10
    timeline.add_rect(view.widget, visible_x, clip_y, visible_w, 2, PREVIEW_RECT_COLOR)
    timeline.add_rect(view.widget, visible_x, clip_y + clip_height - 2, visible_w, 2, PREVIEW_RECT_COLOR)
    timeline.add_rect(view.widget, visible_x, clip_y, 2, clip_height, PREVIEW_RECT_COLOR)
    timeline.add_rect(view.widget, visible_x + visible_w - 2, clip_y, 2, clip_height, PREVIEW_RECT_COLOR)
end

local function render_preview_rectangles(view, preview_data, preview_clip_cache, state_module, width, height, viewport_duration)
    if not preview_data then return end
    local affected = preview_data.affected_clips
    if not affected and preview_data.affected_clip then
        affected = {preview_data.affected_clip}
    end

    for _, entry in ipairs(affected or {}) do
        if not entry.is_gap then
            local clip = get_preview_clip(state_module, preview_clip_cache, entry)
            if clip then
                local start_value = entry.new_start_value or clip.timeline_start
                local duration_value = entry.new_duration or clip.duration
                draw_preview_outline(view, clip, start_value, duration_value, state_module, width, height, viewport_duration)
            end
        end
    end

    for _, shift in ipairs(preview_data.shifted_clips or {}) do
        local clip = get_preview_clip(state_module, preview_clip_cache, {clip_id = shift.clip_id})
        if clip and shift.new_start_value then
            local existing_start = clip.timeline_start
            local new_start = shift.new_start_value
            -- All coords are now integers, simple comparison
            if new_start ~= existing_start then
                draw_preview_outline(view, clip, new_start, clip.duration, state_module, width, height, viewport_duration)
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
        -- All coords are integer frames now
        local clip_start = clip and clip.timeline_start
        if type(clip_start) ~= "number" then
            -- Defensive: if the index contains malformed entries, fall back to
            -- scanning from the front rather than risking an infinite loop.
            return 1
        end
        if clip_start < start_frames then
            lo = mid + 1
        else
            hi = mid
        end
    end
    return lo
end

--- Compute the bounding box (in frames) of all clips in a shift block on one track.
-- Returns min_start, max_end (both shifted by delta) or nil if no clips found.
-- This is the "opaque block" that shifts as a unit — the bounded edit region
-- only needs to know its extent, not its individual clips.
local function compute_shift_block_bounds(track_clips, block_start, delta_frames, excluded)
    local min_start = math.huge
    local max_end = -math.huge
    local found = false

    local start_index = lower_bound_start_frames(track_clips, block_start)
    if start_index > 1 then
        start_index = start_index - 1
    end

    for i = start_index, #track_clips do
        local clip = track_clips[i]
        if not clip or type(clip.timeline_start) ~= "number" or type(clip.duration) ~= "number" then
            goto continue_bounds
        end
        if clip.timeline_start < block_start then
            goto continue_bounds
        end
        if clip.is_gap then
            goto continue_bounds
        end
        if clip.id and excluded[clip.id] then
            goto continue_bounds
        end

        local shifted_start = clip.timeline_start + delta_frames
        if shifted_start < 0 then shifted_start = 0 end
        local shifted_end = shifted_start + clip.duration

        if shifted_start < min_start then min_start = shifted_start end
        if shifted_end > max_end then max_end = shifted_end end
        found = true

        ::continue_bounds::
    end

    if not found then return nil, nil end
    return min_start, max_end
end

local function render_shift_block_outlines(view, preview_data, state_module, width, height, viewport_duration, viewport_start, viewport_end)
    if not preview_data or type(preview_data.shift_blocks) ~= "table" or #preview_data.shift_blocks == 0 then
        return
    end
    if type(viewport_start) ~= "number" or type(viewport_end) ~= "number" then
        return
    end
    if not (state_module and state_module.get_track_clip_index) then
        error("timeline_view_renderer: state_module.get_track_clip_index is required for shift block previews", 2)
    end

    local global_block = nil
    local per_track = {}
    for _, block in ipairs(preview_data.shift_blocks) do
        if type(block) == "table" then
            if block.track_id then
                per_track[block.track_id] = block
            elseif not global_block then
                global_block = block
            end
        end
    end
    if not global_block and not next(per_track) then
        return
    end

    local excluded = {}
    for _, entry in ipairs(preview_data.affected_clips or {}) do
        if entry and entry.clip_id then excluded[entry.clip_id] = true end
    end
    for _, entry in ipairs(preview_data.shifted_clips or {}) do
        if entry and entry.clip_id then excluded[entry.clip_id] = true end
    end

    -- Compute bounding box across ALL tracks — one big outline for the
    -- entire shift block, spanning from topmost to bottommost affected track.
    local global_min_frames = math.huge
    local global_max_frames = -math.huge
    local min_track_y = math.huge
    local max_track_bottom = -math.huge
    local found_any = false

    local off_tracks = preview_data.off_tracks or {}
    local visible_tracks = view.filtered_tracks or {}
    for _, track in ipairs(visible_tracks) do
        local track_id = track and track.id
        if track_id and not off_tracks[track_id] then
            local block = per_track[track_id] or global_block
            if block and block.start_frames and block.delta_frames and block.delta_frames ~= 0 then
                local track_clips = state_module.get_track_clip_index(track_id) or {}
                if #track_clips > 0 then
                    local min_start, max_end = compute_shift_block_bounds(
                        track_clips, block.start_frames, block.delta_frames, excluded)
                    if min_start then
                        if min_start < global_min_frames then global_min_frames = min_start end
                        if max_end > global_max_frames then global_max_frames = max_end end

                        local ty = view.get_track_y_by_id(track_id, height)
                        local th = view.get_track_visual_height(track_id)
                        if ty >= 0 and th and th > 0 then
                            if ty < min_track_y then min_track_y = ty end
                            if ty + th > max_track_bottom then max_track_bottom = ty + th end
                            found_any = true
                        end
                    end
                end
            end
        end
    end

    if not found_any then return end

    -- Convert frame bounds to pixels
    local start_px = state_module.time_to_pixel(global_min_frames, width)
    local end_px = state_module.time_to_pixel(global_max_frames, width)

    -- Viewport cull + clip
    if start_px > width or end_px < 0 then return end
    if start_px < 0 then start_px = 0 end
    if end_px > width then end_px = width end

    local block_width = end_px - start_px
    if block_width < 1 then return end

    local block_y = min_track_y + 5
    local block_h = (max_track_bottom - min_track_y) - 10
    if block_h < 1 then return end

    -- One big outline around the entire shift block
    timeline.add_rect(view.widget, start_px, block_y, block_width, 2, PREVIEW_RECT_COLOR)
    timeline.add_rect(view.widget, start_px, block_y + block_h - 2, block_width, 2, PREVIEW_RECT_COLOR)
    timeline.add_rect(view.widget, start_px, block_y, 2, block_h, PREVIEW_RECT_COLOR)
    timeline.add_rect(view.widget, start_px + block_width - 2, block_y, 2, block_h, PREVIEW_RECT_COLOR)
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

    local sequence_id = state_module.get_sequence_id and state_module.get_sequence_id()
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
            if not resolved_track_id and state_module.get_clip_by_id then
                local clip = state_module.get_clip_by_id(edge.clip_id)
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

local function get_track_with_offset(state_module, track_id, offset)
    if not offset or offset == 0 then return track_id end
    local tracks = state_module.get_all_tracks()
    local original_index = nil
    for i, track in ipairs(tracks) do
        if track.id == track_id then original_index = i; break end
    end
    if not original_index then return track_id end
    local new_index = original_index + offset
    if new_index < 1 or new_index > #tracks then return track_id end
    local original_track = tracks[original_index]
    local target_track = tracks[new_index]
    if target_track and original_track and target_track.track_type == original_track.track_type then
        return target_track.id
    end
    return track_id
end

--- Compute target track hint for clip drag preview (owning pane only).
--- Returns preview_target_id (string track ID for single-track), preview_track_offset (number for multi-track).
--- Single-track selection: returns target track ID directly.
--- Multi-track selection: returns numeric offset applied to each clip's track.
local function compute_clip_drag_track_hint(view, drag_state, height, state_module)
    local current_y = drag_state.current_y or drag_state.start_y
    local target_tid = view.get_track_id_at_y(current_y, height)
    if not target_tid then return nil, nil end

    local anchor_clip = nil
    local aid = drag_state.anchor_clip_id
    if aid then
        for _, c in ipairs(drag_state.clips) do
            if c.id == aid then anchor_clip = c; break end
        end
    end
    if not anchor_clip then anchor_clip = drag_state.clips[1] end
    if not anchor_clip then return nil, nil end

    local multi = false
    for _, c in ipairs(drag_state.clips) do
        if c.track_id ~= drag_state.clips[1].track_id then multi = true; break end
    end

    local tracks = state_module.get_all_tracks()
    local anchor_idx, target_idx
    for i, t in ipairs(tracks) do
        if t.id == anchor_clip.track_id then anchor_idx = i end
        if t.id == target_tid then target_idx = i end
    end

    if anchor_idx and target_idx then
        local offset = target_idx - anchor_idx
        if offset ~= 0 then
            if multi then return nil, offset else return target_tid, nil end
        end
        if not multi then return target_tid, nil end
    else
        if not multi then return target_tid, nil end
    end
    return nil, nil
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

function M.render(view)
    if not view.widget then return end
    local perf_t0 = os.clock()
    local state_module = view.state
    local width, height = timeline.get_dimensions(view.widget)

    state_module.debug_begin_layout_capture(view.debug_id, width, height)
    timeline.clear_commands(view.widget)

    -- Viewport state (all integer frames)
    local viewport_start = state_module.get_viewport_start_time()
    local viewport_duration = state_module.get_viewport_duration()
    local viewport_end = viewport_start + viewport_duration
    local playhead_position = state_module.get_playhead_position()
    assert(state_module.get_display_mark_in,
        "timeline_view_renderer: state_module missing get_display_mark_in — timeline_state required")
    assert(state_module.get_display_mark_out,
        "timeline_view_renderer: state_module missing get_display_mark_out — timeline_state required")
    local mark_in  = state_module.get_display_mark_in()
    local mark_out = state_module.get_display_mark_out()

    -- Compute layout
    view.update_layout_cache(height) -- Call layout logic on view object

    -- Draw Tracks
    local layout_cache = view.track_layout_cache
    local layout_by_index = layout_cache.by_index
    for i, track in ipairs(view.filtered_tracks) do
        local entry = layout_by_index[i]
        if entry then
            local y = entry.y
            local h = entry.height
            state_module.debug_record_track_layout(view.debug_id, track.id, y, h)
            if y + h > 0 and y < height then
                local color = (i % 2 == 0) and state_module.colors.track_even or state_module.colors.track_odd
                timeline.add_rect(view.widget, 0, y, width, h, color)
                timeline.add_line(view.widget, 0, y, width, y, state_module.colors.grid_line, 1)
            end
        end
    end

    local selected_clips = state_module.get_selected_clips()
    local selected_lookup = {}
    for _, sel in ipairs(selected_clips) do
        if sel and sel.id then
            selected_lookup[sel.id] = true
        end
    end

    local layout_by_id = view.track_layout_cache.by_id

    local function draw_clip_instance(clip, render_track_id, clip_start, clip_duration, outline_only)
        if not clip or not render_track_id or not clip_start or not clip_duration then
            return
        end
        -- All coords are integer frames
        if clip_duration <= 0 then
            return
        end
        local track_layout = layout_by_id and layout_by_id[render_track_id]
        if not track_layout then
            return
        end

        local y = track_layout.y
        local track_height = track_layout.height
        local clip_end = clip_start + clip_duration
        local x = state_module.time_to_pixel(clip_start, width)
        local clip_end_px = state_module.time_to_pixel(clip_end, width)
        y = y + 5
        local clip_width = clip_end_px - x
        local clip_height = track_height - 10

        local visible_x = x
        local visible_width = clip_width
        if visible_x < 0 then
            visible_width = visible_width + visible_x
            visible_x = 0
        end
        if visible_x + visible_width > width then
            visible_width = width - visible_x
        end

        if x + clip_width < 0 or x > width or y + clip_height <= 0 or y >= height then
            return
        end
        if visible_width < 1 then
            return
        end

        local draw_width = visible_width
        local clip_enabled = clip.enabled ~= false

        -- Stamp clip with cached media status (pure reader — no probing)
        media_status.ensure_clip_status(clip)

        -- Resolve colors
        local is_audio = (track_layout.track_type == "AUDIO")
        local body_color, text_color
        local label_prefix = ""
        if clip.offline then
            body_color = is_audio and state_module.colors.clip_audio_offline or state_module.colors.clip_video_offline
            text_color = state_module.colors.clip_offline_text
            local is_codec = (clip.error_code == "Unsupported" or clip.error_code == "DecodeFailed")
            label_prefix = is_codec and "CODEC UNAVAIL - " or "OFFLINE - "
            -- Offline-AND-disabled: dim the bright red so the clip
            -- reads as "not participating in the cut right now"
            -- instead of demanding attention. Matches the standard
            -- NLE convention where disabled clips draw dimmed.
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

            -- Layout: label at bottom (16px), waveform in remaining upper area
            local LABEL_RESERVE = 16
            local has_waveform = false

            -- Waveform display (audio clips only, when enabled and peaks available).
            -- Required-data invariants (source_in/source_out presence, non-zero range)
            -- are enforced by waveform_utils.visible_source_range via asserts —
            -- surfacing a bug is preferable to a silent skip.
            if is_audio and not clip.offline
                    and track_state.get_waveform_enabled(render_track_id)
                    and (clip.resolved_media and clip.resolved_media.id) and draw_width > 1 and clip_width > 0 then
                local vis_src_in, vis_src_out = waveform_utils.visible_source_range(
                    clip.source_in, clip.source_out, x, visible_x, clip_width, draw_width)

                -- Reverse clips: vis_src_in > vis_src_out. Peak cache always expects
                -- forward-ordered [start, end] sample range; normalize for the query
                -- and set reversed flag so the renderer draws peaks right-to-left.
                -- waveform_utils asserts non-zero source range, so vis_src_in ~=
                -- vis_src_out here and peak_end > peak_start is guaranteed.
                local reversed = vis_src_in > vis_src_out
                local peak_start = reversed and vis_src_out or vis_src_in
                local peak_end = reversed and vis_src_in or vis_src_out

                local peaks, count, actual_start, actual_end = peak_cache.get_visible_peaks(
                    (clip.resolved_media and clip.resolved_media.id), peak_start, peak_end, draw_width)
                -- peaks == nil is legitimate: peak generation is async, peaks may
                -- not yet be available for a freshly-loaded media.
                if peaks and count > 0 then
                    -- Drift threshold scales with mipmap level — at higher
                    -- levels (1024/2048 spp), legitimate bin-alignment drift
                    -- is larger.
                    local samples_per_pixel = (peak_end - peak_start) / draw_width
                    local mip_level = peak_constants.select_level(samples_per_pixel)
                    local max_drift = peak_constants.SAMPLES_PER_LEVEL[mip_level]
                    log_waveform_range_anomalies((clip.resolved_media and clip.resolved_media.id),
                        peak_start, peak_end, actual_start, actual_end, max_drift)

                    local wave_col = waveform_color.derive(body_color)
                    local wave_height = math.max(4, clip_height - LABEL_RESERVE)
                    timeline.add_waveform(view.widget, visible_x, y, draw_width, wave_height, peaks, count, wave_col, reversed)
                    has_waveform = true
                end
            end

            -- Text label: at bottom of clip if waveform present, else original position
            local label_padding = 10
            local max_label_width = visible_width - label_padding
            if max_label_width > 35 then
                -- Append shortfall suffix when the clip's media has a
                -- partial_coverage offline_note AND this clip actually
                -- sticks out past what the candidate covers. Empty
                -- string for the common (no-note / fully-covered) case.
                --
                -- Audio clips store source_in/source_out in SAMPLES at
                -- the media's sample rate (e.g. 48000). A raw shortfall
                -- of 1524 samples displayed as "1524f" on the timeline
                -- is misleading — the 'f' reads as video frames.
                -- display_rate = sequence fps rescales the delta into
                -- timeline-frame units for both audio and video.
                -- Use the injected state_module (not a fresh require) so
                -- tests can substitute a mock. state_module.get_sequence_frame_rate
                -- returns nil in some test stubs — guarded below.
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
                    label_prefix .. (clip.label or clip.name or clip.id or "") .. label_suffix,
                    max_label_width)
                if display_label ~= "" then
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
        local outline_thickness = 2

        if is_selected or outline_only then
            local outline_col = state_module.colors.clip_selected
            timeline.add_rect(view.widget, visible_x, y, draw_width, outline_thickness, outline_col)
            timeline.add_rect(view.widget, visible_x, y + clip_height - outline_thickness, draw_width, outline_thickness, outline_col)
            timeline.add_rect(view.widget, visible_x, y, outline_thickness, clip_height, outline_col)
            timeline.add_rect(view.widget, visible_x + draw_width - outline_thickness, y, outline_thickness, clip_height, outline_col)
        elseif draw_width ~= clip_width or visible_x ~= x then
            -- Dash indicators for clipping
            local dash_height = math.min(clip_height, 12)
            local dash_col = state_module.colors.clip_selected
            if x < 0 then timeline.add_rect(view.widget, 0, y + (clip_height - dash_height)/2, outline_thickness, dash_height, dash_col) end
            if x + clip_width > width then timeline.add_rect(view.widget, width - outline_thickness, y + (clip_height - dash_height)/2, outline_thickness, dash_height, dash_col) end
        end

        if not outline_only and draw_width > 0 then
            local boundary_col = state_module.colors.clip_boundary or "#1a1a1a"
            timeline.add_rect(view.widget, visible_x + draw_width - 1, y, 1, clip_height, boundary_col)
        end
    end

    local function draw_visible_clips()
        if not state_module.get_track_clip_index then
            error("timeline_view_renderer: state_module.get_track_clip_index is required", 2)
        end

        -- All coords are integer frames
        assert(type(viewport_start) == "number" and type(viewport_end) == "number",
            "timeline_view_renderer: viewport frames are required")

        for _, track in ipairs(view.filtered_tracks) do
            local track_id = track and track.id
            local track_layout = track_id and layout_by_id and layout_by_id[track_id] or nil
            if track_id and track_layout and track_layout.y < height and (track_layout.y + track_layout.height) > 0 then
                local track_clips = state_module.get_track_clip_index(track_id)
                if track_clips and #track_clips > 0 then
                    local start_index = lower_bound_start_frames(track_clips, viewport_start)
                    if start_index > 1 then
                        start_index = start_index - 1
                    end
                    for i = start_index, #track_clips do
                        local clip = track_clips[i]
                        if not clip or type(clip.timeline_start) ~= "number" or type(clip.duration) ~= "number" then
                            goto continue_clip
                        end
                        -- Gap clips are invisible (empty space) — don't render
                        if clip.is_gap then
                            goto continue_clip
                        end
                        local clip_start = clip.timeline_start
                        if clip_start >= viewport_end then
                            break
                        end
                        local clip_end = clip_start + clip.duration
                        if clip_end <= viewport_start then
                            goto continue_clip
                        end

                        draw_clip_instance(clip, track_id, clip.timeline_start, clip.duration, false)
                        ::continue_clip::
                    end
                end
            end
        end
    end

    local function render_base_clips()
        -- Base rendering must never fall back to scanning all clips.
        -- Guard by temporarily overriding get_clips during the base pass.
        if type(state_module.get_clips) == "function" then
            local original_get_clips = state_module.get_clips
            state_module.get_clips = function()
                error("timeline_view_renderer: get_clips is forbidden for base rendering; use get_track_clip_index(track_id)", 2)
            end
            local ok, err = pcall(draw_visible_clips)
            state_module.get_clips = original_get_clips
            if not ok then
                error(err, 2)
            end
            return
        end
        draw_visible_clips()
    end

    render_base_clips()

    -- Draw Selected Gaps
    local selected_gaps = state_module.get_selected_gaps and state_module.get_selected_gaps() or {}
    if #selected_gaps > 0 then
        for _, gap in ipairs(selected_gaps) do
            -- All coords are integer frames now
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

    -- Drag Previews (clip drag)
    -- Use local drag_state if this view owns the drag, otherwise fall back to
    -- the shared state so both panes (video + audio) render previews.
    local clip_drag_state = nil
    local clip_drag_owns = false
    if view.drag_state and view.drag_state.type == "clips" then
        clip_drag_state = view.drag_state
        clip_drag_owns = true
    elseif state_module.get_active_clip_drag_state then
        clip_drag_state = state_module.get_active_clip_drag_state()
    end

    if clip_drag_state and clip_drag_state.type == "clips" then
        assert(type(clip_drag_state.delta_frames) == "number",
            "timeline_view_renderer: clip drag state missing delta_frames")
        local delta_frames = clip_drag_state.delta_frames
        local preview_target_id, preview_track_offset

        if clip_drag_owns then
            -- Owning pane: resolve cursor Y → target track → offset
            preview_target_id, preview_track_offset =
                compute_clip_drag_track_hint(view, clip_drag_state, height, state_module)
            -- Share offset so non-owning pane can use it
            clip_drag_state._preview_track_offset = preview_track_offset
        else
            -- Non-owning pane: same offset in global track-index space
            -- (matches what drag_handler applies on release)
            preview_track_offset = clip_drag_state._preview_track_offset
        end

        for _, clip in ipairs(clip_drag_state.clips) do
            if clip and clip.id then
                local render_track_id = clip.track_id
                if preview_track_offset then
                    render_track_id = get_track_with_offset(state_module, render_track_id, preview_track_offset)
                elseif preview_target_id then
                    render_track_id = preview_target_id
                end

                local start_value = clip.timeline_start + delta_frames
                draw_clip_instance(clip, render_track_id, start_value, clip.duration, true)
            end
        end
    end

    local edge_drag_state = nil
    if view.drag_state and view.drag_state.type == "edges" then
        edge_drag_state = view.drag_state
    elseif state_module.get_active_edge_drag_state then
        edge_drag_state = state_module.get_active_edge_drag_state()
    end

    local dragging_edges = edge_drag_state and edge_drag_state.type == "edges"
    local preview_clip_cache = {}
    -- All deltas are integer frames
    local edge_delta = 0
    local edges_to_render = state_module.get_selected_edges() or {}

    if dragging_edges then
        ensure_edge_preview(edge_drag_state, state_module)
        local requested_delta = assert_integer(edge_drag_state.delta_frames, "render: edge delta_frames")
        local clamped_delta = assert_integer(edge_drag_state.preview_clamped_delta_frames, "render: clamped_delta_frames")
        if clamped_delta then
            edge_delta = clamped_delta
        elseif requested_delta then
            edge_delta = requested_delta
        end
        edges_to_render = edge_drag_state.edges or edges_to_render

        local preview_data = edge_drag_state.preview_data
        if preview_data then
            render_preview_rectangles(view, preview_data, preview_clip_cache, state_module, width, height, viewport_duration)
            render_shift_block_outlines(
                view,
                preview_data,
                state_module,
                width,
                height,
                viewport_duration,
                viewport_start,
                viewport_end
            )
        end
    end

    if edges_to_render and #edges_to_render > 0 then
        if dragging_edges then
            local preview_data = assert(edge_drag_state and edge_drag_state.preview_data, "timeline_view_renderer: missing preview_data")
            local edge_preview = preview_data.edge_preview
            assert(type(edge_preview) == "table"
                    and type(edge_preview.edges) == "table"
                    and #edge_preview.edges > 0,
                "timeline_view_renderer: missing edge_preview.edges")

            for _, entry in ipairs(edge_preview.edges) do
                if type(entry) == "table" and entry.clip_id and entry.raw_edge_type and entry.normalized_edge then
                    local clip = get_preview_clip(state_module, preview_clip_cache, {clip_id = entry.clip_id})
                    if clip then
                        -- All deltas are integer frames
                        local applied_delta = tonumber(entry.applied_delta_frames) or 0
                        local start_value, duration_value, normalized_edge = edge_drag_renderer.compute_preview_geometry(
                            clip,
                            entry.normalized_edge,
                            applied_delta,
                            entry.raw_edge_type
                        )
                        if start_value and duration_value then
                            local color = (entry.is_limiter and state_module.colors.edge_selected_limit)
                                or state_module.colors.edge_selected_available
                            if entry.is_implied then
                                color = color_utils.dim_hex(color, IMPLIED_EDGE_DIM_FACTOR)
                            end
                            render_edge_handle(
                                view,
                                clip,
                                normalized_edge,
                                entry.raw_edge_type,
                                start_value,
                                duration_value,
                                color,
                                state_module,
                                width,
                                height,
                                viewport_duration
                            )
                        end
                    end
                end
            end
        else
            local previews = edge_drag_renderer.build_preview_edges(
                edges_to_render,
                edge_delta,
                {},
                state_module.colors,
                (edge_drag_state and edge_drag_state.lead_edge) or nil
            )
            for _, p in ipairs(previews) do
                local clip = get_preview_clip(state_module, preview_clip_cache, p)
                if clip then
                    local start_value, duration_value, normalized_edge = edge_drag_renderer.compute_preview_geometry(
                        clip,
                        p.edge_type,
                        p.delta,
                        p.raw_edge_type
                    )
                    if start_value and duration_value then
                        local color = p.color or state_module.colors.edge_selected_available
                        render_edge_handle(
                            view,
                            clip,
                            normalized_edge,
                            p.raw_edge_type,
                            start_value,
                            duration_value,
                            color,
                            state_module,
                            width,
                            height,
                            viewport_duration
                        )
                    end
                end
            end
        end
    end

    -- Mark In/Out highlight (on top of clips, behind playhead)
    local function draw_mark_overlay()
        if not mark_in and not mark_out then return end
        -- Implicit boundary: 0 if mark_in nil, viewport_end if mark_out nil
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
    draw_mark_overlay()

    -- Playhead
    if playhead_position >= viewport_start and playhead_position <= viewport_end then
        local px = state_module.time_to_pixel(playhead_position, width)

        -- DEBUG: Log timeline view width and playhead position
        log.detail("TIMELINE[%s]: width=%d playhead_x=%d playhead_frames=%d",
            view.debug_id or "?", width, px, playhead_position)

        timeline.add_line(view.widget, px, 0, px, height, state_module.colors.playhead, 2)
    end

    -- Snap Indicator
    if edge_drag_state and edge_drag_state.snap_info and edge_drag_state.snap_info.snapped then
        local st = edge_drag_state.snap_info.snap_point.time
        if st >= viewport_start and st <= viewport_end then
            local sx = state_module.time_to_pixel(st, width)
            timeline.add_line(view.widget, sx, 0, sx, height, 0x00FFFF, 2)
        end
    end

    timeline.update(view.widget)
    perf_log.detail("timeline_view.render: %.3fms viewport_start=%d duration=%d",
        (os.clock() - perf_t0) * 1000, viewport_start, viewport_duration)
end

return M
