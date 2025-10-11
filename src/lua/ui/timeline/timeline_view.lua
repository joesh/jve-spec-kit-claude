-- Timeline View Module
-- Renders a filtered subset of tracks from shared timeline state
-- Multiple views can exist, each showing different tracks

local M = {}

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
    }

    local DRAG_THRESHOLD = 5  -- Pixels of movement before starting drag

    -- Filter tracks and cache result
    local function update_filtered_tracks()
        view.filtered_tracks = {}
        for _, track in ipairs(state_module.get_all_tracks()) do
            if track_filter_fn(track) then
                table.insert(view.filtered_tracks, track)
            end
        end
        print(string.format("Timeline view filtered %d tracks (widget: %s)", #view.filtered_tracks, tostring(widget)))
    end

    -- Calculate and set widget height based on track heights
    local function update_widget_height()
        local total_height = 0
        for _, track in ipairs(view.filtered_tracks) do
            local track_height = state_module.get_track_height(track.id)
            total_height = total_height + track_height
        end

        -- Set the widget's minimum height to accommodate all tracks
        qt_constants.PROPERTIES.SET_MIN_HEIGHT(widget, total_height)
        print(string.format("Timeline widget height set to %dpx for %d tracks", total_height, #view.filtered_tracks))
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
                    local track_height = state_module.get_track_height(view.filtered_tracks[i + 1].id)
                    y = y - track_height
                end
            end
            return y - view.vertical_scroll_offset
        else
            -- For audio tracks: render from top down (original behavior)
            local y = 0
            for i = 0, track_index - 1 do
                if view.filtered_tracks[i + 1] then
                    local track_height = state_module.get_track_height(view.filtered_tracks[i + 1].id)
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
            local track_height = state_module.get_track_height(track.id)
            if y >= track_y and y < track_y + track_height then
                return track.id
            end
        end
        return nil  -- No track at this Y position
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

        -- Clear previous drawing commands
        timeline.clear_commands(view.widget)

        -- Get viewport state
        local viewport_start = state_module.get_viewport_start_time()
        local viewport_duration = state_module.get_viewport_duration()
        local playhead_time = state_module.get_playhead_time()

        -- Draw tracks
        -- print(string.format("Rendering %d tracks (widget height: %d, viewport height: %d)", #view.filtered_tracks, height, height))
        for i, track in ipairs(view.filtered_tracks) do
            local y = get_track_y(i - 1, height)
            local track_height = state_module.get_track_height(track.id)
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
        local function draw_clips(time_offset_ms, outline_only, clip_filter, target_track_id)
            local clips = state_module.get_clips()
            local selected_clips = state_module.get_selected_clips()

            for _, clip in ipairs(clips) do
                -- Skip if filter function provided and returns false
                if clip_filter and not clip_filter(clip) then
                    goto continue
                end

                -- Use target track if provided, otherwise use clip's actual track
                local track_id = target_track_id or clip.track_id
                local y = get_track_y_by_id(track_id, height)

                if y >= 0 then  -- Clip is on a track in this view
                    local track_height = state_module.get_track_height(clip.track_id)
                    local clip_start = clip.start_time + time_offset_ms
                    local x = state_module.time_to_pixel(clip_start, width)
                    y = y + 5  -- Add padding from track top
                    local clip_width = math.floor((clip.duration / viewport_duration) * width) - 1
                    local clip_height = track_height - 10

                    -- Only draw if visible
                    if x + clip_width >= 0 and x <= width and
                       y + clip_height > 0 and y < height then

                        -- Check if selected
                        local is_selected = false
                        for _, selected in ipairs(selected_clips) do
                            if selected.id == clip.id then
                                is_selected = true
                                break
                            end
                        end

                        local outline_thickness = 2

                        if not outline_only then
                            -- Draw filled clip
                            timeline.add_rect(view.widget, x, y, clip_width, clip_height, state_module.colors.clip)

                            -- Clip name (if there's enough space)
                            if clip_width > 60 then
                                timeline.add_text(view.widget, x + 5, y + 25, clip.name, state_module.colors.text)
                            end
                        end

                        -- Draw outline if selected or if outline_only mode
                        if is_selected or outline_only then
                            -- Top
                            timeline.add_rect(view.widget, x, y, clip_width, outline_thickness, state_module.colors.clip_selected)
                            -- Bottom
                            timeline.add_rect(view.widget, x, y + clip_height - outline_thickness, clip_width, outline_thickness, state_module.colors.clip_selected)
                            -- Left
                            timeline.add_rect(view.widget, x, y, outline_thickness, clip_height, state_module.colors.clip_selected)
                            -- Right
                            timeline.add_rect(view.widget, x + clip_width - outline_thickness, y, outline_thickness, clip_height, state_module.colors.clip_selected)
                        end
                    end
                end
                ::continue::
            end
        end

        -- Draw clips at their normal positions
        draw_clips(0, false, nil)

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

            local dragging_clip_ids = {}
            for _, clip in ipairs(view.drag_state.clips) do
                dragging_clip_ids[clip.id] = true
            end

            -- Draw outline preview only for dragged clips at their new positions/track
            -- For multi-track selections, don't change tracks (pass nil)
            draw_clips(drag_offset_ms, true, function(clip)
                return dragging_clip_ids[clip.id]
            end, multi_track_selection and nil or target_track_id)
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
                local edge = view.drag_state.edges[1]
                local ripple_cmd = Command.create("RippleEdit", "default_project")
                ripple_cmd:set_parameter("edge_info", {
                    clip_id = edge.clip_id,
                    edge_type = edge.edge_type,
                    track_id = edge.track_id
                })
                ripple_cmd:set_parameter("delta_ms", edge_drag_offset_ms)
                ripple_cmd:set_parameter("sequence_id", "default_sequence")
                ripple_cmd:set_parameter("dry_run", true)

                local executor = command_manager.get_executor("RippleEdit")
                if executor then
                    success, preview_data = executor(ripple_cmd)
                end
            -- Multiple edges: use BatchRippleEdit
            elseif #view.drag_state.edges > 1 then
                local edge_infos = {}
                for _, edge in ipairs(view.drag_state.edges) do
                    table.insert(edge_infos, {
                        clip_id = edge.clip_id,
                        edge_type = edge.edge_type,
                        track_id = edge.track_id
                    })
                end

                local batch_cmd = Command.create("BatchRippleEdit", "default_project")
                batch_cmd:set_parameter("edge_infos", edge_infos)
                batch_cmd:set_parameter("delta_ms", edge_drag_offset_ms)
                batch_cmd:set_parameter("sequence_id", "default_sequence")
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
                                local track_height = state_module.get_track_height(clip.track_id)
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
                                local track_height = state_module.get_track_height(clip.track_id)
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
                    local track_height = state_module.get_track_height(clip.track_id)
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
                    local track_height = state_module.get_track_height(edge_clip.track_id)

                    -- Apply drag offset to clip boundaries if this edge is being dragged
                    local edge_key = edge.clip_id .. ":" .. edge.edge_type
                    local is_dragging = dragging_edge_ids[edge_key]

                    local clip_start = edge_clip.start_time
                    local clip_duration = edge_clip.duration

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

                    if edge.edge_type == "in" then
                        -- Clip's in-point: [ facing right
                        edge_x = clip_x
                        bracket_type = "in"
                        has_available_media = edge_clip.source_in > 0
                    elseif edge.edge_type == "out" then
                        -- Clip's out-point: ] facing left
                        edge_x = clip_x + clip_width
                        bracket_type = "out"
                        has_available_media = true
                    elseif edge.edge_type == "gap_before" then
                        -- Gap's edge before clip: ] facing right (closing towards clip)
                        edge_x = clip_x
                        bracket_type = "out"
                        has_available_media = true  -- Gap always has "space" available
                    elseif edge.edge_type == "gap_after" then
                        -- Gap's edge after clip: [ facing left (opening into gap)
                        edge_x = clip_x + clip_width
                        bracket_type = "in"
                        has_available_media = true  -- Gap always has "space" available
                    end

                    -- Choose color based on media availability (white if dragging for visibility)
                    local edge_color
                    if is_dragging then
                        edge_color = 0xFFFFFFFF  -- Bright white for drag preview
                    else
                        edge_color = has_available_media
                            and state_module.colors.edge_selected_available
                            or state_module.colors.edge_selected_limit
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

        -- Draw playhead line (vertical line only, triangle is in ruler)
        if playhead_time >= viewport_start and playhead_time <= viewport_start + viewport_duration then
            local playhead_x = state_module.time_to_pixel(playhead_time, width)
            timeline.add_line(view.widget, playhead_x, 0, playhead_x, height, state_module.colors.playhead, 2)
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

            local EDGE_ZONE = 8  -- Pixels from edge to detect single edge
            local EDIT_POINT_ZONE = 4  -- Pixels - must be close to center for edit point
            local clips_at_position = {}

            -- First pass: find all clips at this Y position and their edge proximity
            for _, clip in ipairs(state_module.get_clips()) do
                local clip_y = get_track_y_by_id(clip.track_id, height)
                if clip_y >= 0 then
                    local track_height = state_module.get_track_height(clip.track_id)
                    local clip_height = track_height - 10

                    -- Check if Y is within track bounds (full track, not just clip height)
                    if y >= clip_y and y <= clip_y + track_height then
                        local clip_x = state_module.time_to_pixel(clip.start_time, width)
                        local clip_width = math.floor((clip.duration / state_module.get_viewport_duration()) * width) - 1
                        local clip_end_x = clip_x + clip_width

                        -- Left edge: distinguish between clip's in-point and gap's out-point
                        local dist_from_left = math.abs(x - clip_x)
                        if dist_from_left <= EDGE_ZONE then
                            local inside_clip = x >= clip_x
                            table.insert(clips_at_position, {
                                clip = clip,
                                edge = inside_clip and "in" or "gap_before",  -- in=] from clip side, gap_before=[ from gap side
                                distance = dist_from_left
                            })
                        end

                        -- Right edge: distinguish between clip's out-point and gap's in-point
                        local dist_from_right = math.abs(x - clip_end_x)
                        if dist_from_right <= EDGE_ZONE then
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
                -- Check if any detected edge is already selected
                local selected_edges = state_module.get_selected_edges()
                local clicking_selected_edge = false
                for _, edge_info in ipairs(clips_at_position) do
                    for _, selected in ipairs(selected_edges) do
                        if selected.clip_id == edge_info.clip.id and selected.edge_type == edge_info.edge then
                            clicking_selected_edge = true
                            break
                        end
                    end
                    if clicking_selected_edge then break end
                end

                if clicking_selected_edge then
                    -- Clicking on selected edge
                    if modifiers and modifiers.command then
                        -- Cmd+click on selected edge - toggle it (deselect)
                        for _, edge_info in ipairs(clips_at_position) do
                            state_module.toggle_edge_selection(edge_info.clip.id, edge_info.edge, "ripple")
                        end
                        render()
                        return
                    else
                        -- Regular click on selected edge - prepare for potential drag
                        view.potential_drag = {
                            type = "edges",
                            start_x = x,
                            start_y = y,
                            start_time = state_module.pixel_to_time(x, width),
                            edges = selected_edges,
                            modifiers = modifiers
                        }
                        print(string.format("Clicked %d selected edge(s)", #selected_edges))
                        return
                    end
                else
                    -- Clicking unselected edge - select it
                    if not (modifiers and modifiers.command) then
                        -- Without Cmd key, clear previous edge selection
                        state_module.clear_edge_selection()
                        -- Select only the CLOSEST edge (for ripple edit)
                        -- If you want to select both edges for roll edit, use Cmd+click
                        if #clips_at_position > 0 then
                            -- Find closest edge
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
                            state_module.toggle_edge_selection(edge_info.clip.id, edge_info.edge, "ripple")
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
                    local track_height = state_module.get_track_height(clip.track_id)
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
                            modifiers = modifiers
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
                        modifiers = modifiers
                    }
                    print(string.format("Selected %d clip(s)", #view.potential_drag.clips))
                    render()
                    return
                end
            end

            -- Not clicking on clip or edge - starting drag selection
            -- Clear selections unless Cmd is held (for multi-select)
            if not (modifiers and modifiers.command) then
                state_module.clear_edge_selection()
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
                    view.drag_state = {
                        type = view.potential_drag.type,
                        start_x = view.potential_drag.start_x,
                        start_y = view.potential_drag.start_y,
                        start_time = view.potential_drag.start_time,
                        clips = view.potential_drag.clips,
                        edges = view.potential_drag.edges,
                        current_x = x,
                        current_y = y,
                        current_time = state_module.pixel_to_time(x, width)
                    }
                    view.drag_state.delta_ms = math.floor(view.drag_state.current_time - view.drag_state.start_time)

                    local item_count = view.drag_state.clips and #view.drag_state.clips or #view.drag_state.edges
                    local item_type = view.drag_state.type == "clips" and "clip(s)" or "edge(s)"
                    print(string.format("Start dragging %d %s (threshold exceeded)", item_count, item_type))

                    view.potential_drag = nil
                    render()
                end
            elseif view.drag_state then
                -- Dragging clips or edges - show visual feedback
                local current_time = state_module.pixel_to_time(x, width)
                view.drag_state.current_x = x
                view.drag_state.current_y = y
                view.drag_state.current_time = current_time
                view.drag_state.delta_ms = math.floor(current_time - view.drag_state.start_time)
                render()  -- Show drag preview
            elseif state_module.is_dragging_playhead() then
                local time = state_module.pixel_to_time(x, width)
                state_module.set_playhead_time(time)
            elseif view.panel_drag_move then
                -- Forward move events to panel during drag selection
                view.panel_drag_move(view.widget, x, y)
            else
                -- Update cursor based on what's under the mouse
                local EDGE_ZONE = 8
                local EDIT_POINT_ZONE = 4
                local cursor_type = "arrow"  -- Default
                local clips_at_position = {}

                -- Find all edges near mouse position (same logic as click detection)
                for _, clip in ipairs(state_module.get_clips()) do
                    local clip_y = get_track_y_by_id(clip.track_id, height)
                    if clip_y >= 0 then
                        local track_height = state_module.get_track_height(clip.track_id)
                        local clip_height = track_height - 10

                        if y >= clip_y + 5 and y <= clip_y + 5 + clip_height then
                            local clip_x = state_module.time_to_pixel(clip.start_time, width)
                            local clip_width = math.floor((clip.duration / state_module.get_viewport_duration()) * width) - 1

                            local dist_from_left = math.abs(x - clip_x)
                            local dist_from_right = math.abs(x - (clip_x + clip_width))

                            if dist_from_left <= EDGE_ZONE then
                                table.insert(clips_at_position, {
                                    edge = "in",
                                    distance = dist_from_left
                                })
                            end
                            if dist_from_right <= EDGE_ZONE then
                                table.insert(clips_at_position, {
                                    edge = "out",
                                    distance = dist_from_right
                                })
                            end
                        end
                    end
                end

                -- Determine cursor based on edge proximity
                if #clips_at_position == 2 then
                    -- Two edges detected - check if it's an edit point
                    local max_distance = math.max(clips_at_position[1].distance, clips_at_position[2].distance)
                    if max_distance <= EDIT_POINT_ZONE then
                        cursor_type = "split_h"  -- Edit point: ][ uses split cursor
                    else
                        -- Select closest edge only
                        local closest = clips_at_position[1]
                        if clips_at_position[2].distance < closest.distance then
                            closest = clips_at_position[2]
                        end
                        -- Single edge cursor
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

                -- Clear drag state IMMEDIATELY to prevent preview rendering during command execution
                -- (reload_clips triggers listeners which call render)
                view.drag_state = nil
                view.potential_drag = nil

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
                    -- Use first clip as reference for calculating offset
                    local reference_clip = current_clips[1]
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

                    -- Execute track changes
                    if #clips_to_move > 0 then
                        for _, move_info in ipairs(clips_to_move) do
                            local move_cmd = Command.create("MoveClipToTrack", "default_project")
                            move_cmd:set_parameter("clip_id", move_info.clip.id)
                            move_cmd:set_parameter("target_track_id", move_info.target_track_id)

                            local result = command_manager.execute(move_cmd)
                            if not result.success then
                                print(string.format("ERROR: Failed to move clip %s to track %s",
                                    move_info.clip.id:sub(1,8), move_info.target_track_id))
                            end
                        end
                        -- Reload clips after track changes
                        state_module.reload_clips()
                    end

                    -- Execute time nudge (if moved horizontally)
                    if delta_ms ~= 0 then
                        local clip_ids = {}
                        for _, clip in ipairs(drag_clips) do
                            table.insert(clip_ids, clip.id)
                        end

                        local nudge_cmd = Command.create("Nudge", "default_project")
                        nudge_cmd:set_parameter("nudge_amount_ms", delta_ms)
                        nudge_cmd:set_parameter("selected_clip_ids", clip_ids)

                        local result = command_manager.execute(nudge_cmd)
                        if result.success then
                            state_module.reload_clips()
                        else
                            print("ERROR: Nudge failed: " .. (result.error_message or "unknown error"))
                        end
                    end

                    -- Summary message
                    local moved_count = #clips_changed_track
                    local nudged_count = delta_ms ~= 0 and #drag_clips or 0
                    if moved_count > 0 and nudged_count > 0 then
                        print(string.format("Moved %d clip(s) to track %s and nudged by %dms",
                            moved_count, target_track_id, delta_ms))
                    elseif moved_count > 0 then
                        print(string.format("Moved %d clip(s) to track %s", moved_count, target_track_id))
                    elseif nudged_count > 0 then
                        print(string.format("Nudged %d clip(s) by %dms", nudged_count, delta_ms))
                    end

                elseif drag_type == "edges" then
                    -- Ripple edit edges by delta
                    local edge_infos = {}
                    local all_clips = state_module.get_clips()

                    for _, edge in ipairs(drag_edges) do
                        -- Find track_id for each edge
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
                                track_id = clip.track_id
                            })
                        end
                    end

                    local result
                    if #edge_infos > 1 then
                        local batch_cmd = Command.create("BatchRippleEdit", "default_project")
                        batch_cmd:set_parameter("edge_infos", edge_infos)
                        batch_cmd:set_parameter("delta_ms", delta_ms)
                        batch_cmd:set_parameter("sequence_id", "default_sequence")
                        result = command_manager.execute(batch_cmd)
                    elseif #edge_infos == 1 then
                        local ripple_cmd = Command.create("RippleEdit", "default_project")
                        ripple_cmd:set_parameter("edge_info", edge_infos[1])
                        ripple_cmd:set_parameter("delta_ms", delta_ms)
                        ripple_cmd:set_parameter("sequence_id", "default_sequence")
                        result = command_manager.execute(ripple_cmd)
                    end

                    if result and result.success then
                        state_module.reload_clips()
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
            state_module.set_dragging_playhead(false)
        end

        render()
    end

    -- Initialize
    update_filtered_tracks()
    update_widget_height()

    -- Set up event handlers
    timeline.set_lua_state(widget)

    -- Wire up mouse event handler
    local handler_name = "timeline_view_mouse_handler_" .. tostring(widget)
    _G[handler_name] = function(event)
        on_mouse_event(event.type, event.x, event.y, event.button, event)
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
    }
end

return M
