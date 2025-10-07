-- Timeline View Module
-- Renders a filtered subset of tracks from shared timeline state
-- Multiple views can exist, each showing different tracks

local M = {}

-- Create a new timeline view
-- Parameters:
--   widget: ScriptableTimeline Qt widget
--   state: Reference to timeline_state module
--   track_filter_fn: function(track) -> boolean (which tracks to show)
--   options: { vertical_scroll_offset = 0, render_bottom_to_top = false }
function M.create(widget, state_module, track_filter_fn, options)
    options = options or {}

    local view = {
        widget = widget,
        state = state_module,
        track_filter = track_filter_fn,
        vertical_scroll_offset = options.vertical_scroll_offset or 0,
        render_bottom_to_top = options.render_bottom_to_top or false,
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

        for _, clip in ipairs(clips) do
            local y = get_track_y_by_id(clip.track_id, height)

            if y >= 0 then  -- Clip is on a track in this view
                -- Get actual track height for this clip's track
                local track_height = state_module.get_track_height(clip.track_id)

                local x = state_module.time_to_pixel(clip.start_time, width)
                y = y + 5  -- Add padding from track top
                local clip_width = math.floor((clip.duration / viewport_duration) * width)
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

                    -- Clip color
                    local clip_color = is_selected and state_module.colors.clip_selected or state_module.colors.clip

                    -- Clip rectangle
                    timeline.add_rect(view.widget, x, y, clip_width, clip_height, clip_color)

                    -- Clip name (if there's enough space)
                    if clip_width > 60 then
                        timeline.add_text(view.widget, x + 5, y + 25, clip.name, state_module.colors.text)
                    end
                end
            end
        end

        -- Draw playhead line (vertical line only, triangle is in ruler)
        if playhead_time >= viewport_start and playhead_time <= viewport_start + viewport_duration then
            local playhead_x = state_module.time_to_pixel(playhead_time, width)
            timeline.add_line(view.widget, playhead_x, 0, playhead_x, height, state_module.colors.playhead, 2)
        end

        -- Draw drag selection box if active
        if state_module.is_drag_selecting() then
            local bounds = state_module.get_drag_selection_bounds()
            local x1 = state_module.time_to_pixel(bounds.start_time, width)
            local x2 = state_module.time_to_pixel(bounds.end_time, width)

            -- Calculate Y positions for tracks in this view
            local y1 = get_track_y(bounds.start_track, height)
            local y2 = get_track_y(bounds.end_track, height)

            if y1 >= 0 or y2 >= 0 then  -- At least part of selection is in this view
                local x = math.min(x1, x2)
                local y = math.min(y1, y2)
                local w = math.abs(x2 - x1)
                local h = math.abs(y2 - y1)

                -- Clamp to visible area
                y = math.max(0, y)
                h = math.min(height - y, h)

                -- Draw selection rectangle border
                timeline.add_line(view.widget, x, y, x + w, y, state_module.colors.selection_box, 2)
                timeline.add_line(view.widget, x + w, y, x + w, y + h, state_module.colors.selection_box, 2)
                timeline.add_line(view.widget, x + w, y + h, x, y + h, state_module.colors.selection_box, 2)
                timeline.add_line(view.widget, x, y + h, x, y, state_module.colors.selection_box, 2)
            end
        end

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

            -- Check if clicking on clip
            local clicked_clip = nil
            for _, clip in ipairs(state_module.get_clips()) do
                local clip_y = get_track_y_by_id(clip.track_id, height)
                if clip_y >= 0 then
                    local track_height = state_module.get_track_height(clip.track_id)
                    local clip_x = state_module.time_to_pixel(clip.start_time, width)
                    local clip_width = math.floor((clip.duration / state_module.get_viewport_duration()) * width)
                    local clip_height = track_height - 10

                    if x >= clip_x and x <= clip_x + clip_width and
                       y >= clip_y + 5 and y <= clip_y + 5 + clip_height then
                        clicked_clip = clip
                        break
                    end
                end
            end

            if clicked_clip then
                -- TODO: Handle clip selection and dragging
                state_module.set_selection({clicked_clip})
            else
                -- Start drag selection - determine which track was clicked
                local time = state_module.pixel_to_time(x, width)
                local track_index = 0
                local cumulative_y = 0
                for i, track in ipairs(view.filtered_tracks) do
                    local track_height = state_module.get_track_height(track.id)
                    if y >= cumulative_y and y < cumulative_y + track_height then
                        track_index = i - 1
                        break
                    end
                    cumulative_y = cumulative_y + track_height
                end

                state_module.set_drag_selecting(true)
                state_module.set_drag_selection_bounds(time, time, track_index, track_index)
            end

        elseif event_type == "move" then
            if state_module.is_dragging_playhead() then
                local time = state_module.pixel_to_time(x, width)
                state_module.set_playhead_time(time)

            elseif state_module.is_drag_selecting() then
                local time = state_module.pixel_to_time(x, width)
                -- Determine which track is at this Y position
                local track_index = 0
                local cumulative_y = 0
                for i, track in ipairs(view.filtered_tracks) do
                    local track_height = state_module.get_track_height(track.id)
                    if y >= cumulative_y and y < cumulative_y + track_height then
                        track_index = i - 1
                        break
                    end
                    cumulative_y = cumulative_y + track_height
                end

                local bounds = state_module.get_drag_selection_bounds()
                state_module.set_drag_selection_bounds(bounds.start_time, time, bounds.start_track, track_index)

                -- Update selection based on current drag box
                -- TODO: Implement multi-select logic
            end

        elseif event_type == "release" then
            state_module.set_dragging_playhead(false)
            state_module.set_drag_selecting(false)
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
