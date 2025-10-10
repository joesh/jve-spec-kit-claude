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
    }

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

        -- Draw clips on these tracks
        local clips = state_module.get_clips()
        local selected_clips = state_module.get_selected_clips()

        -- Calculate drag offset if dragging clips
        local drag_offset_ms = 0
        local dragging_clip_ids = {}
        if view.drag_state and view.drag_state.type == "clips" then
            drag_offset_ms = view.drag_state.delta_ms or 0
            for _, clip in ipairs(view.drag_state.clips) do
                dragging_clip_ids[clip.id] = true
            end
        end

        for _, clip in ipairs(clips) do
            local y = get_track_y_by_id(clip.track_id, height)

            if y >= 0 then  -- Clip is on a track in this view
                -- Get actual track height for this clip's track
                local track_height = state_module.get_track_height(clip.track_id)

                -- Apply drag offset if this clip is being dragged
                local clip_start = clip.start_time
                if dragging_clip_ids[clip.id] then
                    clip_start = clip_start + drag_offset_ms
                end

                local x = state_module.time_to_pixel(clip_start, width)
                y = y + 5  -- Add padding from track top
                local clip_width = math.floor((clip.duration / viewport_duration) * width) - 1  -- 1px gap between clips
                local clip_height = track_height - 10  -- Use actual track height

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

                    -- Clip color (semi-transparent if being dragged)
                    local clip_color = is_selected and state_module.colors.clip_selected or state_module.colors.clip
                    if dragging_clip_ids[clip.id] then
                        -- Make dragged clips bright and semi-transparent for preview
                        clip_color = 0xCCCCCCAA  -- Bright semi-transparent white/gray
                    end

                    -- Clip rectangle
                    timeline.add_rect(view.widget, x, y, clip_width, clip_height, clip_color)

                    -- Clip name (if there's enough space)
                    if clip_width > 60 then
                        timeline.add_text(view.widget, x + 5, y + 25, clip.name, state_module.colors.text)
                    end
                end
            end
        end

        -- Draw selected edge highlights as bracket indicators (for trimming operations)
        local selected_edges = state_module.get_selected_edges()
        print(string.format("DEBUG RENDER: Drawing %d selected edges", #selected_edges))

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

        for _, edge in ipairs(selected_edges) do
            -- Find the clip for this edge
            local edge_clip = nil
            for _, clip in ipairs(clips) do
                if clip.id == edge.clip_id then
                    edge_clip = clip
                    break
                end
            end

            if edge_clip then
                local clip_y = get_track_y_by_id(edge_clip.track_id, height)
                print(string.format("  Drawing edge for clip %s, edge_type=%s, clip_y=%d",
                    edge_clip.id:sub(1,8), edge.edge_type, clip_y))

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
                        print(string.format("    Drawing [ bracket at x=%d, y=%d, type=%s", edge_x, bracket_y, edge.edge_type))
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
                        print(string.format("    Drawing ] bracket at x=%d, y=%d, type=%s", edge_x, bracket_y, edge.edge_type))
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
                    -- Clicking selected edge - start dragging
                    view.drag_state = {
                        type = "edges",
                        start_x = x,
                        start_time = state_module.pixel_to_time(x, width),
                        edges = selected_edges
                    }
                    print(string.format("Start dragging %d edge(s)", #selected_edges))
                    return
                else
                    -- Clicking unselected edge - select it and start dragging
                    if not (modifiers and modifiers.command) then
                        -- Without Cmd key, clear previous edge selection
                        state_module.clear_edge_selection()
                    end

                    -- Select all edges within the detection zone
                    for _, edge_info in ipairs(clips_at_position) do
                        state_module.toggle_edge_selection(edge_info.clip.id, edge_info.edge, "ripple")
                    end

                    -- Note: toggle_edge_selection() already clears clip selection (mutual exclusion)

                    -- Start dragging immediately
                    view.drag_state = {
                        type = "edges",
                        start_x = x,
                        start_time = state_module.pixel_to_time(x, width),
                        edges = state_module.get_selected_edges()
                    }
                    print(string.format("Start dragging %d edge(s)", #view.drag_state.edges))
                    render()
                    return
                end
            end

            -- No edge clicked - check if clicking on selected clip body for dragging
            local selected_clips = state_module.get_selected_clips()
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

                if is_selected then
                    -- Clicking on selected clip - start dragging
                    view.drag_state = {
                        type = "clips",
                        start_x = x,
                        start_time = state_module.pixel_to_time(x, width),
                        clips = selected_clips
                    }
                    print(string.format("Start dragging %d clip(s)", #selected_clips))
                    return
                else
                    -- Clicking on unselected clip - select it and start dragging
                    if not (modifiers and modifiers.command) then
                        -- Without Cmd, replace selection with this clip
                        state_module.clear_edge_selection()
                        state_module.set_selection({clicked_clip})
                    else
                        -- With Cmd, add to selection
                        state_module.toggle_clip_selection(clicked_clip.id)
                    end

                    -- Start dragging immediately
                    view.drag_state = {
                        type = "clips",
                        start_x = x,
                        start_time = state_module.pixel_to_time(x, width),
                        clips = state_module.get_selected_clips()
                    }
                    print(string.format("Start dragging %d clip(s)", #view.drag_state.clips))
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
            if view.drag_state then
                -- Dragging clips or edges - show visual feedback
                local current_time = state_module.pixel_to_time(x, width)
                view.drag_state.current_x = x
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
            if view.drag_state then
                -- Finalize drag operation - execute command
                local delta_ms = view.drag_state.delta_ms or 0

                if delta_ms ~= 0 then  -- Only execute if actually moved
                    local Command = require("command")
                    local command_manager = require("core.command_manager")

                    if view.drag_state.type == "clips" then
                        -- Nudge clips by delta
                        local clip_ids = {}
                        for _, clip in ipairs(view.drag_state.clips) do
                            table.insert(clip_ids, clip.id)
                        end

                        local nudge_cmd = Command.create("Nudge", "default_project")
                        nudge_cmd:set_parameter("nudge_amount_ms", delta_ms)
                        nudge_cmd:set_parameter("selected_clip_ids", clip_ids)

                        local result = command_manager.execute(nudge_cmd)
                        if result.success then
                            state_module.reload_clips()
                            print(string.format("Dragged %d clip(s) by %dms", #clip_ids, delta_ms))
                        else
                            print("ERROR: Drag failed: " .. (result.error_message or "unknown error"))
                        end

                    elseif view.drag_state.type == "edges" then
                        -- Ripple edit edges by delta
                        local edge_infos = {}
                        local all_clips = state_module.get_clips()

                        for _, edge in ipairs(view.drag_state.edges) do
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
                            print("ERROR: Drag failed")
                        end
                    end
                end

                -- Clear drag state
                view.drag_state = nil
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
