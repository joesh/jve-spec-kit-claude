-- Timeline UI Module
-- Implements all timeline logic in Lua, using ScriptableTimeline for rendering

local M = {}
local db = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local project_browser = nil  -- Will be set by main layout

-- Callbacks
local on_selection_changed_callback = nil

-- Set callback for selection changes
function M.set_on_selection_changed(callback)
    on_selection_changed_callback = callback
end

-- Set project browser reference for accessing selected media
function M.set_project_browser(browser)
    project_browser = browser
end

-- Timeline dimensions (single source of truth)
M.dimensions = {
    ruler_height = 32,
    track_height = 50,
    track_header_width = 150,
    track_area_separator_height = 30,  -- Space between video and audio areas
}

-- Timeline state
local state = {
    widget = nil,
    zoom = 0.1,  -- pixels per millisecond
    scroll_offset = 0,  -- horizontal scroll in pixels
    playhead_time = 0,  -- milliseconds
    tracks = {},  -- All tracks from database
    video_tracks = {},  -- Filtered video tracks
    audio_tracks = {},  -- Filtered audio tracks
    clips = {},
    ruler_height = M.dimensions.ruler_height,
    track_height = M.dimensions.track_height,
    track_header_width = M.dimensions.track_header_width,
    track_area_separator_height = M.dimensions.track_area_separator_height,
}

-- Colors
local colors = {
    background = "#232323",
    ruler = "#2a2a2a",
    track_odd = "#2b2b2b",
    track_even = "#252525",
    video_track_header = "#3a3a5a",  -- Slightly blue tint for video
    audio_track_header = "#3a4a3a",  -- Slightly green tint for audio
    track_area_separator = "#1a1a1a",  -- Dark separator between video/audio
    clip = "#4a90e2",
    clip_selected = "#ff8c42",  -- Orange for selected clips
    playhead = "#ff6b6b",
    text = "#cccccc",
    grid_line = "#3a3a3a",
    selection_box = "#ff8c42",  -- Orange for selection box
}

-- Interaction state
local interaction = {
    dragging_playhead = false,
    dragging_clip = nil,
    drag_start_x = 0,
    drag_start_y = 0,
    selected_clips = {},  -- Changed to array for multi-selection
    drag_selecting = false,
    drag_select_start_x = 0,
    drag_select_start_y = 0,
    drag_select_end_x = 0,
    drag_select_end_y = 0,
    dragging_separator = false,
    video_area_height = nil,  -- Will be calculated dynamically if separator dragged
}

-- Initialize timeline with widget
function M.init(widget, options)
    state.widget = widget

    -- Apply options
    options = options or {}
    if options.track_header_width then
        state.track_header_width = options.track_header_width
    end

    -- Load tracks and clips from database
    state.tracks = db.load_tracks("default_sequence")
    state.clips = db.load_clips("default_sequence")

    -- Partition tracks by type
    state.video_tracks = {}
    state.audio_tracks = {}
    for _, track in ipairs(state.tracks) do
        if track.track_type == "VIDEO" then
            table.insert(state.video_tracks, track)
        elseif track.track_type == "AUDIO" then
            table.insert(state.audio_tracks, track)
        end
    end

    print(string.format("Loaded %d video tracks, %d audio tracks, %d clips from database",
        #state.video_tracks, #state.audio_tracks, #state.clips))

    -- Set Lua state for callbacks
    timeline.set_lua_state(widget)

    -- Set up event handlers
    timeline.set_mouse_event_handler(widget, "timeline_mouse_event")
    timeline.set_key_event_handler(widget, "timeline_key_event")

    -- Initial render
    M.render()

    return true
end

-- Convert time (ms) to pixel position
function M.time_to_pixel(time_ms)
    return math.floor((time_ms * state.zoom) - state.scroll_offset)
end

-- Convert pixel position to time (ms)
function M.pixel_to_time(pixel)
    return math.floor((pixel + state.scroll_offset) / state.zoom)
end

-- Get current video area height (either custom or calculated)
local function get_video_area_height()
    return interaction.video_area_height or (#state.video_tracks * state.track_height)
end

-- Get track Y position based on track ID and type
-- Returns the Y position for a track, accounting for separate video/audio areas
function M.get_track_y_by_id(track_id)
    -- Search in video tracks first
    for i, track in ipairs(state.video_tracks) do
        if track.id == track_id then
            return state.ruler_height + ((i - 1) * state.track_height)
        end
    end

    -- Search in audio tracks
    for i, track in ipairs(state.audio_tracks) do
        if track.id == track_id then
            local video_area_height = get_video_area_height()
            local separator_y = state.ruler_height + video_area_height
            return separator_y + state.track_area_separator_height + ((i - 1) * state.track_height)
        end
    end

    return 0  -- Track not found
end

-- Get Y position for a track by index within its type
-- track_type: "VIDEO" or "AUDIO"
-- track_index: 0-based index within that type
function M.get_track_y(track_type, track_index)
    if track_type == "VIDEO" then
        return state.ruler_height + (track_index * state.track_height)
    elseif track_type == "AUDIO" then
        local video_area_height = get_video_area_height()
        local separator_y = state.ruler_height + video_area_height
        return separator_y + state.track_area_separator_height + (track_index * state.track_height)
    end
    return 0
end

-- Get separator Y position
local function get_separator_y()
    return state.ruler_height + get_video_area_height()
end

-- Render timeline
function M.render()
    if not state.widget then
        return
    end

    -- Get widget dimensions
    local width, height = timeline.get_dimensions(state.widget)

    -- Clear previous drawing commands
    timeline.clear_commands(state.widget)

    -- Draw ruler
    M.draw_ruler(width)

    -- Draw tracks
    M.draw_tracks(width, height)

    -- Draw clips
    M.draw_clips()

    -- Draw playhead
    M.draw_playhead(height)

    -- Draw drag-select rectangle if active
    if interaction.drag_selecting then
        local x = math.min(interaction.drag_select_start_x, interaction.drag_select_end_x)
        local y = math.min(interaction.drag_select_start_y, interaction.drag_select_end_y)
        local w = math.abs(interaction.drag_select_end_x - interaction.drag_select_start_x)
        local h = math.abs(interaction.drag_select_end_y - interaction.drag_select_start_y)

        -- Draw selection rectangle border only (no fill)
        timeline.add_line(state.widget, x, y, x + w, y, colors.selection_box, 2)
        timeline.add_line(state.widget, x + w, y, x + w, y + h, colors.selection_box, 2)
        timeline.add_line(state.widget, x + w, y + h, x, y + h, colors.selection_box, 2)
        timeline.add_line(state.widget, x, y + h, x, y, colors.selection_box, 2)
    end

    -- Trigger Qt repaint
    timeline.update(state.widget)
end

-- Draw time ruler
function M.draw_ruler(width)
    -- Calculate extended timeline width based on actual content
    -- Find the rightmost clip to determine timeline duration
    local timeline_duration_ms = 60000  -- Default minimum 60 seconds
    for _, clip in ipairs(state.clips) do
        local clip_end = clip.start_time + clip.duration
        if clip_end > timeline_duration_ms then
            timeline_duration_ms = clip_end
        end
    end
    -- Add 10 seconds of padding after the last clip
    timeline_duration_ms = timeline_duration_ms + 10000

    local timeline_width = math.floor(timeline_duration_ms * state.zoom)

    -- Ruler background (extended width)
    timeline.add_rect(state.widget, 0, 0, math.max(width, timeline_width), state.ruler_height, colors.ruler)

    -- Time markers - zoom-dependent interval
    local visible_start_time = M.pixel_to_time(0)
    local visible_end_time = timeline_duration_ms

    -- Calculate appropriate interval based on zoom level
    -- We want markers roughly 60-120 pixels apart
    local target_pixel_spacing = 80
    local interval_ms = math.floor(target_pixel_spacing / state.zoom)

    -- Round to nice intervals: 100ms, 200ms, 500ms, 1s, 2s, 5s, 10s, 30s, 60s
    local nice_intervals = {100, 200, 500, 1000, 2000, 5000, 10000, 30000, 60000}
    for _, nice in ipairs(nice_intervals) do
        if interval_ms <= nice then
            interval_ms = nice
            break
        end
    end

    local start_marker = math.floor(visible_start_time / interval_ms) * interval_ms

    for time_ms = start_marker, visible_end_time, interval_ms do
        local x = M.time_to_pixel(time_ms)
        if x >= 0 and x <= width then
            -- Tick mark
            timeline.add_line(state.widget, x, state.ruler_height - 10, x, state.ruler_height, colors.grid_line, 1)

            -- Time label (convert to seconds)
            local seconds = time_ms / 1000
            timeline.add_text(state.widget, x + 2, 18, string.format("%.1fs", seconds), colors.text)
        end
    end
end

-- Draw tracks - separate video and audio areas
function M.draw_tracks(width, height)
    -- Draw video tracks
    for i, track in ipairs(state.video_tracks) do
        local y = M.get_track_y("VIDEO", i - 1)

        -- Alternate track colors
        local track_color = (i % 2 == 0) and colors.track_even or colors.track_odd

        -- Track header (left side, fixed) with video-specific color
        timeline.add_rect(state.widget, 0, y, state.track_header_width, state.track_height, colors.video_track_header)
        timeline.add_text(state.widget, 10, y + 28, track.name, colors.text)

        -- Track content area (right of header)
        timeline.add_rect(state.widget, state.track_header_width, y, width - state.track_header_width, state.track_height, track_color)

        -- Track separator line
        timeline.add_line(state.widget, 0, y, width, y, colors.grid_line, 1)
    end

    -- Draw separator area between video and audio
    if #state.video_tracks > 0 and #state.audio_tracks > 0 then
        local separator_y = get_separator_y()

        -- Top border line (marks end of video area)
        timeline.add_line(state.widget, 0, separator_y, width, separator_y, "#555555", 2)

        -- Draggable separator bar
        timeline.add_rect(state.widget, 0, separator_y, width, state.track_area_separator_height, colors.track_area_separator)

        -- Bottom border line (marks start of audio area)
        timeline.add_line(state.widget, 0, separator_y + state.track_area_separator_height, width, separator_y + state.track_area_separator_height, "#555555", 2)

        -- Draw resize handle in the middle with label
        local handle_width = 80
        local handle_x = state.track_header_width / 2 - handle_width / 2
        local handle_y = separator_y + (state.track_area_separator_height - 16) / 2
        timeline.add_rect(state.widget, handle_x, handle_y, handle_width, 16, "#444444")
        timeline.add_text(state.widget, handle_x + 18, handle_y + 12, "AUDIO", "#aaaaaa")
    end

    -- Draw audio tracks
    for i, track in ipairs(state.audio_tracks) do
        local y = M.get_track_y("AUDIO", i - 1)

        -- Alternate track colors
        local track_color = (i % 2 == 0) and colors.track_even or colors.track_odd

        -- Track header (left side, fixed) with audio-specific color
        timeline.add_rect(state.widget, 0, y, state.track_header_width, state.track_height, colors.audio_track_header)
        timeline.add_text(state.widget, 10, y + 28, track.name, colors.text)

        -- Track content area (right of header)
        timeline.add_rect(state.widget, state.track_header_width, y, width - state.track_header_width, state.track_height, track_color)

        -- Track separator line
        timeline.add_line(state.widget, 0, y, width, y, colors.grid_line, 1)
    end
end

-- Check if clip is selected
-- Notify selection changed
local function notify_selection_changed()
    -- print("DEBUG: notify_selection_changed called, " .. #interaction.selected_clips .. " clips selected")
    if on_selection_changed_callback then
        -- print("DEBUG: Calling selection callback")
        on_selection_changed_callback(interaction.selected_clips)
    else
        -- print("DEBUG: No selection callback registered!")
    end
end

local function is_clip_selected(clip)
    for _, selected in ipairs(interaction.selected_clips) do
        if selected.id == clip.id then
            return true
        end
    end
    return false
end

-- Draw clips
function M.draw_clips()
    local width, height = timeline.get_dimensions(state.widget)

    for _, clip in ipairs(state.clips) do
        -- Get Y position using track ID (works with separated video/audio areas)
        local y = M.get_track_y_by_id(clip.track_id)

        if y > 0 then
            local x = state.track_header_width + M.time_to_pixel(clip.start_time)
            y = y + 5  -- Add padding from track top
            local clip_width = math.floor(clip.duration * state.zoom)
            local clip_height = state.track_height - 10

            -- Only draw if visible
            if x + clip_width >= state.track_header_width and x <= width then
                -- Determine clip color based on selection
                local clip_color = colors.clip
                if is_clip_selected(clip) then
                    clip_color = colors.clip_selected
                end

                -- Clip rectangle
                timeline.add_rect(state.widget, x, y, clip_width, clip_height, clip_color)

                -- Clip name (if there's enough space)
                if clip_width > 60 then
                    timeline.add_text(state.widget, x + 5, y + 25, clip.name, colors.text)
                end
            end
        end
    end
end

-- Draw playhead
function M.draw_playhead(height)
    local playhead_x = state.track_header_width + M.time_to_pixel(state.playhead_time)

    -- Playhead line (from top to bottom)
    timeline.add_line(state.widget, playhead_x, 0, playhead_x, height, colors.playhead, 2)

    -- Playhead handle (downward-pointing triangle at top)
    -- Draw three lines to form a triangle
    local handle_size = 8
    local handle_y = 0
    local tip_y = handle_y + handle_size

    -- Left edge
    timeline.add_line(state.widget, playhead_x - handle_size/2, handle_y, playhead_x, tip_y, colors.playhead, 2)
    -- Right edge
    timeline.add_line(state.widget, playhead_x, tip_y, playhead_x + handle_size/2, handle_y, colors.playhead, 2)
    -- Top edge
    timeline.add_line(state.widget, playhead_x - handle_size/2, handle_y, playhead_x + handle_size/2, handle_y, colors.playhead, 2)
end

-- Set zoom level
function M.set_zoom(zoom_factor)
    state.zoom = math.max(0.01, math.min(10.0, zoom_factor))
    M.render()
end

-- Set playhead position
function M.set_playhead(time_ms)
    state.playhead_time = time_ms
    timeline.set_playhead(state.widget, time_ms)
    M.render()
end

-- Scroll timeline
function M.set_scroll(offset)
    state.scroll_offset = math.max(0, offset)
    M.render()
end

-- Add clip
function M.add_clip(track_id, start_time, duration, name)
    local clip = {
        id = "clip_" .. (#state.clips + 1),
        track_id = track_id,
        start_time = start_time,
        duration = duration,
        name = name or "Clip"
    }
    table.insert(state.clips, clip)
    M.render()
    return clip.id
end

-- Check if point is near playhead
function M.is_near_playhead(x, y)
    local playhead_x = state.track_header_width + M.time_to_pixel(state.playhead_time)
    local distance = math.abs(x - playhead_x)
    return distance < 5  -- 5px tolerance, works anywhere along playhead
end

-- Check if point is near separator (for dragging)
local function is_near_separator(x, y)
    if #state.video_tracks == 0 or #state.audio_tracks == 0 then
        return false
    end

    local separator_y = get_separator_y()
    local distance = math.abs(y - separator_y - state.track_area_separator_height / 2)
    return distance < 10  -- 10px tolerance for drag handle
end

-- Find clip at position
function M.find_clip_at(x, y)
    local width, height = timeline.get_dimensions(state.widget)

    for _, clip in ipairs(state.clips) do
        -- Find track index
        local track_index = nil
        for i, track in ipairs(state.tracks) do
            if track.id == clip.track_id then
                track_index = i - 1
                break
            end
        end

        if track_index then
            local clip_x = state.track_header_width + M.time_to_pixel(clip.start_time)
            local clip_y = M.get_track_y(track_index) + 5
            local clip_width = math.floor(clip.duration * state.zoom)
            local clip_height = state.track_height - 10

            if x >= clip_x and x <= clip_x + clip_width and
               y >= clip_y and y <= clip_y + clip_height then
                return clip
            end
        end
    end
    return nil
end

-- Add clip to selection
local function add_to_selection(clip)
    if not is_clip_selected(clip) then
        table.insert(interaction.selected_clips, clip)
        notify_selection_changed()
    end
end

-- Remove clip from selection
local function remove_from_selection(clip)
    for i, selected in ipairs(interaction.selected_clips) do
        if selected.id == clip.id then
            table.remove(interaction.selected_clips, i)
            notify_selection_changed()
            return
        end
    end
end

-- Global mouse event handler
function timeline_mouse_event(event)
    if event.type == "press" then
        timeline_on_mouse_press(event)
    elseif event.type == "move" then
        timeline_on_mouse_move(event)
    elseif event.type == "release" then
        timeline_on_mouse_release(event)
    end
end

-- Mouse press handler
function timeline_on_mouse_press(event)
    local x, y = event.x, event.y
    local ctrl_pressed = event.ctrl

    -- Check if clicking in ruler area
    if y < state.ruler_height then
        -- Click in ruler: move playhead to this position and start dragging
        local time_ms = M.pixel_to_time(x - state.track_header_width)
        time_ms = math.max(0, time_ms)
        M.set_playhead(time_ms)
        interaction.dragging_playhead = true
        return
    end

    -- Check if clicking near playhead (in track area)
    if M.is_near_playhead(x, y) then
        interaction.dragging_playhead = true
        return
    end

    -- Check if clicking near separator (to resize video/audio areas)
    if is_near_separator(x, y) then
        interaction.dragging_separator = true
        interaction.drag_start_y = y
        return
    end

    -- Check if clicking on a clip
    local clip = M.find_clip_at(x, y)
    if clip then
        if ctrl_pressed then
            -- Command-click: toggle selection
            if is_clip_selected(clip) then
                remove_from_selection(clip)
            else
                add_to_selection(clip)
            end
        else
            -- Regular click: select only this clip (unless already selected for dragging)
            if not is_clip_selected(clip) then
                interaction.selected_clips = {clip}
                notify_selection_changed()
            end
            interaction.dragging_clip = clip
            interaction.drag_start_x = x
        end
        M.render()  -- Re-render to show selection
        return
    end

    -- Otherwise, start drag-select (unless ctrl-clicking or in ruler)
    if not ctrl_pressed then
        interaction.selected_clips = {}
        notify_selection_changed()
    end
    interaction.drag_selecting = true
    interaction.drag_select_start_x = x
    interaction.drag_select_start_y = y
    interaction.drag_select_end_x = x
    interaction.drag_select_end_y = y
    M.render()
end

-- Check if clip is in rectangle
local function is_clip_in_rect(clip, x1, y1, x2, y2)
    -- Find track index
    local track_index = nil
    for i, track in ipairs(state.tracks) do
        if track.id == clip.track_id then
            track_index = i - 1
            break
        end
    end

    if not track_index then
        return false
    end

    local clip_x = state.track_header_width + M.time_to_pixel(clip.start_time)
    local clip_y = M.get_track_y(track_index) + 5
    local clip_width = math.floor(clip.duration * state.zoom)
    local clip_height = state.track_height - 10

    -- Normalize rectangle coordinates
    local rect_x1 = math.min(x1, x2)
    local rect_y1 = math.min(y1, y2)
    local rect_x2 = math.max(x1, x2)
    local rect_y2 = math.max(y1, y2)

    -- Check if rectangles overlap
    return not (clip_x + clip_width < rect_x1 or
                clip_x > rect_x2 or
                clip_y + clip_height < rect_y1 or
                clip_y > rect_y2)
end

-- Mouse move handler
function timeline_on_mouse_move(event)
    local x, y = event.x, event.y
    if interaction.dragging_playhead then
        -- Update playhead position
        local time_ms = M.pixel_to_time(x - state.track_header_width)
        time_ms = math.max(0, time_ms)
        M.set_playhead(time_ms)
    elseif interaction.dragging_separator then
        -- Update video area height based on mouse Y position
        local new_height = y - state.ruler_height
        -- Clamp to reasonable bounds (at least 1 track worth of space for each)
        local min_height = state.track_height
        local max_height = (#state.video_tracks + #state.audio_tracks - 1) * state.track_height
        interaction.video_area_height = math.max(min_height, math.min(max_height, new_height))
        M.render()
    elseif interaction.drag_selecting then
        -- Don't allow drag-select to extend into ruler
        if y >= state.ruler_height then
            -- Update drag-select rectangle
            interaction.drag_select_end_x = x
            interaction.drag_select_end_y = y
            M.render()
        end
    elseif interaction.dragging_clip then
        -- Drag all selected clips together
        local delta_x = x - interaction.drag_start_x
        local delta_time = delta_x / state.zoom

        -- Find the minimum allowed delta to prevent any clip from going below 0
        local min_allowed_delta = delta_time
        for _, clip in ipairs(interaction.selected_clips) do
            local new_start = clip.start_time + delta_time
            if new_start < 0 then
                -- This clip would go negative, so constrain the delta
                min_allowed_delta = math.max(min_allowed_delta, -clip.start_time)
            end
        end

        -- Apply the constrained delta to all selected clips
        if min_allowed_delta ~= 0 then
            for _, clip in ipairs(interaction.selected_clips) do
                clip.start_time = clip.start_time + min_allowed_delta
            end
            -- Update drag start position to reflect constrained movement
            interaction.drag_start_x = interaction.drag_start_x + (min_allowed_delta * state.zoom)
            M.render()
        end
    end
end

-- Mouse release handler
function timeline_on_mouse_release(event)
    local x, y = event.x, event.y

    -- Complete clip drag - save clip positions
    if interaction.dragging_clip then
        for _, clip in ipairs(interaction.selected_clips) do
            -- Save clip position to database
            db.update_clip_position(clip.id, clip.start_time, clip.duration)
        end
    end

    -- Complete drag-select
    if interaction.drag_selecting then
        -- Find all clips in the selection rectangle
        for _, clip in ipairs(state.clips) do
            if is_clip_in_rect(clip, interaction.drag_select_start_x, interaction.drag_select_start_y,
                               interaction.drag_select_end_x, interaction.drag_select_end_y) then
                add_to_selection(clip)
            end
        end
        interaction.drag_selecting = false
        M.render()
    end

    interaction.dragging_playhead = false
    interaction.dragging_clip = nil
    interaction.dragging_separator = false
end

-- Qt key codes
local Qt_Key = {
    Key_Equal = 61,      -- =
    Key_Minus = 45,      -- -
    Key_Plus = 43,       -- +
    Key_A = 65,
    Key_B = 66,
    Key_Z = 90,
    -- F-keys: Qt::Key_F1 starts at 16777264, so F9 = 16777264 + 8 = 16777272
    Key_F9 = 16777272,   -- F9
    Key_F10 = 16777273,  -- F10
    Key_F12 = 16777275,  -- F12
}

-- Global keyboard event handler
function timeline_key_event(event)
    if event.type == "press" then
        print(string.format("⌨️  Key pressed: %d, ctrl=%s, shift=%s", event.key, tostring(event.ctrl), tostring(event.shift)))

        -- Check for F-keys explicitly (F1 = 16777264, so F9 = 16777272)
        if event.key >= 16777264 and event.key <= 16777275 then
            local f_num = event.key - 16777264 + 1
            print(string.format("  🔑 F-key detected: F%d (code %d)", f_num, event.key))
        end

        -- Zoom in: = or +
        if event.key == Qt_Key.Key_Equal or event.key == Qt_Key.Key_Plus then
            M.set_zoom(state.zoom * 1.5)
            return
        end

        -- Zoom out: -
        if event.key == Qt_Key.Key_Minus then
            M.set_zoom(state.zoom / 1.5)
            return
        end

        -- Cmd-A: Select all
        if event.key == Qt_Key.Key_A and event.ctrl and not event.shift then
            interaction.selected_clips = {}
            for _, clip in ipairs(state.clips) do
                table.insert(interaction.selected_clips, clip)
            end
            notify_selection_changed()
            M.render()
            return
        end

        -- Cmd-Shift-A: Deselect all
        if event.key == Qt_Key.Key_A and event.ctrl and event.shift then
            interaction.selected_clips = {}
            notify_selection_changed()
            M.render()
            return
        end

        -- Cmd-B: Split clip at playhead
        if event.key == Qt_Key.Key_B and event.ctrl then
            M.split_clips_at_playhead()
            return
        end

        -- Cmd-Z: Undo last command
        print(string.format("  Checking Cmd+Z: key=%d (Z=%d), ctrl=%s, shift=%s",
            event.key, Qt_Key.Key_Z, tostring(event.ctrl), tostring(event.shift)))
        if event.key == Qt_Key.Key_Z and event.ctrl and not event.shift then
            print(string.format("  Matched Cmd+Z! Key_Z=%d, event.key=%d", Qt_Key.Key_Z, event.key))

            local success, err = pcall(function()
                local project_id = db.get_current_project_id() or "default_project"
                print(string.format("  Project ID: %s", tostring(project_id)))
                local last_command = command_manager.get_last_command(project_id)
                print(string.format("  Last command: %s", tostring(last_command)))

                if last_command then
                    print(string.format("↶ Undoing last command: %s", last_command.type))
                    local result = command_manager.execute_undo(last_command)

                    if result.success then
                        print("  Undo successful!")
                        -- Reload clips from database
                        state.clips = db.load_clips("default_sequence")

                        -- Update selection to point to refreshed clip objects
                        local new_selection = {}
                        for _, old_clip in ipairs(interaction.selected_clips) do
                            for _, new_clip in ipairs(state.clips) do
                                if new_clip.id == old_clip.id then
                                    table.insert(new_selection, new_clip)
                                    break
                                end
                            end
                        end
                        interaction.selected_clips = new_selection

                        -- Refresh timeline display
                        M.render()
                    else
                        print(string.format("  Undo failed: %s", result.error_message or "unknown error"))
                    end
                else
                    print("  No command to undo")
                end
            end)

            if not success then
                print(string.format("  ERROR in undo handler: %s", tostring(err)))
            end
            return
        end

        -- F9: Insert media to VIDEO track at playhead
        if event.key == Qt_Key.Key_F9 then
            print("F9 pressed: Insert to video track")
            M.insert_media_to_timeline("VIDEO")
            return
        end

        -- F10: Insert media to AUDIO track at playhead
        if event.key == Qt_Key.Key_F10 then
            print("F10 pressed: Insert to audio track")
            M.insert_media_to_timeline("AUDIO")
            return
        end

        -- F12: Insert media to first available track (VIDEO preferred)
        if event.key == Qt_Key.Key_F12 then
            print("F12 pressed: Insert to first available track")
            -- Try video first, then audio
            if #state.tracks > 0 then
                for _, track in ipairs(state.tracks) do
                    if track.track_type == "VIDEO" then
                        M.insert_media_to_timeline("VIDEO")
                        return
                    end
                end
                -- No video track, try audio
                M.insert_media_to_timeline("AUDIO")
            else
                print("WARNING: No tracks available")
            end
            return
        end
    end
end

-- Split selected clips at playhead position
function M.split_clips_at_playhead()
    print("🔪 Split clips at playhead called!")
    print(string.format("  Playhead time: %d", state.playhead_time))
    print(string.format("  Selected clips: %d", #interaction.selected_clips))

    local playhead_time = state.playhead_time
    local commands_executed = 0

    -- Get project ID (assuming single project for now)
    local project_id = db.get_current_project_id() or "default_project"

    for _, clip in ipairs(interaction.selected_clips) do
        -- Check if playhead is within this clip
        if playhead_time > clip.start_time and playhead_time < clip.start_time + clip.duration then
            -- Create SplitClip command
            local split_command = Command.create("SplitClip", project_id)
            split_command:set_parameter("clip_id", clip.id)
            split_command:set_parameter("split_time", playhead_time)

            -- Execute the command
            local result = command_manager.execute(split_command)

            if result.success then
                print(string.format("Split clip %s at time %d", clip.id, playhead_time))
                commands_executed = commands_executed + 1
            else
                print(string.format("WARNING: Failed to split clip %s: %s", clip.id, result.error_message))
            end
        end
    end

    if commands_executed > 0 then
        -- Reload clips from database to reflect changes
        state.clips = db.load_clips("default_sequence")

        -- Update selection to reference the new clip objects from database
        -- Map old selection by clip ID to new clip objects
        local new_selection = {}
        for _, old_clip in ipairs(interaction.selected_clips) do
            for _, new_clip in ipairs(state.clips) do
                if new_clip.id == old_clip.id then
                    table.insert(new_selection, new_clip)
                    break
                end
            end
        end
        interaction.selected_clips = new_selection
        notify_selection_changed()

        M.render()
    end
end

-- Insert selected media from project browser to timeline at playhead
function M.insert_media_to_timeline(track_type)
    if not project_browser then
        print("WARNING: Project browser not set")
        return
    end

    local selected_media = project_browser.get_selected_media()
    if not selected_media then
        print("📎 No media selected in project browser")
        return
    end

    print(string.format("📎 Inserting media: %s (duration: %d ms)", selected_media.file_name, selected_media.duration))

    -- Find appropriate track
    local target_track = nil
    for _, track in ipairs(state.tracks) do
        if track.track_type == track_type then
            target_track = track
            break
        end
    end

    if not target_track then
        print(string.format("WARNING: No %s track found", track_type))
        return
    end

    -- Create InsertClipToTimeline command
    local project_id = db.get_current_project_id() or "default_project"
    local insert_command = Command.create("InsertClipToTimeline", project_id)
    insert_command:set_parameter("media_id", selected_media.id)
    insert_command:set_parameter("track_id", target_track.id)
    insert_command:set_parameter("start_time", state.playhead_time)
    insert_command:set_parameter("media_duration", selected_media.duration)

    -- Execute the command
    local result = command_manager.execute(insert_command)

    if result.success then
        print(string.format("✅ Inserted %s to %s track at playhead", selected_media.file_name, track_type))
        -- Reload clips from database
        state.clips = db.load_clips("default_sequence")
        M.render()
    else
        print(string.format("WARNING: Failed to insert media: %s", result.error_message or "unknown error"))
    end
end

return M
