-- Timeline View Renderer
-- Handles drawing logic for tracks, clips, and overlays

local M = {}
local edge_drag_renderer = require("ui.timeline.edge_drag_renderer")
local color_utils = require("ui.color_utils")
local Rational = require("core.rational")
local Command = require("command")
local command_manager = require("core.command_manager")

local function frames_to_rational(frames, fps_num, fps_den)
    return Rational.new(frames or 0, fps_num, fps_den)
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

local TEMP_GAP_PREFIX = "temp_gap_"
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
    if entry.is_gap or entry.is_temp_gap then
        return true
    end
    if type(entry.clip_id) == "string" and entry.clip_id:find("^" .. TEMP_GAP_PREFIX) then
        return true
    end
    if (entry.raw_edge_type == "gap_before" or entry.raw_edge_type == "gap_after")
        and type(entry.clip_id) == "string" and entry.clip_id:find("^" .. TEMP_GAP_PREFIX) then
        return true
    end
    return false
end

local function normalize_preview_entries(entries, fps_num, fps_den)
    local normalized = {}
    for _, entry in ipairs(coerce_clip_entries(entries) or {}) do
        local start_value = entry.new_start_value or entry.timeline_start or entry.start_value
        local duration_value = entry.new_duration or entry.duration
        if type(start_value) == "number" then
            start_value = frames_to_rational(start_value, fps_num, fps_den)
        end
        if type(duration_value) == "number" then
            duration_value = frames_to_rational(duration_value, fps_num, fps_den)
        end
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

local function build_preview_from_payload(payload, fps_num, fps_den)
    if type(payload) ~= "table" then
        return nil
    end
    local affected_entries = normalize_preview_entries(payload.affected_clips or payload.affected_clip, fps_num, fps_den) or {}
    local preview = {
        affected_clips = {},
        shifted_clips = normalize_preview_entries(payload.shifted_clips, fps_num, fps_den) or {},
        shift_blocks = payload.shift_blocks or {},
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

local function coerce_to_rational(value, fps_num, fps_den)
    if not value then return nil end
    if getmetatable(value) == Rational.metatable then
        return value
    end
    if type(value) == "number" then
        return Rational.new(value, fps_num, fps_den)
    end
    return nil
end

local function rational_equals(a, b)
    if not a or not b then
        return false
    end
    if getmetatable(a) ~= Rational.metatable or getmetatable(b) ~= Rational.metatable then
        return false
    end
    return a.frames == b.frames
        and a.fps_numerator == b.fps_numerator
        and a.fps_denominator == b.fps_denominator
end

local function parse_temp_gap_identifier(clip_id)
    if type(clip_id) ~= "string" then
        return nil
    end
    if not clip_id:find("^" .. TEMP_GAP_PREFIX) then
        return nil
    end
    local payload = clip_id:sub(#TEMP_GAP_PREFIX + 1)
    local start_str, end_str = payload:match("_(%-?%d+)_(-?%d+)$")
    if not start_str or not end_str then
        return nil
    end
    local track_len = #payload - (#start_str + #end_str + 2)
    if track_len <= 0 then
        return nil
    end
    local track_id = payload:sub(1, track_len)
    return track_id, tonumber(start_str), tonumber(end_str)
end

local function build_temp_gap_preview_clip(preview, seq_rate)
    if not preview or not preview.clip_id then
        return nil
    end
    local base_track_id, start_frames, end_frames = parse_temp_gap_identifier(preview.clip_id)
    local track_id = preview.target_track_id or base_track_id
    if not track_id or not start_frames or not end_frames then
        return nil
    end
    assert(seq_rate and seq_rate.fps_numerator and seq_rate.fps_denominator, "build_temp_gap_preview_clip: missing sequence fps metadata")
    local fps_num = seq_rate.fps_numerator
    local fps_den = seq_rate.fps_denominator
    local duration_frames = end_frames - start_frames
    if duration_frames < 0 then
        duration_frames = 0
    end
    local start_value = Rational.new(start_frames, fps_num, fps_den)
    local duration = Rational.new(duration_frames, fps_num, fps_den)
    return {
        id = preview.clip_id,
        track_id = track_id,
        timeline_start = start_value,
        duration = duration,
        source_in = Rational.new(0, fps_num, fps_den),
        source_out = duration,
        enabled = 1,
        is_gap = true
    }
end

local function get_preview_clip(state_module, preview_clip_cache, preview_entry, seq_rate)
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
    local gap_clip = build_temp_gap_preview_clip(preview_entry, seq_rate)
    if gap_clip then
        preview_clip_cache[preview_entry.clip_id] = gap_clip
        return gap_clip
    end
    return nil
end

local PREVIEW_RECT_COLOR = "#ffff00"

local function draw_preview_outline(view, clip, start_value, duration_value, state_module, width, height, viewport_duration_rational)
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

local function render_preview_rectangles(view, preview_data, preview_clip_cache, seq_rate, state_module, width, height, viewport_duration_rational)
    if not preview_data then return end
    local affected = preview_data.affected_clips
    if not affected and preview_data.affected_clip then
        affected = {preview_data.affected_clip}
    end

    for _, entry in ipairs(affected or {}) do
        if not entry.is_gap then
            local clip = get_preview_clip(state_module, preview_clip_cache, entry, seq_rate)
            if clip then
                local start_value = entry.new_start_value or clip.timeline_start
                local duration_value = entry.new_duration or clip.duration
                draw_preview_outline(view, clip, start_value, duration_value, state_module, width, height, viewport_duration_rational)
            end
        end
    end

    for _, shift in ipairs(preview_data.shifted_clips or {}) do
        local clip = get_preview_clip(state_module, preview_clip_cache, {clip_id = shift.clip_id}, seq_rate)
        if clip and shift.new_start_value then
            local existing_start = clip.timeline_start
            local new_start = shift.new_start_value
            if type(new_start) == "number" then
                local fps = state_module.get_sequence_frame_rate()
                new_start = Rational.new(new_start, fps.fps_numerator, fps.fps_denominator)
            end
            if not rational_equals(new_start, existing_start) then
                draw_preview_outline(view, clip, new_start, clip.duration, state_module, width, height, viewport_duration_rational)
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
        local clip_start = clip and clip.timeline_start and clip.timeline_start.frames
        if not clip_start then
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

local function render_shift_block_outlines(view, preview_data, seq_rate, state_module, width, height, viewport_duration_rational, viewport_start_rational, viewport_end_rational)
    if not preview_data or type(preview_data.shift_blocks) ~= "table" or #preview_data.shift_blocks == 0 then
        return
    end
    if not seq_rate or not seq_rate.fps_numerator or not seq_rate.fps_denominator then
        return
    end
    if not viewport_start_rational or not viewport_end_rational then
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

    local fps_num = seq_rate.fps_numerator
    local fps_den = seq_rate.fps_denominator

    local visible_tracks = view.filtered_tracks or {}
    for _, track in ipairs(visible_tracks) do
        local track_id = track and track.id
        if track_id then
            local block = per_track[track_id] or global_block
            if block and block.start_frames and block.delta_frames and block.delta_frames ~= 0 then
                local delta_frames = block.delta_frames
                local min_old_start = viewport_start_rational.frames - delta_frames
                local max_old_start = viewport_end_rational.frames - delta_frames
                if min_old_start < block.start_frames then
                    min_old_start = block.start_frames
                end

                local track_clips = state_module.get_track_clip_index(track_id) or {}
                if #track_clips > 0 then
                    local start_index = lower_bound_start_frames(track_clips, min_old_start)
                    if start_index > 1 then
                        start_index = start_index - 1 -- include previous clip for potential overlap
                    end

                    local delta = Rational.new(delta_frames, fps_num, fps_den)
                    for i = start_index, #track_clips do
                        local clip = track_clips[i]
                        if not clip or not clip.timeline_start or not clip.duration or not clip.timeline_start.frames then
                            goto continue_shift_clip
                        end

                        local old_start_frames = clip.timeline_start.frames
                        if old_start_frames > max_old_start then
                            break
                        end
                        if old_start_frames < block.start_frames then
                            goto continue_shift_clip
                        end
                        if clip.id and excluded[clip.id] then
                            goto continue_shift_clip
                        end

                        local new_start = clip.timeline_start + delta
                        if new_start.frames < 0 then
                            new_start = Rational.new(0, fps_num, fps_den)
                        end
                        draw_preview_outline(view, clip, new_start, clip.duration, state_module, width, height, viewport_duration_rational)

                        ::continue_shift_clip::
                    end
                end
            end
        end
    end
end

local function render_edge_handle(view, clip, normalized_edge, raw_edge_type, start_value, duration_value, color, state_module, width, height, viewport_duration_rational)
    if not clip or not clip.track_id or not start_value or not duration_value then
        return
    end
    local cy = view.get_track_y_by_id(clip.track_id, height)
    if cy < 0 then return end
    local th = view.get_track_visual_height(clip.track_id)
    if not th or th <= 0 then return end

    local sx = state_module.time_to_pixel(start_value, width)
    local cw = math.floor((duration_value / viewport_duration_rational) * width) - 1
    if cw < 0 then cw = 0 end
    local ch = th - 10
    local handle_y = cy + 5
    local ex = (normalized_edge == "in") and sx or (sx + cw)
    if raw_edge_type == "gap_before" or raw_edge_type == "gap_after" then
        ex = sx
    end
    local is_in = (normalized_edge == "in") or (raw_edge_type == "gap_after")
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
    local logger = require("core.logger")
    local debug_enabled = os.getenv("JVE_DEBUG_EDGE_PREVIEW") == "1"
    local function debug(msg)
        if debug_enabled then
            logger.debug("edge_preview", msg)
        end
    end

    local function clear_preview_state()
        if drag_state then
            drag_state.preview_data = nil
            drag_state.preview_request_token = nil
            drag_state.preview_clamped_delta = nil
            drag_state.clamped_edges = nil
        end
    end

    if not drag_state or drag_state.type ~= "edges" then
        clear_preview_state()
        debug("no drag_state or not edges; skipping preview")
        return
    end

    local edges = drag_state.edges or {}
    if #edges == 0 then
        clear_preview_state()
        debug("no edges available")
        return
    end

    local sequence_id = state_module.get_sequence_id and state_module.get_sequence_id()
    local project_id = state_module.get_project_id and state_module.get_project_id()
    if not sequence_id or sequence_id == "" or not project_id or project_id == "" then
        clear_preview_state()
        debug("missing sequence/project id")
        return
    end

    local seq_rate = state_module.get_sequence_frame_rate and state_module.get_sequence_frame_rate()
    assert(seq_rate, "ensure_edge_preview: Failed to retrieve sequence frame rate")
    assert(seq_rate.fps_numerator and seq_rate.fps_denominator, "ensure_edge_preview: missing fps metadata")
    local fps_num = seq_rate.fps_numerator
    local fps_den = seq_rate.fps_denominator

    local delta_rat = coerce_to_rational(drag_state.delta_rational, fps_num, fps_den)
    if not delta_rat then
        clear_preview_state()
        debug("missing delta (delta_rational)")
        return
    end

    local signature = build_edge_signature(edges)
    local token = string.format("%s@%d", signature, delta_rat.frames or 0)
    if drag_state.preview_request_token == token and drag_state.preview_data then
        debug("preview already computed for token " .. token)
        return
    end

    debug("requesting preview for token " .. token)

    local snapshot = drag_state.preloaded_clip_snapshot
    local active_region = drag_state.timeline_active_region
    if type(snapshot) ~= "table" or type(active_region) ~= "table" then
        clear_preview_state()
        debug("missing preloaded snapshot or active region")
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
    cmd:set_parameter("edge_infos", edge_infos)
    cmd:set_parameter("sequence_id", sequence_id)
    cmd:set_parameter("delta_frames", delta_rat.frames)
    cmd:set_parameter("dry_run", true)
    cmd:set_parameter("__preloaded_clip_snapshot", snapshot)
    cmd:set_parameter("__timeline_active_region", active_region)
    if normalized_lead then
        cmd:set_parameter("lead_edge", normalized_lead)
    end
    local executor = command_manager.get_executor("BatchRippleEdit")

    if not executor then
        clear_preview_state()
        debug("executor not available for dry run")
        return
    end

    local ok, result, payload = pcall(executor, cmd)
    if not ok then
        clear_preview_state()
        debug("dry run threw error: " .. tostring(result))
        return
    end

    if result == false then
        clear_preview_state()
        debug("dry run returned false")
        return
    end

    local preview_payload = nil
    if type(payload) == "table" then
        preview_payload = payload
    elseif type(result) == "table" then
        preview_payload = result
    end

    local preview_data = build_preview_from_payload(preview_payload, fps_num, fps_den)
    assert(preview_data, "Edge preview dry run must return preview payload")
    assert(type(preview_data.edge_preview) == "table"
            and type(preview_data.edge_preview.edges) == "table",
        "ensure_edge_preview: BatchRippleEdit dry-run payload missing edge_preview.edges")
    drag_state.preview_data = preview_data
    drag_state.clamped_edges = (drag_state.preview_data and drag_state.preview_data.clamped_edges) or {}

    drag_state.preview_request_token = token
    debug("preview ready; affected=" .. tostring(#(drag_state.preview_data.affected_clips or {})))

    local clamped_frames = cmd.get_parameter and cmd:get_parameter("clamped_delta_frames")
    if clamped_frames ~= nil then
        drag_state.preview_clamped_delta = Rational.new(clamped_frames, fps_num, fps_den)
    else
        drag_state.preview_clamped_delta = nil
    end
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
    local state_module = view.state
    local width, height = timeline.get_dimensions(view.widget)

    state_module.debug_begin_layout_capture(view.debug_id, width, height)
    timeline.clear_commands(view.widget)

    -- Viewport state
    local viewport_start_rational = state_module.get_viewport_start_time()
    local viewport_duration_rational = state_module.get_viewport_duration()
    local viewport_end_rational = viewport_start_rational + viewport_duration_rational
    local playhead_position_rational = state_module.get_playhead_position()
    local mark_in_rational = state_module.get_mark_in and state_module.get_mark_in()
    local mark_out_rational = state_module.get_mark_out and state_module.get_mark_out()

    -- Draw Mark Overlays
    if mark_in_rational and mark_out_rational and mark_out_rational > mark_in_rational then
        local fill_color = state_module.colors.mark_range_fill
        local visible_start = Rational.max(mark_in_rational, viewport_start_rational)
        local visible_end = mark_out_rational
        if viewport_end_rational < visible_end then visible_end = viewport_end_rational end
        
        if visible_end > visible_start then
            local start_x = state_module.time_to_pixel(visible_start, width)
            local end_x = state_module.time_to_pixel(visible_end, width)
            if end_x <= start_x then end_x = start_x + 1 end
            local region_width = math.max(1, end_x - start_x)
            timeline.add_rect(view.widget, start_x, 0, region_width, height, fill_color)
        end
    end

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

    local function draw_clip_instance(clip, render_track_id, clip_start_rational, clip_duration_rational, outline_only)
        if not clip or not render_track_id or not clip_start_rational or not clip_duration_rational then
            return
        end
        if clip_duration_rational.frames <= 0 then
            return
        end
        local track_layout = layout_by_id and layout_by_id[render_track_id]
        if not track_layout then
            return
        end

        local y = track_layout.y
        local track_height = track_layout.height
        local clip_end_rational = clip_start_rational + clip_duration_rational
        local x = state_module.time_to_pixel(clip_start_rational, width)
        local clip_end_px = state_module.time_to_pixel(clip_end_rational, width)
        y = y + 5
        local clip_width = math.max(1, clip_end_px - x)
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

        if visible_width <= 0 or x + clip_width < 0 or x > width or y + clip_height <= 0 or y >= height then
            return
        end

        local draw_width = math.max(1, visible_width)
        local clip_enabled = clip.enabled ~= false

        -- Resolve colors
        local is_audio = (track_layout.track_type == "AUDIO")
        local body_color, text_color
        if clip_enabled then
            body_color = is_audio and state_module.colors.clip_audio or state_module.colors.clip_video
            text_color = state_module.colors.text
        else
            body_color = is_audio and state_module.colors.clip_audio_disabled or state_module.colors.clip_video_disabled
            text_color = state_module.colors.clip_disabled_text
        end
        if not body_color then body_color = state_module.colors.clip end

        if not outline_only then
            timeline.add_rect(view.widget, visible_x, y, draw_width, clip_height, body_color)
            local label_padding = 10
            local max_label_width = visible_width - label_padding
            if max_label_width > 35 then
                local display_label = truncate_label(clip.label or clip.name or clip.id or "", max_label_width)
                if display_label ~= "" then
                    local label_baseline = y + math.min(clip_height - 10, 22)
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

        local viewport_start_frames = viewport_start_rational.frames
        local viewport_end_frames = viewport_end_rational.frames
        if viewport_start_frames == nil or viewport_end_frames == nil then
            error("timeline_view_renderer: viewport frames are required", 2)
        end

        for _, track in ipairs(view.filtered_tracks) do
            local track_id = track and track.id
            local track_layout = track_id and layout_by_id and layout_by_id[track_id] or nil
            if track_id and track_layout and track_layout.y < height and (track_layout.y + track_layout.height) > 0 then
                local track_clips = state_module.get_track_clip_index(track_id)
                if track_clips and #track_clips > 0 then
                    local start_index = lower_bound_start_frames(track_clips, viewport_start_frames)
                    if start_index > 1 then
                        start_index = start_index - 1
                    end
                    for i = start_index, #track_clips do
                        local clip = track_clips[i]
                        if not clip or not clip.timeline_start or not clip.duration then
                            goto continue_clip
                        end
                        local clip_start_frames = clip.timeline_start.frames
                        if not clip_start_frames then
                            goto continue_clip
                        end
                        if clip_start_frames >= viewport_end_frames then
                            break
                        end
                        local clip_end_frames = clip_start_frames + clip.duration.frames
                        if clip_end_frames <= viewport_start_frames then
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
        local seq_rate = state_module.get_sequence_frame_rate()
        assert(seq_rate and seq_rate.fps_numerator and seq_rate.fps_denominator, "timeline_view_renderer: missing sequence fps metadata")
        local fps_num = seq_rate.fps_numerator
        local fps_den = seq_rate.fps_denominator
        for _, gap in ipairs(selected_gaps) do
            local start_rat = gap.start_value
            local dur_rat = gap.duration
            if getmetatable(start_rat) ~= Rational.metatable then
                start_rat = Rational.hydrate and Rational.hydrate(start_rat, fps_num, fps_den) or start_rat
            end
            if getmetatable(dur_rat) ~= Rational.metatable then
                dur_rat = Rational.hydrate and Rational.hydrate(dur_rat, fps_num, fps_den) or dur_rat
            end
            local gap_y = view.get_track_y_by_id(gap.track_id, height)
            if gap_y >= 0 then
                local th = view.get_track_visual_height(gap.track_id)
                local sx = state_module.time_to_pixel(start_rat, width)
                local ex = state_module.time_to_pixel(start_rat + dur_rat, width)
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

    -- Drag Previews
    if view.drag_state and view.drag_state.type == "clips" then
        local delta_rat = view.drag_state.delta_rational
        
        local preview_hint = nil
        local current_y = view.drag_state.current_y or view.drag_state.start_y
        local target_tid = view.get_track_id_at_y(current_y, height)
        
        if target_tid then
            local anchor_clip = nil
            local aid = view.drag_state.anchor_clip_id
            if aid then for _, c in ipairs(view.drag_state.clips) do if c.id == aid then anchor_clip = c break end end end
            if not anchor_clip then anchor_clip = view.drag_state.clips[1] end
            
            if anchor_clip then
                local tracks = state_module.get_all_tracks()
                local anchor_idx, target_idx
                for i, t in ipairs(tracks) do
                    if t.id == anchor_clip.track_id then anchor_idx = i end
                    if t.id == target_tid then target_idx = i end
                end
                if anchor_idx and target_idx then
                    local offset = target_idx - anchor_idx
                    local multi = false
                    for _, c in ipairs(view.drag_state.clips) do if c.track_id ~= view.drag_state.clips[1].track_id then multi = true break end end
                    if offset ~= 0 then
                        if multi then preview_hint = {track_offset = offset} else preview_hint = target_tid end
                    else
                        if not multi then preview_hint = target_tid end
                    end
                else
                    local multi = false
                    for _, c in ipairs(view.drag_state.clips) do if c.track_id ~= view.drag_state.clips[1].track_id then multi = true break end end
                    if not multi then preview_hint = target_tid end
                end
            end
        end

        local preview_target_id = nil
        local preview_track_offset = nil
        if type(preview_hint) == "string" then
            preview_target_id = preview_hint
        elseif type(preview_hint) == "table" then
            preview_target_id = preview_hint.target_track_id
            preview_track_offset = preview_hint.track_offset
        end

        local delta_is_rational = getmetatable(delta_rat) == Rational.metatable
        for _, clip in ipairs(view.drag_state.clips) do
            if clip and clip.id then
                local render_track_id = clip.track_id
                if preview_track_offset then
                    render_track_id = get_track_with_offset(state_module, render_track_id, preview_track_offset)
                elseif preview_target_id then
                    render_track_id = preview_target_id
                end

                local start_value = clip.timeline_start
                if delta_is_rational and start_value then
                    start_value = start_value + delta_rat
                end
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
    local seq_rate = state_module.get_sequence_frame_rate()
    assert(seq_rate and seq_rate.fps_numerator and seq_rate.fps_denominator, "timeline_view_renderer: missing sequence fps metadata")
    local fps_num = seq_rate.fps_numerator
    local fps_den = seq_rate.fps_denominator
    local zero_delta = Rational.new(0, fps_num, fps_den)
    local edge_delta = zero_delta
    local edges_to_render = state_module.get_selected_edges() or {}

    if dragging_edges then
        ensure_edge_preview(edge_drag_state, state_module)
        local requested_delta = coerce_to_rational(edge_drag_state.delta_rational, fps_num, fps_den)
        local clamped_delta = coerce_to_rational(edge_drag_state.preview_clamped_delta, fps_num, fps_den)
        if clamped_delta then
            edge_delta = clamped_delta
        elseif requested_delta then
            edge_delta = requested_delta
        end
        if not edge_delta then
            edge_delta = zero_delta
        end
        edges_to_render = edge_drag_state.edges or edges_to_render

        local preview_data = edge_drag_state.preview_data
        if preview_data then
            render_preview_rectangles(view, preview_data, preview_clip_cache, seq_rate, state_module, width, height, viewport_duration_rational)
            render_shift_block_outlines(
                view,
                preview_data,
                seq_rate,
                state_module,
                width,
                height,
                viewport_duration_rational,
                viewport_start_rational,
                viewport_end_rational
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
                    local clip = get_preview_clip(state_module, preview_clip_cache, {clip_id = entry.clip_id}, seq_rate)
                    if clip then
                        local delta_frames = tonumber(entry.applied_delta_frames) or 0
                        local delta = Rational.new(delta_frames, fps_num, fps_den)
                        local start_value, duration_value, normalized_edge = edge_drag_renderer.compute_preview_geometry(
                            clip,
                            entry.normalized_edge,
                            delta,
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
                                viewport_duration_rational
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
                local clip = get_preview_clip(state_module, preview_clip_cache, p, seq_rate)
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
                            viewport_duration_rational
                        )
                    end
                end
            end
        end
    end

    -- Playhead
    if playhead_position_rational >= viewport_start_rational and playhead_position_rational <= viewport_end_rational then
        local px = state_module.time_to_pixel(playhead_position_rational, width)
        timeline.add_line(view.widget, px, 0, px, height, state_module.colors.playhead, 2)
    end

    -- Snap Indicator
    if edge_drag_state and edge_drag_state.snap_info and edge_drag_state.snap_info.snapped then
        local st = edge_drag_state.snap_info.snap_point.time
        if st >= viewport_start_rational and st <= viewport_end_rational then
            local sx = state_module.time_to_pixel(st, width)
            timeline.add_line(view.widget, sx, 0, sx, height, 0x00FFFF, 2)
        end
    end

    timeline.update(view.widget)
end

return M
