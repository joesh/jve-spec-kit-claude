-- Timeline State Module
-- Centralized state management for multi-view timeline
-- Manages tracks, clips, playhead, viewport in logical (time-based) coordinates

local M = {}
local db = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local ui_constants = require("core.ui_constants")

-- State listeners (views register here for notifications)
local listeners = {}

-- Debouncing configuration
-- Batches rapid state changes to prevent excessive redraws
local notify_timer = nil
local NOTIFY_DEBOUNCE_MS = ui_constants.TIMELINE.NOTIFY_DEBOUNCE_MS

-- Project browser reference (for media insertion)
local project_browser = nil

-- Rubber band reference (for drag selection UI)
local rubber_band = nil

-- Callbacks
local on_selection_changed_callback = nil

-- Dimensions (shared across all views)
M.dimensions = {
    default_track_height = ui_constants.TIMELINE.TRACK_HEIGHT,
    track_height = ui_constants.TIMELINE.TRACK_HEIGHT,  -- Legacy field for unit tests expecting track_height
    track_header_width = ui_constants.TIMELINE.TRACK_HEADER_WIDTH,
    ruler_height = ui_constants.TIMELINE.RULER_HEIGHT,  -- Height of the timeline ruler in pixels
}

-- Version tracking for stale data detection
-- Incremented whenever clips or tracks are reloaded from database
local state_version = 0

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
    selected_edges = {},  -- Array of selected edge objects for trimming
                          -- Each edge: {clip_id, edge_type ("in"/"out"), trim_type ("ripple"/"roll")}

    -- Interaction state (for cross-view operations)
    dragging_playhead = false,
    dragging_clip = nil,
    drag_selecting = false,
    drag_select_start_time = 0,  -- in milliseconds
    drag_select_end_time = 0,
    drag_select_start_track_index = 0,  -- global track index
    drag_select_end_track_index = 0,
}

local function calculate_timeline_extent()
    local max_end = 0
    for _, clip in ipairs(state.clips) do
        local clip_end = clip.start_time + clip.duration
        if clip_end > max_end then
            max_end = clip_end
        end
    end

    if state.playhead_time and state.playhead_time > max_end then
        max_end = state.playhead_time
    end

    return math.max(60000, max_end + 10000)
end

local function clamp_viewport_start(desired_start, duration)
    local total_extent = calculate_timeline_extent()
    local max_start = math.max(0, total_extent - duration)
    if desired_start < 0 then
        return 0
    end
    if desired_start > max_start then
        return max_start
    end
    return desired_start
end

-- Debug layout capture (populated by views when rendering)
local debug_layouts = {}

local function compute_gap_after(clip)
    local clip_end = clip.start_time + clip.duration
    local min_gap = nil

    for _, other in ipairs(state.clips) do
        if other.track_id == clip.track_id and other.id ~= clip.id then
            if other.start_time >= clip_end then
                local gap = other.start_time - clip_end
                if gap <= 1 then
                    return 0
                end
                if not min_gap or gap < min_gap then
                    min_gap = gap
                end
            end
        end
    end

    return min_gap
end

local function compute_gap_before(clip)
    local clip_start = clip.start_time
    local min_gap = nil

    for _, other in ipairs(state.clips) do
        if other.track_id == clip.track_id and other.id ~= clip.id then
            local other_end = other.start_time + other.duration
            if other_end <= clip_start then
                local gap = clip_start - other_end
                if gap <= 1 then
                    return 0
                end
                if not min_gap or gap < min_gap then
                    min_gap = gap
                end
            end
        end
    end

    return min_gap
end

local function find_next_clip(clip)
    local clip_end = clip.start_time + clip.duration
    local closest = nil
    local closest_start = nil
    for _, other in ipairs(state.clips) do
        if other.track_id == clip.track_id and other.id ~= clip.id then
            if other.start_time >= clip_end then
                if not closest_start or other.start_time < closest_start then
                    closest = other
                    closest_start = other.start_time
                end
            end
        end
    end
    return closest
end

local function find_previous_clip(clip)
    local clip_start = clip.start_time
    local closest = nil
    local closest_end = nil
    for _, other in ipairs(state.clips) do
        if other.track_id == clip.track_id and other.id ~= clip.id then
            local other_end = other.start_time + other.duration
            if other_end <= clip_start then
                if not closest_end or other_end > closest_end then
                    closest = other
                    closest_end = other_end
                end
            end
        end
    end
    return closest
end

local function normalize_edge_selection()
    if not state.selected_edges or #state.selected_edges == 0 then
        return false
    end

    local normalized = {}
    local seen = {}
    local changed = false

    for _, edge in ipairs(state.selected_edges) do
        local clip = nil
        for _, candidate in ipairs(state.clips) do
            if candidate.id == edge.clip_id then
                clip = candidate
                break
            end
        end

        if clip then
            local new_edge_type = edge.edge_type
            local new_clip_id = clip.id
            if edge.edge_type == "gap_after" then
                local gap = compute_gap_after(clip)
                if gap and gap <= 0 then
                    local neighbour = find_next_clip(clip)
                    if neighbour then
                        new_clip_id = neighbour.id
                        new_edge_type = "in"
                    else
                        new_edge_type = "in"
                    end
                end
            elseif edge.edge_type == "gap_before" then
                local gap = compute_gap_before(clip)
                if gap and gap <= 0 then
                    local neighbour = find_previous_clip(clip)
                    if neighbour then
                        new_clip_id = neighbour.id
                        new_edge_type = "out"
                    else
                        new_edge_type = "out"
                    end
                end
            end

            local key = new_clip_id .. ":" .. new_edge_type
            if not seen[key] then
                table.insert(normalized, {
                    clip_id = new_clip_id,
                    edge_type = new_edge_type,
                    trim_type = edge.trim_type
                })
                seen[key] = true
            else
                changed = true
            end

            if new_edge_type ~= edge.edge_type then
                changed = true
            end
            if new_clip_id ~= edge.clip_id then
                changed = true
            end
        else
            changed = true
        end
    end

    if changed then
        state.selected_edges = normalized
    end

    return changed
end

function M.normalize_edge_selection()
    return normalize_edge_selection()
end

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
    edge_selected_available = "#66ff66",  -- Green for selected edge with available media
    edge_selected_limit = "#ff6666",      -- Red for selected edge at media limit
}

-- Listener notification helper (defined early so M.init can use it)
-- Batches rapid state changes to prevent excessive redraws (60fps throttle)
local function notify_listeners()
    if notify_timer then
        -- Timer already scheduled, will notify soon
        return
    end

    -- Create Qt timer to batch notifications
    notify_timer = qt_create_single_shot_timer(NOTIFY_DEBOUNCE_MS, function()
        notify_timer = nil

        -- Call all listeners
        for _, listener in ipairs(listeners) do
            listener()
        end
    end)
end

-- Initialize state from database
function M.init(sequence_id)
    sequence_id = sequence_id or "default_sequence"
    state.sequence_id = sequence_id  -- Store for reload

    -- Load data from database
    state.tracks = db.load_tracks(sequence_id)
    state.clips = db.load_clips(sequence_id)

    -- Load playhead and selection state from sequence
    local db_conn = db.get_connection()
    if db_conn then
        local query = db_conn:prepare("SELECT playhead_time, selected_clip_ids, selected_edge_infos FROM sequences WHERE id = ?")
        if query then
            query:bind_value(1, sequence_id)
            if query:exec() and query:next() then
                -- Restore playhead position
                local saved_playhead = query:value(0)
                if saved_playhead then
                    state.playhead_time = saved_playhead
                end

                -- Restore selection
                local saved_selection_json = query:value(1)
                if saved_selection_json and saved_selection_json ~= "" then
                    local success, selected_ids = pcall(qt_json_decode, saved_selection_json)
                    if success and type(selected_ids) == "table" then
                        -- Load clip objects for saved IDs
                        state.selected_clips = {}
                        for _, clip_id in ipairs(selected_ids) do
                            for _, clip in ipairs(state.clips) do
                                if clip.id == clip_id then
                                    table.insert(state.selected_clips, clip)
                                    break
                                end
                            end
                        end
                        if #state.selected_clips > 0 then
                            print(string.format("Restored playhead to %dms, selection: %d clips",
                                state.playhead_time, #state.selected_clips))
                        end
                    end
                end

                -- Restore edge selection
                local saved_edges_json = query:value(2)
                if saved_edges_json and saved_edges_json ~= "" then
                    local success_edges, edge_infos = pcall(qt_json_decode, saved_edges_json)
                    if success_edges and type(edge_infos) == "table" then
                        state.selected_edges = {}
                        for _, edge_info in ipairs(edge_infos) do
                            if type(edge_info) == "table" and edge_info.clip_id and edge_info.edge_type then
                                local clip_exists = false
                                for _, clip in ipairs(state.clips) do
                                    if clip.id == edge_info.clip_id then
                                        clip_exists = true
                                        break
                                    end
                                end

                                if clip_exists then
                                    table.insert(state.selected_edges, {
                                        clip_id = edge_info.clip_id,
                                        edge_type = edge_info.edge_type,
                                        trim_type = edge_info.trim_type
                                    })
                                end
                            end
                        end

                        if #state.selected_edges > 0 then
                            -- Edge selection is exclusive with clip selection
                            state.selected_clips = {}
                            print(string.format(
                                "Restored playhead to %dms, edge selection: %d edges",
                                state.playhead_time,
                                #state.selected_edges
                            ))
                        end
                    end
                end
            end
        end
    end

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

-- Reload clips from database (for after commands that modify database)
function M.reload_clips()
    local sequence_id = state.sequence_id or "default_sequence"
    state.clips = db.load_clips(sequence_id)

    -- Increment version and stamp all clips
    state_version = state_version + 1
    for _, clip in ipairs(state.clips) do
        clip._version = state_version
    end

    local selection_adjusted = normalize_edge_selection()
    print(string.format("Reloaded %d clips from database (version %d)", #state.clips, state_version))
    if selection_adjusted then
        M.persist_state_to_db()
    end
    notify_listeners()
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

function M.get_sequence_id()
    return state.sequence_id or "default_sequence"
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

-- Get all clips (WARNING: returned objects become stale after next reload_clips())
function M.get_clips()
    return state.clips
end

-- Get clip by ID (always returns fresh data from current state)
function M.get_clip_by_id(clip_id)
    for _, clip in ipairs(state.clips) do
        if clip.id == clip_id then
            return clip
        end
    end
    return nil
end

-- Validate that a clip object is still fresh (not stale)
-- Returns: success (bool), error_message (string or nil)
function M.validate_clip_fresh(clip)
    if not clip then
        return false, "Clip is nil"
    end
    if not clip._version then
        return false, "Clip has no version stamp (created before versioning enabled)"
    end
    if clip._version ~= state_version then
        return false, string.format("Stale clip data (clip version %d, current state version %d)",
            clip._version, state_version)
    end
    return true
end

-- Get current state version (for debugging)
function M.get_state_version()
    return state_version
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
    local clamped_start = clamp_viewport_start(time_ms, state.viewport_duration)
    if state.viewport_start_time ~= clamped_start then
        state.viewport_start_time = clamped_start
        notify_listeners()
    end
end

function M.set_viewport_duration(duration_ms)
    local new_duration = math.max(1000, duration_ms)
    if state.viewport_duration ~= new_duration then
        local playhead = state.playhead_time or (state.viewport_start_time + state.viewport_duration / 2)
        local desired_start = playhead - (new_duration / 2)
        local clamped_start = clamp_viewport_start(desired_start, new_duration)

        local changed = false

        if state.viewport_duration ~= new_duration then
            state.viewport_duration = new_duration
            changed = true
        end

        if state.viewport_start_time ~= clamped_start then
            state.viewport_start_time = clamped_start
            changed = true
        end

        if changed then
            notify_listeners()
        end
    end
end

function M.set_playhead_time(time_ms)
    if state.playhead_time ~= time_ms then
        state.playhead_time = math.max(0, time_ms)
        notify_listeners()

        -- Persist playhead position to database
        M.persist_state_to_db()

        -- Also notify selection callback if registered
        if on_selection_changed_callback then
            on_selection_changed_callback(state.selected_clips)
        end
    end
end

function M.set_selection(clips)
    state.selected_clips = clips or {}

    -- Clear edge selection (clips and edges are mutually exclusive)
    state.selected_edges = {}

    notify_listeners()

    -- Persist selection to database
    M.persist_state_to_db()

    if on_selection_changed_callback then
        on_selection_changed_callback(state.selected_clips)
    end
end

-- Edge selection functions (for trimming)
function M.get_selected_edges()
    return state.selected_edges
end

function M.set_edge_selection(edges)
    state.selected_edges = edges or {}

    -- Clear clip selection (clips and edges are mutually exclusive)
    state.selected_clips = {}

    normalize_edge_selection()

    notify_listeners()

    -- Persist edge selection to database
    M.persist_state_to_db()
end

function M.toggle_edge_selection(clip_id, edge_type, trim_type)
    -- Check if this edge is already selected
    for i, edge in ipairs(state.selected_edges) do
        if edge.clip_id == clip_id and edge.edge_type == edge_type then
            -- Remove it
            table.remove(state.selected_edges, i)
            normalize_edge_selection()
            notify_listeners()
            M.persist_state_to_db()
            return false  -- Deselected
        end
    end

    -- Clear clip selection when selecting first edge (clips and edges are mutually exclusive)
    if #state.selected_edges == 0 then
        state.selected_clips = {}
    end

    -- Add new edge
    table.insert(state.selected_edges, {
        clip_id = clip_id,
        edge_type = edge_type,
        trim_type = trim_type
    })

    normalize_edge_selection()

    notify_listeners()
    M.persist_state_to_db()
    return true  -- Selected
end

function M.clear_edge_selection()
    if #state.selected_edges > 0 then
        state.selected_edges = {}
        normalize_edge_selection()
        notify_listeners()
        M.persist_state_to_db()
    end
end

-- Selection callback (for inspector integration)
function M.set_on_selection_changed(callback)
    on_selection_changed_callback = callback

    -- Immediately notify the new callback of current selection state
    -- This ensures listeners that register after init() still get the current state
    if callback and #state.selected_clips > 0 then
        callback(state.selected_clips)
    end
end

-- Project browser reference
function M.set_project_browser(browser)
    project_browser = browser
end

function M.get_project_browser()
    return project_browser
end

-- Rubber band reference (for drag selection UI)
function M.set_rubber_band(band)
    rubber_band = band
end

function M.get_rubber_band()
    return rubber_band
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

-- Debug helpers for tests to query the most recent layout geometry
function M.debug_begin_layout_capture(view_id, viewport_width, viewport_height)
    if not view_id then
        return
    end

    debug_layouts[view_id] = {
        widget_width = viewport_width,
        widget_height = viewport_height,
        tracks = {},
        clips = {}
    }
end

function M.debug_record_track_layout(view_id, track_id, y, height)
    local layout = debug_layouts[view_id]
    if not layout then
        return
    end

    layout.tracks[track_id] = {
        y = y,
        height = height
    }
end

function M.debug_record_clip_layout(view_id, clip_id, track_id, x, y, width, height)
    local layout = debug_layouts[view_id]
    if not layout then
        return
    end

    layout.clips[clip_id] = {
        track_id = track_id,
        x = x,
        y = y,
        width = width,
        height = height
    }
end

function M.debug_get_clip_layout(view_id, clip_id)
    local layout = debug_layouts[view_id]
    if layout then
        return layout.clips[clip_id]
    end
    return nil
end

function M.debug_get_track_layout(view_id, track_id)
    local layout = debug_layouts[view_id]
    if layout then
        return layout.tracks[track_id]
    end
    return nil
end

function M.debug_get_layout_metrics(view_id)
    return debug_layouts[view_id]
end

-- Edge detection helper for trimming
-- Returns: edge_type ("in"/"out"), trim_type ("ripple"/"roll"), or nil if not near edge
function M.detect_edge_at_position(clip, click_x, viewport_width)
    local EDGE_ZONE_PX = ui_constants.TIMELINE.EDGE_ZONE_PX

    local clip_start_x = M.time_to_pixel(clip.start_time, viewport_width)
    local clip_end_x = M.time_to_pixel(clip.start_time + clip.duration, viewport_width)

    -- Check left edge (in point)
    if math.abs(click_x - clip_start_x) <= EDGE_ZONE_PX then
        return "in", "ripple"
    end

    -- Check right edge (out point)
    if math.abs(click_x - clip_end_x) <= EDGE_ZONE_PX then
        return "out", "ripple"
    end

    return nil, nil
end

-- Check if click is between two adjacent clips (for roll edit)
function M.detect_roll_between_clips(clip1, clip2, click_x, viewport_width)
    if not clip1 or not clip2 then return false end

    local ROLL_ZONE_PX = ui_constants.TIMELINE.ROLL_ZONE_PX
    local gap_start_x = M.time_to_pixel(clip1.start_time + clip1.duration, viewport_width)
    local gap_end_x = M.time_to_pixel(clip2.start_time, viewport_width)

    -- If clips are adjacent or close enough, check if click is near the edit point
    if gap_end_x - gap_start_x < ROLL_ZONE_PX then
        local edit_point_x = (gap_start_x + gap_end_x) / 2
        if math.abs(click_x - edit_point_x) <= ROLL_ZONE_PX / 2 then
            return true
        end
    end

    return false
end

-- Clip management - BLOCKED to enforce event sourcing discipline
-- All timeline modifications MUST go through command system for proper undo/redo

function M.add_clip(clip)
    error("timeline_state.add_clip() is blocked - use command system instead:\n" ..
          "  command_manager.execute(Command.create('AddClip', ...))\n" ..
          "This ensures proper undo/redo and prevents phantom state changes.")
end

function M.remove_clip(clip_id)
    error("timeline_state.remove_clip() is blocked - use command system instead:\n" ..
          "  command_manager.execute(Command.create('DeleteClip', ...))\n" ..
          "This ensures proper undo/redo and prevents phantom state changes.")
end

-- Internal helpers for command executors (bypass event sourcing check)
function M._internal_add_clip_from_command(clip)
    table.insert(state.clips, clip)
    notify_listeners()
end

function M._internal_remove_clip_from_command(clip_id)
    for i, clip in ipairs(state.clips) do
        if clip.id == clip_id then
            table.remove(state.clips, i)

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
    -- DISABLED: Direct clip modifications bypass the command system and break undo/redo
    -- All clip modifications must go through the command_manager to be logged in the event log
    error("Direct clip modification is not allowed. Use command_manager to execute a command instead.")
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

--- Persist playhead and selection state to sequences table (for session restoration)
function M.persist_state_to_db()
    local db_conn = db.get_connection()
    if not db_conn then
        return
    end

    local sequence_id = state.sequence_id or "default_sequence"

    -- Serialize selected clip IDs to JSON
    local selected_ids = {}
    for _, clip in ipairs(state.selected_clips) do
        table.insert(selected_ids, clip.id)
    end

    local success, json_str = pcall(qt_json_encode, selected_ids)
    if not success then
        json_str = "[]"
    end

    -- Serialize selected edge descriptors to JSON
    local edge_descriptors = {}
    for _, edge in ipairs(state.selected_edges) do
        if edge and edge.clip_id and edge.edge_type then
            table.insert(edge_descriptors, {
                clip_id = edge.clip_id,
                edge_type = edge.edge_type,
                trim_type = edge.trim_type
            })
        end
    end

    local success_edges, edges_json = pcall(qt_json_encode, edge_descriptors)
    if not success_edges then
        edges_json = "[]"
    end

    -- Update sequences table with current state
    local query = db_conn:prepare([[
        UPDATE sequences
        SET playhead_time = ?, selected_clip_ids = ?, selected_edge_infos = ?
        WHERE id = ?
    ]])

    if query then
        query:bind_value(1, state.playhead_time)
        query:bind_value(2, json_str)
        query:bind_value(3, edges_json)
        query:bind_value(4, sequence_id)
        query:exec()
    end
end

return M
