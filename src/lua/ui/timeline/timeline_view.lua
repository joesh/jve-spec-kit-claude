-- Timeline View Module
-- Renders a filtered subset of tracks from shared timeline state
-- Multiple views can exist, each showing different tracks

local M = {}
local ui_constants = require("core.ui_constants")
local focus_manager = require("ui.focus_manager")
local frame_utils = require("core.frame_utils")

-- Create a new timeline view
-- Parameters:
--   widget: ScriptableTimeline Qt widget
--   state: Reference to timeline_state module
--   track_filter_fn: function(track) -> boolean (which tracks to show)
--   options: {
--     vertical_scroll_offset = 0,
--     render_bottom_to_top = false,
--     on_drag_start = function(view_widget, x, y) -- Called when drag starts in empty space
--   }
function M.create(widget, state_module, track_filter_fn, options)
    options = options or {}

    local view = {
        widget = widget,
        state = state_module,
        track_filter = track_filter_fn,
        vertical_scroll_offset = options.vertical_scroll_offset or 0,
        render_bottom_to_top = options.render_bottom_to_top or false,
        on_drag_start = options.on_drag_start,  -- Panel callback for drag coordination
        filtered_tracks = {},  -- Cached filtered track list
        potential_drag = nil,  -- Stores info about a click that might become a drag
        drag_state = nil,
        panel_drag_move = nil,
        panel_drag_end = nil,
        pending_gap_click = nil,
        debug_id = options.debug_id or tostring(widget),
    }

    local DRAG_THRESHOLD = ui_constants.TIMELINE.DRAG_THRESHOLD
    local function get_track_visual_height(track_id)
        local height = state_module.get_track_height and state_module.get_track_height(track_id) or state_module.dimensions.default_track_height
        return math.max(0, height or 0)
    end

    -- Filter tracks and cache result
    local function update_filtered_tracks()
        view.filtered_tracks = {}
        for _, track in ipairs(state_module.get_all_tracks()) do
            if track_filter_fn(track) then
                table.insert(view.filtered_tracks, track)
            end
        end
    end

    -- Calculate and set widget height based on track heights
    local function update_widget_height()
        local total_height = 0
        for _, track in ipairs(view.filtered_tracks) do
            local track_height = get_track_visual_height(track.id)
            total_height = total_height + track_height
        end

        -- Set the widget's minimum height to accommodate all tracks
        qt_constants.PROPERTIES.SET_MIN_HEIGHT(widget, total_height)
    end

    -- Get Y position for a track within this view
    -- Calculates cumulative Y position based on actual track heights
    local function get_track_y(track_index, widget_height)
        if view.render_bottom_to_top then
            -- For video tracks: render from bottom up (track 0 at bottom)
            -- Calculate Y by subtracting cumulative heights from widget height
            local y = widget_height
            for i = 0, track_index do
                if view.filtered_tracks[i + 1] then
                    local track_height = get_track_visual_height(view.filtered_tracks[i + 1].id)
                    y = y - track_height
                end
            end
            return y - view.vertical_scroll_offset
        else
            -- For audio tracks: render from top down (original behavior)
            local y = 0
            for i = 0, track_index - 1 do
                if view.filtered_tracks[i + 1] then
                    local track_height = get_track_visual_height(view.filtered_tracks[i + 1].id)
                    y = y + track_height
                end
            end
            return y - view.vertical_scroll_offset
        end
    end

    -- Get Y position by track ID
    local function get_track_y_by_id(track_id, widget_height)
        for i, track in ipairs(view.filtered_tracks) do
            if track.id == track_id then
                return get_track_y(i - 1, widget_height)  -- 0-based index
            end
        end
        return -1  -- Track not in this view
    end

    -- Get track ID at a given Y coordinate
    local function get_track_id_at_y(y, widget_height)
        for i, track in ipairs(view.filtered_tracks) do
            local track_y = get_track_y(i - 1, widget_height)
            local track_height = get_track_visual_height(track.id)
            if y >= track_y and y < track_y + track_height then
                return track.id
            end
        end
        return nil  -- No track at this Y position
    end

    local function find_gap_at_time(track_id, time_ms)
        if not track_id or not time_ms then
            return nil
        end

        local clips_on_track = {}
        for _, clip in ipairs(state_module.get_clips() or {}) do
            if clip.track_id == track_id then
                table.insert(clips_on_track, clip)
            end
        end

        table.sort(clips_on_track, function(a, b)
            if a.start_time == b.start_time then
                return a.id < b.id
            end
            return a.start_time < b.start_time
        end)

        local previous_end = 0
        local previous_clip_id = nil
        for _, clip in ipairs(clips_on_track) do
            local gap_start = previous_end
            local gap_end = clip.start_time
            local gap_duration = gap_end - gap_start

            if gap_duration > 0 and time_ms >= gap_start and time_ms < gap_end then
                return {
                    track_id = track_id,
                    start_time = gap_start,
                    duration = gap_duration,
                    prev_clip_id = previous_clip_id,
                    next_clip_id = clip.id,
                }
            end

            previous_end = clip.start_time + clip.duration
            previous_clip_id = clip.id
        end

        return nil
    end

    local function normalize_edge_type(edge_type)
        if edge_type == "gap_after" then
            return "out"
        elseif edge_type == "gap_before" then
            return "in"
        end
        return edge_type
    end

    local function find_best_roll_pair(entries, x, width)
        if not entries or #entries < 2 then
            return nil, nil, math.huge
        end

        local best_selection = nil
        local best_pair = nil
        local best_score = math.huge

        for i = 1, #entries do
            local first = entries[i]
            local clip_a = first.clip
            local norm_a = normalize_edge_type(first.edge)
            if clip_a and norm_a and (norm_a == "in" or norm_a == "out") then
                for j = i + 1, #entries do
                    local second = entries[j]
                    local clip_b = second.clip
                    local norm_b = normalize_edge_type(second.edge)
                    if clip_b and norm_b and clip_a.track_id == clip_b.track_id and clip_a.id ~= clip_b.id then
                        local left_clip, right_clip = nil, nil
                        local left_distance, right_distance = nil, nil

                        if norm_a == "out" and norm_b == "in" then
                            left_clip = clip_a
                            right_clip = clip_b
                            left_distance = first.distance
                            right_distance = second.distance
                        elseif norm_a == "in" and norm_b == "out" then
                            left_clip = clip_b
                            right_clip = clip_a
                            left_distance = second.distance
                            right_distance = first.distance
                        end

                        if left_clip and right_clip then
                            if left_clip.start_time > right_clip.start_time then
                                left_clip, right_clip = right_clip, left_clip
                                left_distance, right_distance = right_distance, left_distance
                            end

                            if state_module.detect_roll_between_clips(left_clip, right_clip, x, width) then
                                local score = math.max(left_distance or 0, right_distance or 0)
                                if score < best_score then
                                    best_score = score
                                    best_selection = {
                                        {clip_id = left_clip.id, edge_type = "out", trim_type = "roll"},
                                        {clip_id = right_clip.id, edge_type = "in", trim_type = "roll"}
                                    }
                                    best_pair = {
                                        left_clip = left_clip,
                                        right_clip = right_clip,
                                        left_edge_type = "out",
                                        right_edge_type = "in"
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end

        return best_selection, best_pair, best_score
    end

    -- Convert local track index to global track index
    local function local_to_global_track_index(local_index)
        if local_index >= 0 and local_index < #view.filtered_tracks then
            local track = view.filtered_tracks[local_index + 1]  -- Lua 1-based
            return state_module.get_track_index(track.id)
        end
        return -1
    end

    -- Convert global track index to local track index (returns -1 if not in this view)
    local function global_to_local_track_index(global_index)
        local all_tracks = state_module.get_all_tracks()
        if global_index >= 0 and global_index < #all_tracks then
            local track_id = all_tracks[global_index + 1].id
            for i, track in ipairs(view.filtered_tracks) do
                if track.id == track_id then
                    return i - 1  -- 0-based local index
                end
            end
        end
        return -1  -- Not in this view
    end

    -- Render this view
    local function render()
        if not view.widget then
            return
        end

        -- Get widget dimensions
        local width, height = timeline.get_dimensions(view.widget)

        state_module.debug_begin_layout_capture(view.debug_id, width, height)

        -- Clear previous drawing commands
        timeline.clear_commands(view.widget)

        -- Get viewport state
        local viewport_start = state_module.get_viewport_start_time()
        local viewport_duration = state_module.get_viewport_duration()
        local viewport_end = viewport_start + viewport_duration
        local playhead_time = state_module.get_playhead_time()
        local mark_in = state_module.get_mark_in and state_module.get_mark_in()
        local mark_out = state_module.get_mark_out and state_module.get_mark_out()

        local function draw_mark_overlays()
            if (not mark_in) and (not mark_out) then
                return
            end

            local fill_color = state_module.colors.mark_range_fill
            if not fill_color then
                error("timeline_state.colors.mark_range_fill is nil; expected translucent color for mark range overlay")
            end

            if mark_in and mark_out and mark_out > mark_in then
                local visible_start = math.max(mark_in, viewport_start)
                local visible_end = math.min(mark_out, viewport_end)
                if visible_end > visible_start then
                    local start_x = state_module.time_to_pixel(visible_start, width)
                    local end_x = state_module.time_to_pixel(visible_end, width)
                    if end_x <= start_x then
                        end_x = start_x + 1
                    end
                    local region_width = end_x - start_x
                    if region_width <= 0 then
                        region_width = 1
                    end
                    timeline.add_rect(view.widget, start_x, 0, region_width, height, fill_color)
                end
            end
        end

        -- Draw tracks
        -- print(string.format("Rendering %d tracks (widget height: %d, viewport height: %d)", #view.filtered_tracks, height, height))
        for i, track in ipairs(view.filtered_tracks) do
            local y = get_track_y(i - 1, height)
        local track_height = get_track_visual_height(track.id)
            state_module.debug_record_track_layout(view.debug_id, track.id, y, track_height)
            -- print(string.format("  Track %d (%s): y=%d height=%d", i, track.name, y, track_height))

            -- Only draw if visible
            if y + track_height > 0 and y < height then
                -- Alternate track colors
                local track_color = (i % 2 == 0) and state_module.colors.track_even or state_module.colors.track_odd

                -- Track background
                timeline.add_rect(view.widget, 0, y, width, track_height, track_color)

                -- Track separator line
                timeline.add_line(view.widget, 0, y, width, y, state_module.colors.grid_line, 1)
                -- print(string.format("    -> Drew track at y=%d", y))
            -- else
                -- print(string.format("    -> SKIPPED (not visible)"))
            end
        end

        -- Helper function to draw clips with optional offset and outline-only mode
        -- Parameters:
        --   time_offset_ms: time offset to apply to all clips
        --   outline_only: if true, only draw outlines
        --   clip_filter: optional function(clip) to filter which clips to draw
        --   target_track_id: optional track ID to override clip's track (for drag preview)
        local function get_track_with_offset(track_id, offset)
    if not offset or offset == 0 then
        return track_id
    end

    local tracks = state_module.get_all_tracks()
    local original_index = nil
    for i, track in ipairs(tracks) do
        if track.id == track_id then
            original_index = i
            break
        end
    end

    if not original_index then
        return track_id
    end

    local new_index = original_index + offset
    if new_index < 1 or new_index > #tracks then
        return track_id
    end

    local original_track = tracks[original_index]
    local target_track = tracks[new_index]
    if target_track and original_track and target_track.track_type == original_track.track_type then
        return target_track.id
    end

    return track_id
end

    local function truncate_label(label, max_width)
        if not label or label == "" or max_width <= 0 then
            return ""
        end

        local approx_char_width = 7
        local max_chars = math.floor(max_width / approx_char_width)
        if max_chars <= 0 then
            return ""
        end

        if #label <= max_chars then
            return label
        end

        if max_chars <= 3 then
            return label:sub(1, max_chars)
        end

        return label:sub(1, max_chars - 3) .. "..."
    end

    local function draw_clips(time_offset_ms, outline_only, clip_filter, preview_hint)
        local clips = state_module.get_clips()
        local selected_clips = state_module.get_selected_clips()

        local preview_target_id = nil
        local preview_track_offset = nil
        if type(preview_hint) == 'string' then
            preview_target_id = preview_hint
        elseif type(preview_hint) == 'table' then
            preview_target_id = preview_hint.target_track_id
            preview_track_offset = preview_hint.track_offset
        end

        for _, clip in ipairs(clips) do
            if clip_filter and not clip_filter(clip) then
                goto continue
            end

            local render_track_id = clip.track_id
            if preview_track_offset then
                render_track_id = get_track_with_offset(render_track_id, preview_track_offset)
            elseif preview_target_id then
                render_track_id = preview_target_id
            end

            local y = get_track_y_by_id(render_track_id, height)

                if y >= 0 then  -- Clip is on a track in this view
                    local track_height = get_track_visual_height(render_track_id or clip.track_id)
                    local clip_start = clip.start_time + time_offset_ms
                    local clip_end = clip_start + clip.duration
                    local x = state_module.time_to_pixel(clip_start, width)
                    local clip_end_px = state_module.time_to_pixel(clip_end, width)
                    y = y + 5  -- Add padding from track top
                    local clip_width = clip_end_px - x
                    if clip_width < 1 then
                        clip_width = 1
                    end
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

                    -- Only draw if visible
                    if visible_width > 0 and
                       x + clip_width >= 0 and x <= width and
                       y + clip_height > 0 and y < height then

                        if not outline_only and time_offset_ms == 0 and target_track_id == nil then
                            state_module.debug_record_clip_layout(view.debug_id, clip.id, clip.track_id, x, y, clip_width, clip_height)
                        end

                        -- Check if selected
                        local is_selected = false
                        for _, selected in ipairs(selected_clips) do
                            if selected.id == clip.id then
                                is_selected = true
                                break
                            end
                        end

                        local outline_thickness = 2

                        local clip_enabled = clip.enabled ~= false
                        local track_info = state_module.get_track_by_id(render_track_id or clip.track_id)
                        local is_audio_track = track_info and track_info.track_type == "AUDIO"
                        local body_color
                        if clip_enabled then
                            if is_audio_track then
                                body_color = state_module.colors.clip_audio or state_module.colors.clip
                            else
                                body_color = state_module.colors.clip_video or state_module.colors.clip
                            end
                        else
                            body_color = state_module.colors.clip_disabled
                        end
                        local text_color = clip_enabled and state_module.colors.text or state_module.colors.clip_disabled_text

                        if not outline_only then
                            -- Draw filled clip
                            timeline.add_rect(view.widget, visible_x, y, visible_width, clip_height, body_color)

                            -- Clip name (if there's enough space)
                            local label_padding = 10
                            local max_label_width = visible_width - label_padding
                            if max_label_width > 40 then
                                local clip_label = clip.label or clip.name or clip.id or ""
                                local display_label = truncate_label(clip_label, max_label_width)
                                if display_label ~= "" then
                                    local label_baseline = y + math.min(clip_height - 10, 22)
                                    timeline.add_text(view.widget, visible_x + 5, label_baseline, display_label, text_color)
                                end
                            end
                        end

                        -- Draw outline if selected or if outline_only mode
                        if is_selected or outline_only then
                            local outline_width = visible_width
                            local outline_x = visible_x
                            local trim = 1
                            local top_width = outline_width > trim and (outline_width - trim) or outline_width
                            timeline.add_rect(view.widget, outline_x, y, top_width, outline_thickness, state_module.colors.clip_selected)
                            timeline.add_rect(view.widget, outline_x, y + clip_height - outline_thickness, top_width, outline_thickness, state_module.colors.clip_selected)
                            timeline.add_rect(view.widget, outline_x, y, outline_thickness, clip_height, state_module.colors.clip_selected)
                            local right_x = outline_x + outline_width - outline_thickness - trim
                            if right_x < outline_x then
                                right_x = outline_x
                            end
                            timeline.add_rect(view.widget, right_x, y, outline_thickness, clip_height, state_module.colors.clip_selected)
                        elseif visible_width ~= clip_width or visible_x ~= x then
                            local dash_height = math.min(clip_height, 12)
                            if x < 0 then
                                timeline.add_rect(view.widget, 0, y + (clip_height - dash_height) / 2, outline_thickness, dash_height, state_module.colors.clip_selected)
                            end
                            if x + clip_width > width then
                                timeline.add_rect(view.widget, width - outline_thickness, y + (clip_height - dash_height) / 2, outline_thickness, dash_height, state_module.colors.clip_selected)
                            end
                        end

                        if not outline_only and visible_width > 0 then
                            local boundary_x = visible_x + visible_width - 1
                            local boundary_color = state_module.colors.clip_boundary or state_module.colors.background or "#1a1a1a"
                            timeline.add_rect(view.widget, boundary_x, y, 1, clip_height, boundary_color)
                        end
                    end
                end
                ::continue::
            end
        end

        -- Draw clips at their normal positions
        draw_clips(0, false, nil)

        -- Highlight selected gaps (empty regions) if any
        local selected_gaps = state_module.get_selected_gaps and state_module.get_selected_gaps() or {}
        if #selected_gaps > 0 then
            for _, gap in ipairs(selected_gaps) do
                local gap_track_y = get_track_y_by_id(gap.track_id, height)
                if gap_track_y >= 0 then
                    local track_height = get_track_visual_height(gap.track_id)
                    local gap_start_x = state_module.time_to_pixel(gap.start_time, width)
                    local gap_end_x = state_module.time_to_pixel(gap.start_time + gap.duration, width)
                    local gap_width = gap_end_x - gap_start_x
                    if gap_width > 0 then
                        local gap_top = gap_track_y + 5
                        local gap_height = track_height - 10
                        local outline = state_module.colors.gap_selected_outline or state_module.colors.clip_selected
                        local outline_thickness = state_module.dimensions and state_module.dimensions.clip_outline_thickness or 4
                        local gap_outline_thickness =  math.max(1, math.floor(outline_thickness / 2))
                        if gap_height > outline_thickness * 2 and gap_width > outline_thickness * 2 then
                            timeline.add_rect(view.widget, gap_start_x, gap_top, gap_width, gap_outline_thickness, outline)
                            timeline.add_rect(view.widget, gap_start_x, gap_top + gap_height - gap_outline_thickness, gap_width, gap_outline_thickness, outline)
                            timeline.add_rect(view.widget, gap_start_x, gap_top, gap_outline_thickness, gap_height, outline)
                            timeline.add_rect(view.widget, gap_start_x + gap_width - gap_outline_thickness, gap_top, gap_outline_thickness, gap_height, outline)
                        else
                            -- Fallback for very small gaps: draw a single outline block so selection stays visible.
                            timeline.add_rect(view.widget, gap_start_x, gap_top, gap_width, math.max(gap_outline_thickness, gap_height), outline)
                        end
                    end
                end
            end
        end

        -- If dragging clips, draw outline preview at new positions
        if view.drag_state and view.drag_state.type == "clips" then
            local drag_offset_ms = view.drag_state.delta_ms or 0
            local current_y = view.drag_state.current_y or view.drag_state.start_y
            local target_track_id = get_track_id_at_y(current_y, height)

            -- Check if selection spans multiple tracks
            local first_track_id = view.drag_state.clips[1].track_id
            local multi_track_selection = false
            for _, clip in ipairs(view.drag_state.clips) do
                if clip.track_id ~= first_track_id then
                    multi_track_selection = true
                    break
                end
            end

            local anchor_clip = nil
            if view.drag_state.anchor_clip_id then
                for _, clip in ipairs(view.drag_state.clips) do
                    if clip.id == view.drag_state.anchor_clip_id then
                        anchor_clip = clip
                        break
                    end
                end
            end
            if not anchor_clip then
                anchor_clip = view.drag_state.clips[1]
            end

            local preview_hint = nil
            if target_track_id then
                if anchor_clip then
                    local all_tracks = state_module.get_all_tracks()
                    local anchor_index = nil
                    local target_index = nil
                    for i, track in ipairs(all_tracks) do
                        if track.id == anchor_clip.track_id then
                            anchor_index = i
                        end
                        if track.id == target_track_id then
                            target_index = i
                        end
                    end

                    if anchor_index and target_index then
                        local track_offset = target_index - anchor_index
                        if track_offset ~= 0 then
                            if multi_track_selection then
                                preview_hint = {track_offset = track_offset}
                            else
                                preview_hint = target_track_id
                            end
                        else
                            if not multi_track_selection then
                                preview_hint = target_track_id
                            end
                        end
                    else
                        if not multi_track_selection then
                            preview_hint = target_track_id
                        end
                    end
                else
                    if not multi_track_selection then
                        preview_hint = target_track_id
                    end
                end
            end

            local dragging_clip_ids = {}
            for _, clip in ipairs(view.drag_state.clips) do
                dragging_clip_ids[clip.id] = true
            end

            -- Draw outline preview only for dragged clips at their new positions/track
            -- For multi-track selections, don't change tracks (pass nil)
            draw_clips(drag_offset_ms, true, function(clip)
                return dragging_clip_ids[clip.id]
            end, preview_hint)
        end

        -- If dragging edges, draw outline preview of affected clips at their new trimmed dimensions
        if view.drag_state and view.drag_state.type == "edges" then
            local edge_drag_offset_ms = view.drag_state.delta_ms or 0

            -- Use dry-run to get what would happen if we released now
            local Command = require("command")
            local command_manager = require("core.command_manager")

            local preview_data = nil
            local success = false

            -- Single edge: use RippleEdit
            if #view.drag_state.edges == 1 then
                local sequence_id = state_module.get_sequence_id and state_module.get_sequence_id()
                if not sequence_id or sequence_id == "" then
                    print("ERROR: Ripple preview aborted - missing sequence id")
                    return
                end
                local project_id = state_module.get_project_id and state_module.get_project_id()
                if not project_id or project_id == "" then
                    print("ERROR: Ripple preview aborted - missing project id")
                    return
                end
                local edge = view.drag_state.edges[1]
                local ripple_cmd = Command.create("RippleEdit", project_id)
                ripple_cmd:set_parameter("edge_info", {
                    clip_id = edge.clip_id,
                    edge_type = edge.edge_type,
                    track_id = edge.track_id,
                    trim_type = edge.trim_type
                })
                ripple_cmd:set_parameter("delta_ms", edge_drag_offset_ms)
                ripple_cmd:set_parameter("sequence_id", sequence_id)
                ripple_cmd:set_parameter("dry_run", true)

                local executor = command_manager.get_executor("RippleEdit")
                if executor then
                    success, preview_data = executor(ripple_cmd)
                end
            -- Multiple edges: use BatchRippleEdit
            elseif #view.drag_state.edges > 1 then
                local sequence_id = state_module.get_sequence_id and state_module.get_sequence_id()
                if not sequence_id or sequence_id == "" then
                    print("ERROR: Batch ripple preview aborted - missing sequence id")
                    return
                end
                local project_id = state_module.get_project_id and state_module.get_project_id()
                if not project_id or project_id == "" then
                    print("ERROR: Batch ripple preview aborted - missing project id")
                    return
                end
                local edge_infos = {}
                for _, edge in ipairs(view.drag_state.edges) do
                    table.insert(edge_infos, {
                        clip_id = edge.clip_id,
                        edge_type = edge.edge_type,
                        track_id = edge.track_id,
                        trim_type = edge.trim_type
                    })
                end

                local batch_cmd = Command.create("BatchRippleEdit", project_id)
                batch_cmd:set_parameter("edge_infos", edge_infos)
                batch_cmd:set_parameter("delta_ms", edge_drag_offset_ms)
                batch_cmd:set_parameter("sequence_id", sequence_id)
                batch_cmd:set_parameter("dry_run", true)

                local executor = command_manager.get_executor("BatchRippleEdit")
                if executor then
                    success, preview_data = executor(batch_cmd)
                end
            end

            -- Draw preview based on dry-run results
            if success and preview_data then
                local all_clips = state_module.get_clips()

                -- Draw affected clips (trimmed edges)
                local affected_clips = preview_data.affected_clip and {preview_data.affected_clip} or preview_data.affected_clips or {}
                for _, affected_clip in ipairs(affected_clips) do
                    for _, clip in ipairs(all_clips) do
                        if clip.id == affected_clip.clip_id then
                            local y = get_track_y_by_id(clip.track_id, height)
                            if y >= 0 then
                                local track_height = get_track_visual_height(clip.track_id)
                                local x = state_module.time_to_pixel(affected_clip.new_start_time, width)
                                y = y + 5
                                local clip_width = math.floor((affected_clip.new_duration / viewport_duration) * width) - 1
                                local clip_height = track_height - 10

                                local outline_thickness = 2
                                local preview_color = "#ffff00"

                                timeline.add_rect(view.widget, x, y, clip_width, outline_thickness, preview_color)
                                timeline.add_rect(view.widget, x, y + clip_height - outline_thickness, clip_width, outline_thickness, preview_color)
                                timeline.add_rect(view.widget, x, y, outline_thickness, clip_height, preview_color)
                                timeline.add_rect(view.widget, x + clip_width - outline_thickness, y, outline_thickness, clip_height, preview_color)
                            end
                            break
                        end
                    end
                end

                -- Draw shifted clips (downstream ripple)
                for _, shift_info in ipairs(preview_data.shifted_clips or {}) do
                    for _, clip in ipairs(all_clips) do
                        if clip.id == shift_info.clip_id then
                            local y = get_track_y_by_id(clip.track_id, height)
                            if y >= 0 then
                                local track_height = get_track_visual_height(clip.track_id)
                                local x = state_module.time_to_pixel(shift_info.new_start_time, width)
                                y = y + 5
                                local clip_width = math.floor((clip.duration / viewport_duration) * width) - 1
                                local clip_height = track_height - 10

                                local outline_thickness = 2
                                local preview_color = "#ffff00"

                                timeline.add_rect(view.widget, x, y, clip_width, outline_thickness, preview_color)
                                timeline.add_rect(view.widget, x, y + clip_height - outline_thickness, clip_width, outline_thickness, preview_color)
                                timeline.add_rect(view.widget, x, y, outline_thickness, clip_height, preview_color)
                                timeline.add_rect(view.widget, x + clip_width - outline_thickness, y, outline_thickness, clip_height, preview_color)
                            end
                            break
                        end
                    end
                end
            end
        end

        -- OLD edge preview code - keeping for reference, can be removed later
        if false and view.drag_state and view.drag_state.type == "edges" then
            local edge_drag_offset_ms = view.drag_state.delta_ms or 0
            local affected_clip_ids = {}

            -- Collect all clips affected by edge drag
            for _, edge in ipairs(view.drag_state.edges) do
                affected_clip_ids[edge.clip_id] = true
            end

            -- Draw outline preview showing clips at their new trimmed/extended dimensions
            local function draw_edge_affected_clip(clip)
                if not affected_clip_ids[clip.id] then
                    return false  -- Not affected by this drag
                end

                -- Find which edge(s) are being dragged for this clip
                local in_edge_offset = 0
                local out_edge_offset = 0

                for _, edge in ipairs(view.drag_state.edges) do
                    if edge.clip_id == clip.id then
                        if edge.edge_type == "in" or edge.edge_type == "gap_before" then
                            in_edge_offset = edge_drag_offset_ms
                        elseif edge.edge_type == "out" or edge.edge_type == "gap_after" then
                            out_edge_offset = edge_drag_offset_ms
                        end
                    end
                end

                -- Calculate new dimensions
                local new_start = clip.start_time + in_edge_offset
                local new_duration = clip.duration - in_edge_offset + out_edge_offset
                local y = get_track_y_by_id(clip.track_id, height)

                if y >= 0 then
                    local track_height = get_track_visual_height(clip.track_id)
                    local x = state_module.time_to_pixel(new_start, width)
                    y = y + 5
                    local clip_width = math.floor((new_duration / viewport_duration) * width) - 1
                    local clip_height = track_height - 10

                    -- Draw bright preview outline
                    local outline_thickness = 4  -- Thicker for better visibility
                    local preview_color = "#ffff00"  -- Bright yellow

                    -- Top
                    timeline.add_rect(view.widget, x, y, clip_width, outline_thickness, preview_color)
                    -- Bottom
                    timeline.add_rect(view.widget, x, y + clip_height - outline_thickness, clip_width, outline_thickness, preview_color)
                    -- Left
                    timeline.add_rect(view.widget, x, y, outline_thickness, clip_height, preview_color)
                    -- Right
                    timeline.add_rect(view.widget, x + clip_width - outline_thickness, y, outline_thickness, clip_height, preview_color)
                end

                return false  -- Already drew it, don't let draw_clips handle it
            end

            -- Manually draw affected clips with new dimensions
            local clips = state_module.get_clips()
            for _, clip in ipairs(clips) do
                draw_edge_affected_clip(clip)
            end
        end

        -- Draw selected edge highlights as bracket indicators (for trimming operations)
        local selected_edges = state_module.get_selected_edges()

        -- Calculate drag offset if dragging edges
        local edge_drag_offset_ms = 0
        local dragging_edge_ids = {}
        if view.drag_state and view.drag_state.type == "edges" then
            edge_drag_offset_ms = view.drag_state.delta_ms or 0
            for _, edge in ipairs(view.drag_state.edges) do
                local key = edge.clip_id .. ":" .. edge.edge_type
                dragging_edge_ids[key] = true
            end
        end

        -- Get clips for edge bracket rendering
        local all_clips = state_module.get_clips()

        -- Capture trim constraints for edge rendering so we can show limit state
        local database_module = require('core.database')
        local constraints_module = require('core.timeline_constraints')
        local Clip = require('models.clip')
        local sequence_id = state_module.get_sequence_id()
        local all_for_constraints = database_module.load_clips(sequence_id)
        local db_conn = database_module.get_connection()

        local trim_constraints = {}
        local function ensure_constraint(edge_info)
            if not edge_info or not edge_info.clip_id then return end
            local key = edge_info.clip_id .. ':' .. edge_info.edge_type
            if trim_constraints[key] ~= nil then return end
            local clip = Clip.load(edge_info.clip_id, db_conn)
            if not clip then return end
            local normalized_edge = edge_info.edge_type
            if normalized_edge == 'gap_after' then
                normalized_edge = 'in'
            elseif normalized_edge == 'gap_before' then
                normalized_edge = 'out'
            end
            trim_constraints[key] = constraints_module.calculate_trim_range(clip, normalized_edge, all_for_constraints, false, true)
        end

        if view.drag_state and view.drag_state.type == 'edges' then
            for _, drag_edge in ipairs(view.drag_state.edges) do
                ensure_constraint(drag_edge)
            end
        end
        for _, selected in ipairs(selected_edges) do
            ensure_constraint(selected)
        end

        for _, edge in ipairs(selected_edges) do
            -- Find the clip for this edge
            local edge_clip = nil
            for _, clip in ipairs(all_clips) do
                if clip.id == edge.clip_id then
                    edge_clip = clip
                    break
                end
            end

            if edge_clip then
                local clip_y = get_track_y_by_id(edge_clip.track_id, height)

                if clip_y >= 0 then  -- Clip is on a track in this view
                    local track_height = get_track_visual_height(edge_clip.track_id)

                    -- Apply drag offset to clip boundaries if this edge is being dragged
                    local edge_key = edge.clip_id .. ":" .. edge.edge_type
                    local is_dragging = dragging_edge_ids[edge_key]

                    local clip_start = edge_clip.start_time
                    local clip_duration = edge_clip.duration
                    local at_limit = false

                    if is_dragging then
                        -- Adjust clip boundaries based on which edge is being dragged
                        if edge.edge_type == "in" or edge.edge_type == "gap_before" then
                            clip_start = clip_start + edge_drag_offset_ms
                            clip_duration = clip_duration - edge_drag_offset_ms
                        elseif edge.edge_type == "out" or edge.edge_type == "gap_after" then
                            clip_duration = clip_duration + edge_drag_offset_ms
                        end
                    end

                    local clip_x = state_module.time_to_pixel(clip_start, width)
                    local clip_width = math.floor((clip_duration / viewport_duration) * width) - 1  -- Match rendering gap
                    local clip_height = track_height - 10

                    -- Determine edge position and bracket orientation
                    local edge_x = 0
                    local has_available_media = false
                    local bracket_width = 8  -- Width of bracket indicator
                    local bracket_thickness = 2
                    local bracket_type = "in"  -- "in" for [, "out" for ]
                    local is_gap_edge = (edge.edge_type == "gap_after" or edge.edge_type == "gap_before")

                    if edge.edge_type == "in" then
                        -- Clip's in-point: [ facing right
                        edge_x = clip_x
                        bracket_type = "in"
                        local constraints = trim_constraints[edge_key]
                        if constraints then
                            has_available_media = constraints.min_delta < 0
                            if constraints.min_delta >= 0 then
                                at_limit = true
                            end
                        else
                            has_available_media = edge_clip.source_in > 0
                        end
                    elseif edge.edge_type == "out" then
                        -- Clip's out-point: ] facing left
                        edge_x = clip_x + clip_width
                        bracket_type = "out"
                        local constraints = trim_constraints[edge_key]
                        if constraints then
                            has_available_media = constraints.max_delta > 0
                            if constraints.max_delta <= 0 then
                                at_limit = true
                            end
                        else
                            has_available_media = true
                        end
                    elseif edge.edge_type == "gap_before" then
                        -- Gap's edge before clip: ] facing right (closing towards clip)
                        edge_x = clip_x
                        bracket_type = "out"
                        local constraints = trim_constraints[edge_key]
                        if constraints then
                            has_available_media = constraints.max_delta > 0
                            if constraints.max_delta <= 0 then
                                at_limit = true
                            end
                        else
                            has_available_media = true  -- Gap always has "space" available
                        end
                    elseif edge.edge_type == "gap_after" then
                        -- Gap's edge after clip: [ facing left (opening into gap)
                        edge_x = clip_x + clip_width
                        bracket_type = "in"
                        local constraints = trim_constraints[edge_key]
                        if constraints then
                            has_available_media = constraints.min_delta < 0
                            if constraints.min_delta >= 0 then
                                at_limit = true
                            end
                        else
                            has_available_media = true  -- Gap always has "space" available
                        end
                    end

                    -- Choose color based on media availability (white if dragging for visibility)
                    local edge_color
                    if is_gap_edge then
                        edge_color = is_dragging and 0xFFFFFFFF or state_module.colors.edge_selected_available
                    else
                        if is_dragging then
                            edge_color = at_limit and state_module.colors.edge_selected_limit or 0xFFFFFFFF
                        else
                            edge_color = (not has_available_media or at_limit)
                                and state_module.colors.edge_selected_limit
                                or state_module.colors.edge_selected_available
                        end
                    end

                    -- Draw bracket indicator: [ for in point, ] for out point
                    local bracket_y = clip_y + 5

                    if bracket_type == "in" then
                        -- Draw [ bracket (opening bracket)
                        -- Vertical line
                        timeline.add_rect(view.widget, edge_x, bracket_y,
                                        bracket_thickness, clip_height, edge_color)
                        -- Top horizontal
                        timeline.add_rect(view.widget, edge_x, bracket_y,
                                        bracket_width, bracket_thickness, edge_color)
                        -- Bottom horizontal
                        timeline.add_rect(view.widget, edge_x, bracket_y + clip_height - bracket_thickness,
                                        bracket_width, bracket_thickness, edge_color)
                    else  -- "out"
                        -- Draw ] bracket (closing bracket)
                        -- Vertical line
                        timeline.add_rect(view.widget, edge_x - bracket_thickness, bracket_y,
                                        bracket_thickness, clip_height, edge_color)
                        -- Top horizontal
                        timeline.add_rect(view.widget, edge_x - bracket_width, bracket_y,
                                        bracket_width, bracket_thickness, edge_color)
                        -- Bottom horizontal
                        timeline.add_rect(view.widget, edge_x - bracket_width, bracket_y + clip_height - bracket_thickness,
                                        bracket_width, bracket_thickness, edge_color)
                    end
                end
            end
        end

        draw_mark_overlays()

        -- Draw playhead line (vertical line only, triangle is in ruler)
        if playhead_time >= viewport_start and playhead_time <= viewport_start + viewport_duration then
            local playhead_x = state_module.time_to_pixel(playhead_time, width)
            timeline.add_line(view.widget, playhead_x, 0, playhead_x, height, state_module.colors.playhead, 2)
        end

        -- Draw snap indicator when snapping is active during drag
        if view.drag_state and view.drag_state.snap_info and view.drag_state.snap_info.snapped then
            local snap_point = view.drag_state.snap_info.snap_point
            local snap_time = snap_point.time

            -- Only draw if snap point is visible in viewport
            if snap_time >= viewport_start and snap_time <= viewport_start + viewport_duration then
                local snap_x = state_module.time_to_pixel(snap_time, width)

                -- Draw bright cyan vertical line to indicate snap point
                local snap_color = 0x00FFFF  -- Cyan: highly visible against dark timeline
                timeline.add_line(view.widget, snap_x, 0, snap_x, height, snap_color, 2)

                -- Optional: Draw label showing what we're snapping to
                -- (Commented out for now to avoid clutter, but can be enabled if desired)
                -- local label = snap_point.type == "playhead" and "Playhead" or "Clip Edge"
                -- timeline.add_text(view.widget, snap_x + 5, 15, label, snap_color)
            end
        end

        -- NOTE: Selection box drawing removed - now handled by overlay widget in timeline_panel

        -- Trigger Qt repaint
        timeline.update(view.widget)
    end

    -- Mouse event handler
    local function on_mouse_event(event_type, x, y, button, modifiers)
        if event_type ~= "move" then
            print(string.format("DEBUG: Mouse event type='%s' button=%s drag_state=%s widget=%s",
                event_type, tostring(button), tostring(view.drag_state and view.drag_state.type or "nil"), tostring(view.widget)))
        end

        local width, height = timeline.get_dimensions(view.widget)

        if event_type == "press" then
            view.pending_gap_click = nil
            if focus_manager and focus_manager.set_focused_panel then
                pcall(focus_manager.set_focused_panel, "timeline")
            end
            if qt_set_focus then
                pcall(qt_set_focus, view.widget)
            end
            -- Check if clicking on playhead
            local playhead_time = state_module.get_playhead_time()
            local playhead_x = state_module.time_to_pixel(playhead_time, width)
            if math.abs(x - playhead_x) < 5 then
                state_module.set_dragging_playhead(true)
                return
            end

            -- Check if clicking on a clip edge (for trimming)
            -- Four cases:
            --   1. Click near left edge ONLY (not near another clip's right) → select [ (in-point)
            --   2. Click near right edge ONLY (not near another clip's left) → select ] (out-point)
            --   3. Click between two adjacent clips → select ][ (edit point: right clip's out + left clip's in)
            --   4. Click in middle of clip → no edge selection (future: select clip body for dragging)

            local EDGE_ZONE = ui_constants.TIMELINE.EDGE_ZONE_PX
            local ROLL_ZONE = ui_constants.TIMELINE.ROLL_ZONE_PX or (EDGE_ZONE * 2)
            local EDGE_DETECTION_THRESHOLD = EDGE_ZONE
            local EDIT_POINT_ZONE = ui_constants.TIMELINE.EDIT_POINT_ZONE
            local clips_at_position = {}

            -- First pass: find all clips at this Y position and their edge proximity
            for _, clip in ipairs(state_module.get_clips()) do
                local clip_y = get_track_y_by_id(clip.track_id, height)
                if clip_y >= 0 then
                    local track_height = get_track_visual_height(clip.track_id)
                    local clip_height = track_height - 10

                    -- Check if Y is within track bounds (full track, not just clip height)
                    if y >= clip_y and y <= clip_y + track_height then
                        local clip_x = state_module.time_to_pixel(clip.start_time, width)
                        local clip_width = math.floor((clip.duration / state_module.get_viewport_duration()) * width) - 1
                        local clip_end_x = clip_x + clip_width

                        -- Left edge: distinguish between clip's in-point and gap's out-point
                        local dist_from_left = math.abs(x - clip_x)
                        if dist_from_left <= EDGE_DETECTION_THRESHOLD then
                            local inside_clip = x >= clip_x
                            table.insert(clips_at_position, {
                                clip = clip,
                                edge = inside_clip and "in" or "gap_before",  -- in=] from clip side, gap_before=[ from gap side
                                distance = dist_from_left
                            })
                        end

                        -- Right edge: distinguish between clip's out-point and gap's in-point
                        local dist_from_right = math.abs(x - clip_end_x)
                        if dist_from_right <= EDGE_DETECTION_THRESHOLD then
                            local inside_clip = x <= clip_end_x
                            table.insert(clips_at_position, {
                                clip = clip,
                                edge = inside_clip and "out" or "gap_after",  -- out=] from clip side, gap_after=[ from gap side
                                distance = dist_from_right
                            })
                        end
                    end
                end
            end

            -- DEBUG: Print what was detected
            print(string.format("DEBUG: Click at x=%d, y=%d, detected %d edges:", x, y, #clips_at_position))
            for i, edge_info in ipairs(clips_at_position) do
                print(string.format("  %d: clip=%s, edge=%s, distance=%d, from_gap=%s",
                    i, edge_info.clip.id:sub(1,8), edge_info.edge, edge_info.distance, tostring(edge_info.from_gap or false)))
            end

            -- Second pass: determine what to select or drag based on detected edges
            if #clips_at_position > 0 then
                -- Check selection state
                local selected_edges = state_module.get_selected_edges()
                local closest_edge = clips_at_position[1]
                for _, edge_info in ipairs(clips_at_position) do
                    if edge_info.distance < closest_edge.distance then
                        closest_edge = edge_info
                    end
                end

                local clicked_is_selected = false
                for _, selected in ipairs(selected_edges) do
                    if selected.clip_id == closest_edge.clip.id and selected.edge_type == closest_edge.edge then
                        clicked_is_selected = true
                        break
                    end
                end

                local use_direct_selection = not (modifiers and modifiers.command) or #selected_edges == 0

                if not use_direct_selection and clicked_is_selected then
                    -- Clicking on selected edge
                    view.pending_gap_click = nil
                    if modifiers and modifiers.command then
                        -- Cmd+click on selected edge - toggle it (deselect)
                        for _, edge_info in ipairs(clips_at_position) do
                            state_module.toggle_edge_selection(edge_info.clip.id, edge_info.edge, "ripple")
                        end
                        render()
                        return
                    else
                        -- Regular click on selected edge - prepare for potential drag
                        -- Find the specific edge that was clicked (closest one)
                        local dragged_edge = clips_at_position[1]
                        for _, edge_info in ipairs(clips_at_position) do
                            if edge_info.distance < dragged_edge.distance then
                                dragged_edge = edge_info
                            end
                        end

                        -- Reorder edges to put dragged edge first
                        local reordered_edges = {}
                        -- Add dragged edge first
                        for _, selected in ipairs(selected_edges) do
                            if selected.clip_id == dragged_edge.clip.id and selected.edge_type == dragged_edge.edge then
                                table.insert(reordered_edges, selected)
                                break
                            end
                        end
                        -- Add remaining edges
                        for _, selected in ipairs(selected_edges) do
                            if selected.clip_id ~= dragged_edge.clip.id or selected.edge_type ~= dragged_edge.edge then
                                table.insert(reordered_edges, selected)
                            end
                        end

                        view.potential_drag = {
                            type = "edges",
                            start_x = x,
                            start_y = y,
                            start_time = state_module.pixel_to_time(x, width),
                            edges = reordered_edges,  -- Dragged edge is first
                            modifiers = modifiers
                        }
                        print(string.format("Clicked %d selected edge(s), dragging: %s %s",
                            #reordered_edges, dragged_edge.clip.id:sub(1,8), dragged_edge.edge))
                        return
                    end
                else
                    -- Clicking unselected edge OR we want fresh selection regardless
                    view.pending_gap_click = nil
                    if not (modifiers and modifiers.command) then
                        -- Without Cmd key, clear previous edge selection
                        state_module.clear_edge_selection()

                        local function normalize_edge_type(name)
                            if name == "gap_after" then
                                return "in"
                            elseif name == "gap_before" then
                                return "out"
                            end
                            return name
                        end

                        local best_roll_selection, best_roll_pair = find_best_roll_pair(clips_at_position, x, width)

                        if best_roll_selection and best_roll_pair then
                            local roll_zone_px = ui_constants.TIMELINE.ROLL_ZONE_PX or (EDGE_ZONE * 2)
                            if roll_zone_px < EDGE_ZONE then
                                roll_zone_px = EDGE_ZONE
                            end
                            local half_roll_zone = roll_zone_px / 2
                            local edit_time = best_roll_pair.left_clip.start_time + best_roll_pair.left_clip.duration
                            local edit_x = state_module.time_to_pixel(edit_time, width)

                            if edit_x and math.abs(x - edit_x) <= half_roll_zone then
                                state_module.set_edge_selection(best_roll_selection)
                            else
                                local target_edge_clip_id
                                local target_edge_type
                                if not edit_x or x < edit_x then
                                    target_edge_clip_id = best_roll_pair.left_clip.id
                                    target_edge_type = best_roll_pair.left_edge_type
                                else
                                    target_edge_clip_id = best_roll_pair.right_clip.id
                                    target_edge_type = best_roll_pair.right_edge_type
                                end
                                state_module.toggle_edge_selection(target_edge_clip_id, target_edge_type, "ripple")
                            end
                        elseif #clips_at_position > 0 then
                            -- Select only the CLOSEST edge (ripple trim)
                            local closest = clips_at_position[1]
                            for _, edge_info in ipairs(clips_at_position) do
                                if edge_info.distance < closest.distance then
                                    closest = edge_info
                                end
                            end
                            state_module.toggle_edge_selection(closest.clip.id, closest.edge, "ripple")
                        end
                    else
                        -- With Cmd key, add all edges to selection (for multi-edge operations)
                        for _, edge_info in ipairs(clips_at_position) do
                            state_module.toggle_edge_selection(edge_info.clip.id, edge_info.edge, edge_info.trim_type or "ripple")
                        end
                    end

                    -- Note: toggle_edge_selection() already clears clip selection (mutual exclusion)

                    -- Prepare for potential drag (after selection is updated)
                    view.potential_drag = {
                        type = "edges",
                        start_x = x,
                        start_y = y,
                        start_time = state_module.pixel_to_time(x, width),
                        edges = state_module.get_selected_edges(),
                        modifiers = modifiers
                    }
                    print(string.format("Selected %d edge(s)", #view.potential_drag.edges))
                    render()
                    return
                end
            end

            -- No edge clicked - check if clicking on selected clip body for dragging
            local selected_clips = state_module.get_selected_clips()
            print(string.format("DEBUG: Checking for clip click, %d clips currently selected", #selected_clips))
            local clicked_clip = nil
            for _, clip in ipairs(state_module.get_clips()) do
                local clip_y = get_track_y_by_id(clip.track_id, height)
                if clip_y >= 0 then
                    local track_height = get_track_visual_height(clip.track_id)
                    local clip_x = state_module.time_to_pixel(clip.start_time, width)
                    local clip_width = math.floor((clip.duration / state_module.get_viewport_duration()) * width) - 1

                    if x >= clip_x and x <= clip_x + clip_width and
                       y >= clip_y and y <= clip_y + track_height then
                        clicked_clip = clip
                        print(string.format("DEBUG: Found clicked clip: %s (selected=%s, cmd=%s)",
                            clip.id:sub(1,8),
                            tostring(false),  -- Will check selection below
                            tostring(modifiers and modifiers.command)))
                        break
                    end
                end
            end

            if clicked_clip then
                -- Check if this clip is in the selection
                view.pending_gap_click = nil
                local is_selected = false
                for _, sel in ipairs(selected_clips) do
                    if sel.id == clicked_clip.id then
                        is_selected = true
                        break
                    end
                end

                print(string.format("DEBUG: Clicked clip is_selected=%s", tostring(is_selected)))

                if is_selected then
                    -- Clicking on selected clip
                    if modifiers and modifiers.command then
                        -- Cmd+click on selected clip - deselect it
                        print("DEBUG: Cmd+clicking selected clip - removing from selection")
                        local new_selection = {}
                        for _, clip in ipairs(selected_clips) do
                            if clip.id ~= clicked_clip.id then
                                table.insert(new_selection, clip)
                            end
                        end
                        state_module.set_selection(new_selection)
                        render()
                        return
                    else
                        -- Regular click on selected clip - prepare for potential drag
                        view.potential_drag = {
                            type = "clips",
                            start_x = x,
                            start_y = y,
                            start_time = state_module.pixel_to_time(x, width),
                            clips = selected_clips,
                            modifiers = modifiers,
                            anchor_clip_id = clicked_clip.id
                        }
                        print(string.format("Clicked %d selected clip(s)", #selected_clips))
                        return
                    end
                else
                    -- Clicking on unselected clip - select it
                    if not (modifiers and modifiers.command) then
                        -- Without Cmd, replace selection with this clip
                        print("DEBUG: Replacing selection with clicked clip")
                        state_module.clear_edge_selection()
                        state_module.set_selection({clicked_clip})
                    else
                        -- With Cmd, add to selection
                        print("DEBUG: Cmd+clicking unselected clip - adding to selection")
                        local new_selection = {}
                        for _, clip in ipairs(selected_clips) do
                            table.insert(new_selection, clip)
                        end
                        table.insert(new_selection, clicked_clip)
                        state_module.set_selection(new_selection)
                    end

                    -- Prepare for potential drag (after selection is updated)
                    local new_selection = state_module.get_selected_clips()
                    print(string.format("DEBUG: After selection update, selection has %d clip(s)", #new_selection))
                    view.potential_drag = {
                        type = "clips",
                        start_x = x,
                        start_y = y,
                        start_time = state_module.pixel_to_time(x, width),
                        clips = new_selection,
                        modifiers = modifiers,
                        anchor_clip_id = clicked_clip.id
                    }
                    print(string.format("Selected %d clip(s)", #view.potential_drag.clips))
                    render()
                    return
                end
            else
                -- No clip under cursor, check for gap selection
                local track_id = get_track_id_at_y(y, height)
                if track_id then
                    local click_time = state_module.pixel_to_time(x, width)
                    local gap = find_gap_at_time(track_id, click_time)
                    if gap and gap.duration > 0 then
                        view.pending_gap_click = {
                            initial_gap = gap,
                            command_modifier = modifiers and modifiers.command or false,
                            press_track_id = track_id,
                        }
                    else
                        view.pending_gap_click = nil
                    end
                else
                    view.pending_gap_click = nil
                end
            end

            -- Not clicking on clip or edge - starting drag selection
            -- Clear selections unless Cmd is held (for multi-select)
            if not (modifiers and modifiers.command) then
                state_module.clear_edge_selection()
                if state_module.clear_gap_selection then
                    state_module.clear_gap_selection()
                end
                state_module.set_selection({})
            end

            -- Notify panel that drag is starting (panel coordinates drag selection)
            if view.on_drag_start then
                -- Panel returns callbacks for us to use during drag
                -- Pass modifiers so panel knows about Cmd+drag for multi-select
                view.panel_drag_move, view.panel_drag_end = view.on_drag_start(view.widget, x, y, modifiers)
            end

        elseif event_type == "move" then
            -- Check if we should convert potential_drag to actual drag_state
            if view.potential_drag then
                local dx = math.abs(x - view.potential_drag.start_x)
                local dy = math.abs(y - view.potential_drag.start_y)

                if dx >= DRAG_THRESHOLD or dy >= DRAG_THRESHOLD then
                    -- Movement exceeded threshold - start actual drag
                    view.pending_gap_click = nil
                    view.drag_state = {
                        type = view.potential_drag.type,
                        start_x = view.potential_drag.start_x,
                        start_y = view.potential_drag.start_y,
                        start_time = view.potential_drag.start_time,
                        clips = view.potential_drag.clips,
                        edges = view.potential_drag.edges,
                        anchor_clip_id = view.potential_drag.anchor_clip_id,
                        current_x = x,
                        current_y = y,
                        current_time = state_module.pixel_to_time(x, width)
                    }
                    if (not view.drag_state.anchor_clip_id) and view.drag_state.clips and #view.drag_state.clips > 0 then
                        view.drag_state.anchor_clip_id = view.drag_state.clips[1].id
                    end
                    view.drag_state.delta_ms = math.floor(view.drag_state.current_time - view.drag_state.start_time)

                    -- For edge drags, augment each edge with its original_time for snapping calculations
                    if view.drag_state.type == "edges" and view.drag_state.edges then
                        for _, edge in ipairs(view.drag_state.edges) do
                            -- Find the clip this edge belongs to
                            local clips = state_module.get_clips()
                            for _, clip in ipairs(clips) do
                                if clip.id == edge.clip_id then
                                    -- Calculate original time based on edge type
                                    -- No special cases - "in" is always left edge, "out" is always right edge
                                    if edge.edge_type == "in" then
                                        edge.original_time = clip.start_time
                                    elseif edge.edge_type == "out" then
                                        edge.original_time = clip.start_time + clip.duration
                                    elseif edge.edge_type == "gap_before" then
                                        -- Gap before clip shares the clip's start time
                                        edge.original_time = clip.start_time
                                    elseif edge.edge_type == "gap_after" then
                                        -- Gap after clip starts where the clip ends
                                        edge.original_time = clip.start_time + clip.duration
                                    else
                                        error("Unknown edge type: " .. tostring(edge.edge_type))
                                    end
                                    break
                                end
                            end
                        end
                    end

                    local item_count = view.drag_state.clips and #view.drag_state.clips or #view.drag_state.edges
                    local item_type = view.drag_state.type == "clips" and "clip(s)" or "edge(s)"
                    print(string.format("Start dragging %d %s (threshold exceeded)", item_count, item_type))

                    view.potential_drag = nil
                    render()
                end
            elseif view.drag_state then
                view.pending_gap_click = nil
                -- Dragging clips or edges - show visual feedback
                local current_time = state_module.pixel_to_time(x, width)

                -- Apply magnetic snapping if enabled
                local keyboard_shortcuts = require("core.keyboard_shortcuts")
                local magnetic_snapping = require("core.magnetic_snapping")

                local snap_enabled = keyboard_shortcuts.is_snapping_enabled()

                if snap_enabled then
                    -- Calculate snap tolerance based on current zoom level
                    local tolerance_ms = magnetic_snapping.calculate_tolerance(
                        state_module.get_viewport_duration(),
                        width
                    )

                    -- Build exclusion lists (don't snap to edges we're dragging)
                    local excluded_clip_ids = {}
                    local excluded_edge_specs = {}

                    if view.drag_state.type == "clips" then
                        -- For clip drags: snap CLIP EDGES, not mouse position
                        -- Calculate where clip edges will be after this drag
                        local delta_ms = current_time - view.drag_state.start_time
                        local best_snap = nil
                        local best_snap_distance = math.huge

                        for _, clip in ipairs(view.drag_state.clips) do
                            -- Check both edges of this clip
                            local new_in_point = clip.start_time + delta_ms
                            local new_out_point = new_in_point + clip.duration

                            -- Try snapping in-point (exclude only THIS edge from snapping to itself)
                            local exclude_in = {{clip_id = clip.id, edge_type = "in"}}
                            local snapped_in, snap_info_in = magnetic_snapping.apply_snap(
                                state_module, new_in_point, true, {}, exclude_in, tolerance_ms
                            )
                            if snap_info_in.snapped and snap_info_in.distance < best_snap_distance then
                                best_snap = {time = snapped_in, edge = "in", original = new_in_point}
                                best_snap_distance = snap_info_in.distance
                            end

                            -- Try snapping out-point (exclude only THIS edge from snapping to itself)
                            local exclude_out = {{clip_id = clip.id, edge_type = "out"}}
                            local snapped_out, snap_info_out = magnetic_snapping.apply_snap(
                                state_module, new_out_point, true, {}, exclude_out, tolerance_ms
                            )
                            if snap_info_out.snapped and snap_info_out.distance < best_snap_distance then
                                best_snap = {time = snapped_out, edge = "out", original = new_out_point}
                                best_snap_distance = snap_info_out.distance
                            end
                        end

                        -- If we found a snap, adjust current_time to make that edge snap
                        if best_snap then
                            local snap_delta = best_snap.time - best_snap.original
                            current_time = current_time + snap_delta
                        end

                    elseif view.drag_state.type == "edges" then
                        -- For edge drags: check if edges would snap at their new positions
                        -- Calculate where edges will be AFTER this drag, then check for snaps
                        local delta_ms = current_time - view.drag_state.start_time
                        local best_snap = nil
                        local best_snap_distance = math.huge

                        for _, edge in ipairs(view.drag_state.edges) do
                            -- Calculate new edge position (all edge types use original_time + delta)
                            local edge_time = edge.original_time + delta_ms

                            -- Try snapping this edge's new position (exclude only THIS edge from snapping to itself)
                            local exclude_this_edge = {{clip_id = edge.clip_id, edge_type = edge.edge_type}}
                            local snapped_edge, snap_info = magnetic_snapping.apply_snap(
                                state_module,
                                edge_time,
                                true,
                                {},
                                exclude_this_edge,
                                tolerance_ms
                            )

                            if snap_info.snapped and snap_info.distance < best_snap_distance then
                                best_snap = {time = snapped_edge, original = edge_time}
                                best_snap_distance = snap_info.distance
                            end
                        end

                        -- If we found a snap, adjust current_time to make that edge snap
                        if best_snap then
                            local snap_delta = best_snap.time - best_snap.original
                            current_time = current_time + snap_delta
                        end
                    end
                end

                view.drag_state.current_y = y

                if modifiers and modifiers.shift then
                    view.drag_state.current_x = view.drag_state.start_x
                    view.drag_state.current_time = view.drag_state.start_time
                    view.drag_state.delta_ms = 0
                    view.drag_state.shift_constrained = true
                else
                    view.drag_state.current_x = x
                    view.drag_state.current_time = current_time
                    view.drag_state.delta_ms = math.floor(current_time - view.drag_state.start_time)
                    view.drag_state.shift_constrained = false
                end

                if modifiers and modifiers.alt then
                    view.drag_state.alt_copy = true
                else
                    view.drag_state.alt_copy = false
                end
                render()  -- Show drag preview
            elseif state_module.is_dragging_playhead() then
                local time = state_module.pixel_to_time(x, width)
                state_module.set_playhead_time(time)
            elseif view.panel_drag_move then
                -- Forward move events to panel during drag selection
                view.pending_gap_click = nil
                view.panel_drag_move(view.widget, x, y)
            else
                -- Update cursor based on what's under the mouse
                local EDGE_ZONE = ui_constants.TIMELINE.EDGE_ZONE_PX
                local ROLL_ZONE = ui_constants.TIMELINE.ROLL_ZONE_PX or (EDGE_ZONE * 2)
                local EDGE_DETECTION_THRESHOLD = EDGE_ZONE
                local EDIT_POINT_ZONE = ui_constants.TIMELINE.EDIT_POINT_ZONE
                local cursor_type = "arrow"  -- Default
                local clips_at_position = {}

                -- Find all edges near mouse position (same logic as click detection)
                for _, clip in ipairs(state_module.get_clips()) do
                    local clip_y = get_track_y_by_id(clip.track_id, height)
                    if clip_y >= 0 then
                        local track_height = get_track_visual_height(clip.track_id)
                        local clip_height = track_height - 10

                        if y >= clip_y + 5 and y <= clip_y + 5 + clip_height then
                            local clip_x = state_module.time_to_pixel(clip.start_time, width)
                            local clip_width = math.floor((clip.duration / state_module.get_viewport_duration()) * width) - 1

                            local dist_from_left = math.abs(x - clip_x)
                            local dist_from_right = math.abs(x - (clip_x + clip_width))

                            if dist_from_left <= EDGE_DETECTION_THRESHOLD then
                                table.insert(clips_at_position, {
                                    clip = clip,
                                    edge = "in",
                                    distance = dist_from_left
                                })
                            end
                            if dist_from_right <= EDGE_DETECTION_THRESHOLD then
                                table.insert(clips_at_position, {
                                    clip = clip,
                                    edge = "out",
                                    distance = dist_from_right
                                })
                            end
                        end
                    end
                end

                -- Determine cursor based on edge proximity
                if #clips_at_position >= 2 then
                    local best_selection, best_pair, best_score = find_best_roll_pair(clips_at_position, x, width)
                    if best_selection and best_pair then
                        local roll_zone_px = ui_constants.TIMELINE.ROLL_ZONE_PX or (EDGE_ZONE * 2)
                        if roll_zone_px <= 0 then
                            roll_zone_px = EDGE_ZONE * 2
                        end
                        local half_roll_zone = roll_zone_px / 2
                        if half_roll_zone < 1 then
                            half_roll_zone = 1
                        end
                        half_roll_zone = math.min(half_roll_zone, EDGE_ZONE / 2)
                        local edit_time = best_pair.left_clip.start_time + best_pair.left_clip.duration
                        local edit_x = state_module.time_to_pixel(edit_time, width)
                        if edit_x and math.abs(x - edit_x) <= half_roll_zone then
                            cursor_type = "split_h"
                        elseif not edit_x or x < edit_x then
                            cursor_type = "size_horz"
                        else
                            cursor_type = "size_all"
                        end
                    else
                        -- Fallback to individual edge detection
                        local closest = clips_at_position[1]
                        for i = 2, #clips_at_position do
                            if clips_at_position[i].distance < closest.distance then
                                closest = clips_at_position[i]
                            end
                        end
                        cursor_type = "size_horz"
                    end
                elseif #clips_at_position == 1 then
                    -- Single edge - show resize cursor for [ or ]
                    cursor_type = "size_horz"
                end

                qt_set_widget_cursor(view.widget, cursor_type)
            end

        elseif event_type == "release" then
            print(string.format("DEBUG: Mouse release - drag_state=%s, potential_drag=%s",
                tostring(view.drag_state and view.drag_state.type or "nil"),
                tostring(view.potential_drag and view.potential_drag.type or "nil")))

            -- Clear potential_drag if we released without exceeding threshold
            if view.potential_drag then
                print("Click released without drag (threshold not exceeded)")
                view.potential_drag = nil
            end

            if view.drag_state then
                -- Capture drag state data before clearing it
                local drag_type = view.drag_state.type
                local drag_clips = view.drag_state.clips
                local drag_edges = view.drag_state.edges
                local delta_ms = view.drag_state.delta_ms or 0
                local current_y = view.drag_state.current_y or view.drag_state.start_y
                local width, height = timeline.get_dimensions(view.widget)
                local target_track_id = get_track_id_at_y(current_y, height)

                print(string.format("DEBUG: Drag release - delta_ms=%d, current_y=%d, target_track=%s",
                    delta_ms, current_y, tostring(target_track_id)))

                local alt_copy = (modifiers and modifiers.alt) or (view.drag_state and view.drag_state.alt_copy)
                local shift_constrained = view.drag_state and view.drag_state.shift_constrained
                local anchor_clip_id = view.drag_state and view.drag_state.anchor_clip_id
                view.drag_state = nil
                view.potential_drag = nil

                local keyboard_shortcuts = require("core.keyboard_shortcuts")
                keyboard_shortcuts.reset_drag_snapping()

                local Command = require("command")
                local command_manager = require("core.command_manager")

                if drag_type == "clips" then
                    -- Reload clips to get current track assignments (may have changed since drag started)
                    local all_clips = state_module.get_clips()
                    local current_clips = {}
                    for _, drag_clip in ipairs(drag_clips) do
                        for _, clip in ipairs(all_clips) do
                            if clip.id == drag_clip.id then
                                table.insert(current_clips, clip)
                                break
                            end
                        end
                    end

                    -- Calculate track offset for maintaining relative positions
                    local reference_clip = current_clips[1]
                    if anchor_clip_id then
                        for _, clip in ipairs(current_clips) do
                            if clip.id == anchor_clip_id then
                                reference_clip = clip
                                break
                            end
                        end
                    end

                    if not reference_clip then
                        print("WARNING: Drag release: no reference clip found")
                        return
                    end

                    local reference_original_track = reference_clip.track_id

                    -- Calculate offset: target - original
                    local all_tracks = state_module.get_all_tracks()
                    local reference_track_index = nil
                    local target_track_index = nil

                    for i, track in ipairs(all_tracks) do
                        if track.id == reference_original_track then
                            reference_track_index = i
                        end
                        if track.id == target_track_id then
                            target_track_index = i
                        end
                    end

                    local track_offset = 0
                    if reference_track_index and target_track_index then
                        track_offset = target_track_index - reference_track_index
                    end

                    -- Move each clip by the same track offset
                    local clips_to_move = {}
                    if track_offset ~= 0 then
                        for _, clip in ipairs(current_clips) do
                            local clip_track_index = nil
                            for i, track in ipairs(all_tracks) do
                                if track.id == clip.track_id then
                                    clip_track_index = i
                                    break
                                end
                            end

                            if clip_track_index then
                                local new_track_index = clip_track_index + track_offset
                                if new_track_index >= 1 and new_track_index <= #all_tracks then
                                    local new_track = all_tracks[new_track_index]
                                    -- Only move if same track type (video->video, audio->audio)
                                    local old_track = all_tracks[clip_track_index]
                                    if new_track.track_type == old_track.track_type then
                                        table.insert(clips_to_move, {
                                            clip = clip,
                                            target_track_id = new_track.id
                                        })
                                    end
                                end
                            end
                        end
                    end

                    -- Determine active sequence; drag should never proceed without it
                    local active_sequence_id = state_module.get_sequence_id and state_module.get_sequence_id()
                    if not active_sequence_id or active_sequence_id == "" then
                        print("ERROR: timeline drag aborted - no active sequence id")
                        return
                    end

                    local active_project_id = state_module.get_project_id and state_module.get_project_id()
                    if not active_project_id or active_project_id == "" then
                        print("ERROR: timeline drag aborted - missing project id")
                        return
                    end

                    -- Build command list for BatchCommand (single undo for entire drag)
                    local command_specs = {}
                    local clip_targets = {}
                    for _, clip in ipairs(current_clips) do
                        clip_targets[clip.id] = clip.track_id
                    end
                    for _, move_info in ipairs(clips_to_move) do
                        clip_targets[move_info.clip.id] = move_info.target_track_id
                    end

                    if alt_copy then
                        for _, clip in ipairs(current_clips) do
                            local target_track_id = clip_targets[clip.id] or clip.track_id
                            local overwrite_time = clip.start_time + delta_ms
                            local source_in = clip.source_in or 0
                            local source_out = clip.source_out or (source_in + (clip.duration or 0))
                            local has_media = clip.media_id and clip.media_id ~= ""
                            local has_master = clip.parent_clip_id and clip.parent_clip_id ~= ""

                            if not has_media and not has_master then
                                print(string.format("WARNING: Option-drag copy skipped clip %s (no media or master)", clip.id or "unknown"))
                            else
                                table.insert(command_specs, {
                                    command_type = "Overwrite",
                                    parameters = {
                                        media_id = clip.media_id,
                                        track_id = target_track_id,
                                        overwrite_time = overwrite_time,
                                        duration = clip.duration,
                                        source_in = source_in,
                                        source_out = source_out,
                                        master_clip_id = clip.parent_clip_id,
                                        clip_name = clip.name,
                                        project_id = clip.project_id or active_project_id,
                                        sequence_id = active_sequence_id,
                                        advance_playhead = false,
                                    }
                                })
                            end
                        end

                        table.sort(command_specs, function(a, b)
                            local ta = a.parameters.overwrite_time or 0
                            local tb = b.parameters.overwrite_time or 0
                            if ta == tb then
                                return (a.parameters.track_id or "") < (b.parameters.track_id or "")
                            end
                            return ta < tb
                        end)
                    else
                        -- Add track changes
                        if #clips_to_move > 0 then
                            for _, move_info in ipairs(clips_to_move) do
                                local move_params = {
                                    clip_id = move_info.clip.id,
                                    target_track_id = move_info.target_track_id
                                }
                                if delta_ms ~= 0 then
                                    move_params.skip_occlusion = true
                                    move_params.pending_new_start_time = move_info.clip.start_time + delta_ms
                                    move_params.pending_duration = move_info.clip.duration
                                end
                                move_params.project_id = move_info.clip.project_id or active_project_id
                                move_params.sequence_id = active_sequence_id
                                table.insert(command_specs, {
                                    command_type = "MoveClipToTrack",
                                    parameters = move_params
                                })
                            end
                        end

                        -- Add time nudge (if moved horizontally)
                        if delta_ms ~= 0 then
                            local clip_ids = {}
                            for _, clip in ipairs(drag_clips) do
                                table.insert(clip_ids, clip.id)
                            end

                            table.insert(command_specs, {
                                command_type = "Nudge",
                                parameters = {
                                    sequence_id = active_sequence_id,
                                    project_id = active_project_id,
                                    nudge_amount_ms = delta_ms,
                                    selected_clip_ids = clip_ids
                                }
                            })
                        end
                    end

                    -- Normalize command parameters before execution
                    for _, spec in ipairs(command_specs) do
                        spec.parameters = spec.parameters or {}
                        if not spec.parameters.project_id or spec.parameters.project_id == "" then
                            spec.parameters.project_id = active_project_id
                        end
                        if not spec.parameters.sequence_id or spec.parameters.sequence_id == "" then
                            spec.parameters.sequence_id = active_sequence_id
                        end
                    end

                    -- Execute all as single batch command (single undo entry)
                    if #command_specs > 0 then
                        if #command_specs == 1 then
                            -- Only one operation - execute directly (no batch overhead)
                            local spec = command_specs[1]
                            local cmd = Command.create(spec.command_type, active_project_id)
                            for key, value in pairs(spec.parameters) do
                                cmd:set_parameter(key, value)
                            end
                            local result = command_manager.execute(cmd)
                            if not result.success then
                                print(string.format("ERROR: %s failed: %s", spec.command_type, result.error_message or "unknown"))
                            end
                        else
                            -- Multiple operations - use BatchCommand for single undo
                            local json = require("dkjson")
                            local commands_json = json.encode(command_specs)
                            local batch_cmd = Command.create("BatchCommand", active_project_id)
                            batch_cmd:set_parameter("commands_json", commands_json)
                            batch_cmd:set_parameter("sequence_id", active_sequence_id)

                            local result = command_manager.execute(batch_cmd)
                            if not result.success then
                                print(string.format("ERROR: Batch drag failed: %s", result.error_message or "unknown"))
                            end
                        end
                    end

                    -- Summary message
                    local frame_rate = state_module.get_sequence_frame_rate and state_module.get_sequence_frame_rate() or frame_utils.default_frame_rate
                    local function format_delta()
                        if delta_ms == 0 then
                            return nil
                        end
                        local ok, formatted = pcall(frame_utils.format_timecode, math.abs(delta_ms), frame_rate)
                        if ok and formatted then
                            return formatted
                        end
                        return string.format("%dms", math.abs(delta_ms))
                    end

                    if alt_copy then
                        local copied_count = 0
                        for _, spec in ipairs(command_specs) do
                            if spec.command_type == "Insert" then
                                copied_count = copied_count + 1
                            end
                        end
                        if copied_count > 0 then
                            local delta_text = format_delta()
                            if delta_text then
                                local direction = delta_ms < 0 and "left" or "right"
                                print(string.format("✅ Copied %d clip(s) %s by %s", copied_count, direction, delta_text))
                            else
                                print(string.format("✅ Copied %d clip(s)", copied_count))
                            end
                        end
                    else
                        local moved_count = #clips_to_move
                        local nudged_count = delta_ms ~= 0 and #drag_clips or 0
                        if moved_count > 0 or nudged_count > 0 then
                            local delta_text = format_delta()
                            local direction = delta_ms < 0 and "left" or "right"
                            if moved_count > 0 and nudged_count > 0 and delta_text then
                                print(string.format("✅ Drag: Moved %d clip(s) and nudged %s by %s",
                                    moved_count, direction, delta_text))
                            elseif moved_count > 0 then
                                print(string.format("✅ Moved %d clip(s) to different track", moved_count))
                            elseif nudged_count > 0 and delta_text then
                                print(string.format("✅ Nudged %d clip(s) %s by %s",
                                    nudged_count, direction, delta_text))
                            end
                        end
                    end

                elseif drag_type == "edges" then
                    -- Ripple edit edges by delta
                    local active_sequence_id = state_module.get_sequence_id and state_module.get_sequence_id()
                    if not active_sequence_id or active_sequence_id == "" then
                        print("ERROR: Edge drag aborted - missing sequence id")
                        return
                    end
                    local active_project_id = state_module.get_project_id and state_module.get_project_id()
                    if not active_project_id or active_project_id == "" then
                        print("ERROR: Edge drag aborted - missing project id")
                        return
                    end

                    local edge_infos = {}
                    local all_clips = state_module.get_clips()

                    for _, edge in ipairs(drag_edges) do
                        local clip = nil
                        for _, c in ipairs(all_clips) do
                            if c.id == edge.clip_id then
                                clip = c
                                break
                            end
                        end

                        if clip then
                            table.insert(edge_infos, {
                                clip_id = edge.clip_id,
                                edge_type = edge.edge_type,
                                track_id = clip.track_id,
                                trim_type = edge.trim_type
                            })
                        else
                            print(string.format("WARNING: Drag release - clip %s not found for edge %s",
                                tostring(edge.clip_id), tostring(edge.edge_type)))
                        end
                    end

                    local result
                    if #edge_infos > 1 then
                        local batch_cmd = Command.create("BatchRippleEdit", active_project_id)
                        batch_cmd:set_parameter("edge_infos", edge_infos)
                        batch_cmd:set_parameter("delta_ms", delta_ms)
                        batch_cmd:set_parameter("sequence_id", active_sequence_id)
                        result = command_manager.execute(batch_cmd)
                    elseif #edge_infos == 1 then
                        local ripple_cmd = Command.create("RippleEdit", active_project_id)
                        ripple_cmd:set_parameter("edge_info", edge_infos[1])
                        ripple_cmd:set_parameter("delta_ms", delta_ms)
                        ripple_cmd:set_parameter("sequence_id", active_sequence_id)
                        result = command_manager.execute(ripple_cmd)
                    end

                    if result and result.success then
                        print(string.format("Dragged %d edge(s) by %dms", #edge_infos, delta_ms))
                    else
                        print(string.format("ERROR: Drag failed - result=%s, error=%s",
                            tostring(result and result.success),
                            tostring(result and result.error)))
                    end
                end

                -- Drag state already cleared above - just ensure clean render
                render()

            elseif view.panel_drag_end then
                -- Finalize drag selection via panel
                view.panel_drag_end(view.widget, x, y)
                view.panel_drag_move = nil
                view.panel_drag_end = nil
            end

            if view.pending_gap_click then
                local gap_click = view.pending_gap_click
                view.pending_gap_click = nil
                local release_track = get_track_id_at_y(y, height)
                if release_track then
                    local release_time = state_module.pixel_to_time(x, width)
                    local gap = find_gap_at_time(release_track, release_time)
                    if gap and gap.duration > 0 then
                        if gap_click.command_modifier then
                            state_module.toggle_gap_selection(gap)
                        else
                            state_module.set_gap_selection({gap})
                        end
                    end
                end
            end
            state_module.set_dragging_playhead(false)
        end

        render()
    end

    local function on_wheel_event(delta_x, delta_y, modifiers)
        local horizontal = delta_x or 0
        if math.abs(horizontal) < 0.0001 and modifiers and modifiers.shift then
            horizontal = delta_y or 0
        end

        if horizontal and math.abs(horizontal) > 0.0001 then
            local width = timeline.get_dimensions(widget)
            if width and width > 0 then
                local viewport_duration = state_module.get_viewport_duration()
                local delta_time = (-horizontal / width) * viewport_duration
                local new_start = state_module.get_viewport_start_time() + delta_time
                state_module.set_viewport_start_time(new_start)
                render()
            end
        end
    end

    -- Initialize
    update_filtered_tracks()
    update_widget_height()

    -- Set up event handlers
    timeline.set_lua_state(widget)

    -- Wire up mouse event handler
    local handler_name = "timeline_view_mouse_handler_" .. tostring(widget)
    _G[handler_name] = function(event)
        if event.type == "wheel" then
            on_wheel_event(event.delta_x, event.delta_y, event.modifiers)
        else
            on_mouse_event(event.type, event.x, event.y, event.button, event)
        end
    end
    timeline.set_mouse_event_handler(widget, handler_name)

    -- Wire up resize event handler to redraw when widget size changes
    local resize_handler_name = "timeline_view_resize_handler_" .. tostring(widget)
    _G[resize_handler_name] = function(event)
        -- print(string.format("Timeline widget resized: %dx%d -> %dx%d", event.old_width, event.old_height, event.width, event.height))
        render()
    end
    timeline.set_resize_event_handler(widget, resize_handler_name)

    -- Set expanding size policy so widget fills scroll area viewport
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(widget, "Expanding", "Expanding")
    print(string.format("Timeline view configured for %d tracks (widget: %s)", #view.filtered_tracks, tostring(widget)))

    -- Listen to state changes
    state_module.add_listener(function()
        update_filtered_tracks()
        update_widget_height()
        render()
    end)

    -- Initial render
    render()

    -- Public interface
    return {
        widget = widget,
        render = render,
        set_vertical_scroll = function(offset)
            view.vertical_scroll_offset = offset
            render()
        end,
        get_vertical_scroll = function()
            return view.vertical_scroll_offset
        end,
        on_mouse_event = on_mouse_event,
        on_wheel_event = on_wheel_event,
    }
end

return M
