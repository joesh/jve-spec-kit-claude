-- Timeline State Module
-- Centralized state management for multi-view timeline
-- Manages tracks, clips, playhead, viewport in logical (time-based) coordinates

local M = {}
local db = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")

-- State listeners (views register here for notifications)
local listeners = {}

-- Project browser reference (for media insertion)
local project_browser = nil

-- Callbacks
local on_selection_changed_callback = nil

-- Dimensions (shared across all views)
M.dimensions = {
    default_track_height = 50,  -- Default height for new tracks
    track_header_width = 150,
}

-- Centralized state
local state = {
    -- Data
    tracks = {},  -- All tracks from database
    clips = {},   -- All clips from database

    -- Logical viewport (time-based, not pixel-based)
    viewport_start_time = 0,     -- milliseconds - left edge of visible area
    viewport_duration = 10000,   -- milliseconds - how much time is visible

    -- Playhead
    playhead_time = 0,  -- milliseconds

    -- Selection
    selected_clips = {},  -- Array of selected clip objects

    -- Interaction state (for cross-view operations)
    dragging_playhead = false,
    dragging_clip = nil,
    drag_selecting = false,
    drag_select_start_time = 0,  -- in milliseconds
    drag_select_end_time = 0,
    drag_select_start_track_index = 0,  -- global track index
    drag_select_end_track_index = 0,
}

-- Colors (shared visual style)
M.colors = {
    background = "#232323",
    track_odd = "#2b2b2b",
    track_even = "#252525",
    video_track_header = "#3a3a5a",
    audio_track_header = "#3a4a3a",
    clip = "#4a90e2",
    clip_selected = "#ff8c42",
    playhead = "#ff6b6b",
    text = "#cccccc",
    grid_line = "#3a3a3a",
    selection_box = "#ff8c42",
}

-- Listener notification helper (defined early so M.init can use it)
local function notify_listeners()
    for _, listener in ipairs(listeners) do
        listener()
    end
end

-- Initialize state from database
function M.init(sequence_id)
    sequence_id = sequence_id or "default_sequence"

    -- Load data from database
    state.tracks = db.load_tracks(sequence_id)
    state.clips = db.load_clips(sequence_id)

    -- Initialize track heights to default
    for _, track in ipairs(state.tracks) do
        track.height = M.dimensions.default_track_height
    end

    print(string.format("Timeline state initialized: %d tracks, %d clips",
        #state.tracks, #state.clips))

    -- Calculate initial viewport duration based on content
    local max_clip_end = 0
    for _, clip in ipairs(state.clips) do
        local clip_end = clip.start_time + clip.duration
        if clip_end > max_clip_end then
            max_clip_end = clip_end
        end
    end

    -- Show at least 10 seconds, or enough to see all content
    state.viewport_duration = math.max(10000, max_clip_end * 1.2)

    notify_listeners()
    return true
end

-- Listener management
function M.add_listener(callback)
    table.insert(listeners, callback)
end

function M.remove_listener(callback)
    for i, listener in ipairs(listeners) do
        if listener == callback then
            table.remove(listeners, i)
            return
        end
    end
end

-- Getters
function M.get_all_tracks()
    return state.tracks
end

function M.get_video_tracks()
    local video_tracks = {}
    for _, track in ipairs(state.tracks) do
        if track.track_type == "VIDEO" then
            table.insert(video_tracks, track)
        end
    end
    return video_tracks
end

function M.get_audio_tracks()
    local audio_tracks = {}
    for _, track in ipairs(state.tracks) do
        if track.track_type == "AUDIO" then
            table.insert(audio_tracks, track)
        end
    end
    return audio_tracks
end

function M.get_clips()
    return state.clips
end

function M.get_viewport_start_time()
    return state.viewport_start_time
end

function M.get_viewport_duration()
    return state.viewport_duration
end

function M.get_viewport_end_time()
    return state.viewport_start_time + state.viewport_duration
end

function M.get_playhead_time()
    return state.playhead_time
end

function M.get_selected_clips()
    return state.selected_clips
end

-- Setters (with notification)
function M.set_viewport_start_time(time_ms)
    if state.viewport_start_time ~= time_ms then
        state.viewport_start_time = math.max(0, time_ms)
        notify_listeners()
    end
end

function M.set_viewport_duration(duration_ms)
    if state.viewport_duration ~= duration_ms then
        state.viewport_duration = math.max(1000, duration_ms)  -- Min 1 second
        notify_listeners()
    end
end

function M.set_playhead_time(time_ms)
    if state.playhead_time ~= time_ms then
        state.playhead_time = math.max(0, time_ms)
        notify_listeners()

        -- Also notify selection callback if registered
        if on_selection_changed_callback then
            on_selection_changed_callback(state.selected_clips)
        end
    end
end

function M.set_selection(clips)
    state.selected_clips = clips or {}
    notify_listeners()

    if on_selection_changed_callback then
        on_selection_changed_callback(state.selected_clips)
    end
end

-- Selection callback (for inspector integration)
function M.set_on_selection_changed(callback)
    on_selection_changed_callback = callback
end

-- Project browser reference
function M.set_project_browser(browser)
    project_browser = browser
end

function M.get_project_browser()
    return project_browser
end

-- Coordinate conversion helpers
-- These convert between time and pixel coordinates for a given viewport width
function M.time_to_pixel(time_ms, viewport_width)
    local pixels_per_ms = viewport_width / state.viewport_duration
    return math.floor((time_ms - state.viewport_start_time) * pixels_per_ms)
end

function M.pixel_to_time(pixel, viewport_width)
    local pixels_per_ms = viewport_width / state.viewport_duration
    return math.floor(state.viewport_start_time + (pixel / pixels_per_ms))
end

-- Clip management
function M.add_clip(clip)
    table.insert(state.clips, clip)

    -- Save to database
    db.save_clip(clip)

    notify_listeners()
end

function M.remove_clip(clip_id)
    for i, clip in ipairs(state.clips) do
        if clip.id == clip_id then
            table.remove(state.clips, i)

            -- Remove from database
            db.delete_clip(clip_id)

            -- Remove from selection if selected
            for j, selected in ipairs(state.selected_clips) do
                if selected.id == clip_id then
                    table.remove(state.selected_clips, j)
                    break
                end
            end

            notify_listeners()
            return
        end
    end
end

function M.update_clip(clip_id, updates)
    for i, clip in ipairs(state.clips) do
        if clip.id == clip_id then
            -- Apply updates
            for key, value in pairs(updates) do
                clip[key] = value
            end

            -- Save to database
            db.update_clip(clip)

            notify_listeners()
            return clip
        end
    end
end

-- Find track by ID
function M.get_track_by_id(track_id)
    for _, track in ipairs(state.tracks) do
        if track.id == track_id then
            return track
        end
    end
    return nil
end

-- Get global track index (for selection operations)
function M.get_track_index(track_id)
    for i, track in ipairs(state.tracks) do
        if track.id == track_id then
            return i - 1  -- 0-based index
        end
    end
    return -1
end

-- Get track height by track ID
function M.get_track_height(track_id)
    for _, track in ipairs(state.tracks) do
        if track.id == track_id then
            return track.height or M.dimensions.default_track_height
        end
    end
    return M.dimensions.default_track_height
end

-- Set track height by track ID
function M.set_track_height(track_id, height)
    for _, track in ipairs(state.tracks) do
        if track.id == track_id then
            track.height = height
            notify_listeners()
            return true
        end
    end
    return false
end

-- Interaction state management
function M.is_dragging_playhead()
    return state.dragging_playhead
end

function M.set_dragging_playhead(dragging)
    state.dragging_playhead = dragging
end

function M.get_dragging_clip()
    return state.dragging_clip
end

function M.set_dragging_clip(clip)
    state.dragging_clip = clip
end

function M.is_drag_selecting()
    return state.drag_selecting
end

function M.set_drag_selecting(selecting)
    state.drag_selecting = selecting
end

function M.get_drag_selection_bounds()
    return {
        start_time = state.drag_select_start_time,
        end_time = state.drag_select_end_time,
        start_track = state.drag_select_start_track_index,
        end_track = state.drag_select_end_track_index,
    }
end

function M.set_drag_selection_bounds(start_time, end_time, start_track, end_track)
    state.drag_select_start_time = start_time
    state.drag_select_end_time = end_time
    state.drag_select_start_track_index = start_track
    state.drag_select_end_track_index = end_track
    notify_listeners()
end

return M
