-- Timeline State Module
-- Centralized state management for multi-view timeline
-- Manages tracks, clips, playhead, viewport in logical (time-based) coordinates

local M = {}
local db = require("core.database")
-- local command_manager = require("core.command_manager") -- Removed to break circular dependency
local Command = require("command")
local ui_constants = require("core.ui_constants")
local profile_scope = require("core.profile_scope")
local krono_ok, krono = pcall(require, "core.krono")
local json = require("dkjson")
local Rational = require("core.rational")

local TRACK_HEIGHT_TEMPLATE_KEY = "track_height_template"
local track_layout_dirty = false
local track_template_dirty = false
local last_mutation_failure = nil

local function record_mutation_failure(kind, context)
    last_mutation_failure = {
        kind = kind,
        context = context,
        stack = debug.traceback("", 3),
        timestamp = os.time()
    }
end

-- State listeners (views register here for notifications)
local listeners = {}

-- Debouncing configuration
-- Batches rapid state changes to prevent excessive redraws
local notify_timer = nil
local notify_profile_seq = 0
local NOTIFY_DEBOUNCE_MS = ui_constants.TIMELINE.NOTIFY_DEBOUNCE_MS
local PERSIST_DEBOUNCE_MS = ui_constants.TIMELINE.PERSIST_DEBOUNCE_MS or 75

local persist_timer = nil
local persist_dirty = false

-- Project browser reference (for media insertion)
local project_browser = nil

-- Rubber band reference (for drag selection UI)
local rubber_band = nil

-- Callbacks
local on_selection_changed_callback = nil

-- Dimensions (shared across all views)
M.dimensions = {
    default_track_height = ui_constants.TIMELINE.TRACK_HEIGHT or 50,
    track_height = ui_constants.TIMELINE.TRACK_HEIGHT or 50,  -- Legacy field for unit tests expecting track_height
    track_header_width = ui_constants.TIMELINE.TRACK_HEADER_WIDTH,
    ruler_height = ui_constants.TIMELINE.RULER_HEIGHT,  -- Height of the timeline ruler in pixels
}

-- Version tracking for stale data detection
-- Incremented whenever clips or tracks are reloaded from database
local state_version = 0

local function fresh_state()
    return {
        -- Data
        tracks = {},  -- All tracks from database
        clips = {},   -- All clips from database
        project_id = "default_project",
        
        -- Rate is now a table { fps_numerator, fps_denominator }
        sequence_frame_rate = { fps_numerator = 30, fps_denominator = 1 },
        sequence_audio_rate = 48000,
        sequence_timecode_start_frame = 0,

        -- Logical viewport (Rational Time)
        -- Defaults: Start at 0, Duration 10 seconds (300 frames @ 30fps)
        viewport_start_time = Rational.new(0, 1, 1),
        viewport_duration = Rational.new(300, 1, 1), 

        -- Playhead (Rational Time)
        playhead_position = Rational.new(0, 1, 1),

        -- Selection
        selected_clips = {},  -- Array of selected clip objects
        selected_edges = {},  -- Array of selected edge objects for trimming
                              -- Each edge: {clip_id, edge_type ("in"/"out"), trim_type ("ripple"/"roll")}
        selected_gaps = {},   -- Array of selected gap descriptors {track_id, start_value, duration_value}
        mark_in_value = nil,   -- Mark In point in Rational (nil when unset)
        mark_out_value = nil,  -- Mark Out point in Rational (nil when unset)

        -- Interaction state (for cross-view operations)
        dragging_playhead = false,
        dragging_clip = nil,
        drag_selecting = false,
        drag_select_start_value = 0,  -- in milliseconds
        drag_select_end_time = 0,
        drag_select_start_track_index = 0,  -- global track index
        drag_select_end_track_index = 0,
    }
end

-- Centralized state
local state = fresh_state()

-- Accelerated lookup tables for clips/tracks
local clip_lookup = {}
local track_clip_index = {}
local clip_track_positions = {}
local clip_indexes_dirty = true

-- Qt timer bridge (falls back to immediate execution for headless tests)
local function create_single_shot_timer(delay_ms, callback)
    if type(qt_create_single_shot_timer) == "function" then
        return qt_create_single_shot_timer(delay_ms, callback)
    end
    -- Headless mode: execute immediately
    callback()
    return nil
end

-- Reset in-memory state (used by isolated tests)
function M.reset()
    state = fresh_state()
    state_version = 0
    track_layout_dirty = false
    track_template_dirty = false
    last_mutation_failure = nil
    listeners = {}
    notify_timer = nil
    notify_profile_seq = 0
    persist_timer = nil
    persist_dirty = false
    project_browser = nil
    rubber_band = nil
    on_selection_changed_callback = nil
    clip_lookup = {}
    track_clip_index = {}
    clip_track_positions = {}
    clip_indexes_dirty = true
end

local function invalidate_clip_indexes()
    clip_indexes_dirty = true
end

local function rebuild_clip_indexes()
    clip_lookup = {}
    track_clip_index = {}
    clip_track_positions = {}

    for _, clip in ipairs(state.clips) do
        if clip.id then
            clip_lookup[clip.id] = clip
        end
        if clip.track_id then
            local list = track_clip_index[clip.track_id]
            if not list then
                list = {}
                track_clip_index[clip.track_id] = list
            end
            table.insert(list, clip)
        end
    end

    for _, list in pairs(track_clip_index) do
        table.sort(list, function(a, b)
            local a_start = a.timeline_start.frames or 0
            local b_start = b.timeline_start.frames or 0
            if a_start == b_start then
                return (a.id or "") < (b.id or "")
            end
            return a_start < b_start
        end)
        for index, clip in ipairs(list) do
            if clip.id then
                clip_track_positions[clip.id] = {list = list, index = index}
            end
        end
    end

    clip_indexes_dirty = false
end

local function hydrate_clip_from_database(clip_id, expected_sequence_id)
    if not clip_id or not db or not db.load_clip_entry then
        return nil
    end
    local ok, clip = pcall(db.load_clip_entry, clip_id)
    if not ok then
        return nil
    end
    if not clip then
        return nil
    end

    local target_sequence = expected_sequence_id or state.sequence_id
    if target_sequence and clip.track_sequence_id and clip.track_sequence_id ~= target_sequence then
        return nil
    end

    clip._version = state_version
    table.insert(state.clips, clip)
    invalidate_clip_indexes()
    -- print(string.format("timeline_state: Hydrated missing clip %s from database", tostring(clip_id)))
    return clip
end

local function clone_clip_snapshot(clip)
    if not clip then
        return nil
    end
    return {
        id = clip.id,
        track_id = clip.track_id,
        owner_sequence_id = clip.owner_sequence_id,
        track_sequence_id = clip.track_sequence_id,
        media_id = clip.media_id,
        timeline_start = clip.timeline_start,
        duration = clip.duration,
        source_in = clip.source_in,
        source_out = clip.source_out,
        enabled = clip.enabled
    }
end

local function ensure_clip_indexes()
    if clip_indexes_dirty then
        rebuild_clip_indexes()
    end
end

local function lookup_clip(clip_id)
    if not clip_id then
        return nil
    end
    ensure_clip_indexes()
    return clip_lookup[clip_id]
end

local function locate_neighbor(clip, offset)
    if not clip or not clip.id then
        return nil
    end
    ensure_clip_indexes()
    local info = clip_track_positions[clip.id]
    if not info then
        return nil
    end
    local neighbor_index = info.index + offset
    if neighbor_index < 1 or neighbor_index > #info.list then
        return nil
    end
    return info.list[neighbor_index]
end

local viewport_guard_count = 0

local function clamp_track_height(height)
    if type(height) ~= "number" then
        return nil
    end
    local clamped = math.floor(height)
    if clamped < 24 then
        clamped = 24
    end
    return clamped
end

local function apply_saved_track_heights(saved_map)
    if type(saved_map) ~= "table" then
        return false
    end

    local applied = false
    for _, track in ipairs(state.tracks) do
        local stored = saved_map[track.id]
        local normalized = clamp_track_height(stored)
        if normalized then
            track.height = normalized
            applied = true
        end
    end
    return applied
end

local function build_track_height_map()
    local result = {}
    for _, track in ipairs(state.tracks) do
        if track.id and track.id ~= "" then
            result[track.id] = clamp_track_height(track.height or M.dimensions.default_track_height)
        end
    end
    return result
end

local function build_track_height_template()
    if not state.tracks or #state.tracks == 0 then
        return nil
    end

    local template = {
        video = {},
        audio = {}
    }

    for _, track in ipairs(state.tracks) do
        local normalized = clamp_track_height(track.height or M.dimensions.default_track_height)
        if track.track_type == "VIDEO" then
            table.insert(template.video, normalized)
        elseif track.track_type == "AUDIO" then
            table.insert(template.audio, normalized)
        end
    end

    return template
end

local function compute_sequence_content_length()
    local max_end_rational = Rational.new(0, state.sequence_frame_rate.fps_numerator, state.sequence_frame_rate.fps_denominator)
    for _, clip in ipairs(state.clips) do
        if getmetatable(clip.timeline_start) == Rational.metatable and getmetatable(clip.duration) == Rational.metatable then
            local clip_end = clip.timeline_start + clip.duration
            if clip_end > max_end_rational then
                max_end_rational = clip_end
            end
        end
    end
    return max_end_rational
end

local function calculate_timeline_extent()
    local content_end_rational = compute_sequence_content_length()
    local max_end_rational = content_end_rational

    -- Default rate for constants
    local seq_fps = M.get_sequence_frame_rate()
    local default_fps_num = seq_fps.fps_numerator
    local default_fps_den = seq_fps.fps_denominator

    if state.playhead_position > max_end_rational then
        max_end_rational = state.playhead_position
    end

    if state.viewport_start_time and state.viewport_duration then
        local viewport_end = state.viewport_start_time + state.viewport_duration
        if viewport_end > max_end_rational then
            max_end_rational = viewport_end
        end
    end

    -- Add some buffer, ensuring it's Rational
    local buffer_rational = Rational.new(10000, default_fps_num, default_fps_den) -- 10000 frames buffer
    local min_extent_rational = Rational.new(60000, default_fps_num, default_fps_den) -- min 60000 frames extent

    return Rational.max(min_extent_rational, max_end_rational + buffer_rational)
end

local function clamp_viewport_start(desired_start_rational, duration_rational)
    local total_extent_rational = calculate_timeline_extent()

    -- Calculate max_start_rational, ensuring it doesn't go below 0
    local zero_rational = Rational.new(0, desired_start_rational.fps_numerator, desired_start_rational.fps_denominator)
    local max_start_rational = Rational.max(zero_rational, total_extent_rational - duration_rational)

    if desired_start_rational < zero_rational then
        return zero_rational
    end
    if desired_start_rational > max_start_rational then
        return max_start_rational
    end
    return desired_start_rational
end

local function ensure_playhead_visible()
    if viewport_guard_count > 0 then
        return false
    end

    local viewport_duration_rational = state.viewport_duration
    if not viewport_duration_rational or viewport_duration_rational.frames <= 0 then
        return false
    end

    local viewport_start_rational = state.viewport_start_time
    local viewport_end_rational = viewport_start_rational + viewport_duration_rational
    local playhead_position_rational = state.playhead_position or Rational.new(0, viewport_duration_rational.fps_numerator, viewport_duration_rational.fps_denominator)

    local changed = false
    if playhead_position_rational < viewport_start_rational or playhead_position_rational > viewport_end_rational then
        -- Center playhead in viewport
        local desired_start = playhead_position_rational - (viewport_duration_rational / 2)
        local clamped_start = clamp_viewport_start(desired_start, viewport_duration_rational)
        
        if state.viewport_start_time ~= clamped_start then
            state.viewport_start_time = clamped_start
            changed = true
        end
    end
    
    if changed then
        notify_listeners()
        M.persist_state_to_db()
    end
    return changed
end

-- Debug layout capture (populated by views when rendering)
local debug_layouts = {}

local function compute_gap_after(clip)
    if not clip then
        return nil
    end
    local next_clip = locate_neighbor(clip, 1)
    if not next_clip then
        return nil
    end
    local clip_end = clip.timeline_start + clip.duration
    local gap = next_clip.timeline_start - clip_end
    if gap.frames <= 1 then
        return Rational.new(0, gap.fps_numerator, gap.fps_denominator)
    end
    return gap
end

local function compute_gap_before(clip)
    if not clip then
        return nil
    end
    local prev_clip = locate_neighbor(clip, -1)
    if not prev_clip then
        return nil
    end
    local clip_start = clip.timeline_start
    local prev_end = prev_clip.timeline_start + prev_clip.duration
    local gap = clip_start - prev_end
    if gap.frames <= 1 then
        return Rational.new(0, gap.fps_numerator, gap.fps_denominator)
    end
    return gap
end

local function find_next_clip(clip)
    return locate_neighbor(clip, 1)
end

local function find_previous_clip(clip)
    return locate_neighbor(clip, -1)
end

local function normalize_edge_selection()
    if not state.selected_edges or #state.selected_edges == 0 then
        return false
    end

    local normalized = {}
    local seen = {}
    local changed = false

    ensure_clip_indexes()
    for _, edge in ipairs(state.selected_edges) do
        local clip = lookup_clip(edge.clip_id)

        if clip then
            local new_edge_type = edge.edge_type
            local new_clip_id = clip.id
            if edge.edge_type == "gap_after" then
                local gap = compute_gap_after(clip)
                if gap and gap.frames <= 0 then
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
                if gap and gap.frames <= 0 then
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
    video_track_header = "#1d1d1f",
    audio_track_header = "#1d1d1f",
    clip = "#548bb5",
    clip_video = "#548bb5",
    clip_audio = "#32986b",
    clip_audio_disabled = "#555555",
    clip_video_disabled = "#555555",
    clip_selected = "#ff8c42",
    clip_disabled = "#3f7fcc",
    clip_disabled_text = "#c3d6ff",
    clip_boundary = "#232323",
    gap_selected_fill = "#ff8c42",
    gap_selected_outline = "#ff8c42",
    mark_range_fill = "#19dfeeff",
    mark_range_edge = "#ff6b6b",
    playhead = "#ff6b6b",
    text = "#cccccc",
    grid_line = "#3a3a3a",
    selection_box = "#ff8c42",
    edge_selected_available = "#66ff66",  -- Green for selected edge with available media
    edge_selected_limit = "#ff6666",      -- Red for selected edge at media limit
}

-- Listener notification helper
local function notify_listeners()
    if notify_timer then
        return
    end

    -- Create Qt timer to batch notifications
    notify_timer = create_single_shot_timer(NOTIFY_DEBOUNCE_MS, function()
        notify_timer = nil
        for index, listener in ipairs(listeners) do
            listener()
        end
    end)
end

-- Initialize state from database
function M.init(sequence_id)
    if track_layout_dirty or track_template_dirty then
        M.persist_state_to_db(true)
    end

    sequence_id = sequence_id or "default_sequence"
    state.sequence_id = sequence_id  -- Store for reload

    -- Load data from database
    state.tracks = db.load_tracks(sequence_id)
    track_layout_dirty = false
    track_template_dirty = false
    state.clips = db.load_clips(sequence_id)
    invalidate_clip_indexes()
    ensure_clip_indexes()

    -- Load playhead and selection state from sequence
    local db_conn = db.get_connection()
    if db_conn then
        local project_stmt = db_conn:prepare("SELECT project_id FROM sequences WHERE id = ?")
        if project_stmt then
            project_stmt:bind_value(1, sequence_id)
            if project_stmt:exec() and project_stmt:next() then
                local seq_project = project_stmt:value(0)
                if seq_project and seq_project ~= "" then
                    state.project_id = seq_project
                else
                    state.project_id = "default_project"
                end
            end
            project_stmt:finalize()
        end

        local query = db_conn:prepare("SELECT playhead_frame, selected_clip_ids, selected_edge_infos, view_start_frame, view_duration_frames, fps_numerator, fps_denominator, mark_in_frame, mark_out_frame FROM sequences WHERE id = ?")
        if query then
            query:bind_value(1, sequence_id)
            if query:exec() and query:next() then
                -- Load Rate
                local fps_num = query:value(5) or 30
                local fps_den = query:value(6) or 1
                state.sequence_frame_rate = { fps_numerator = fps_num, fps_denominator = fps_den }

                -- Unconditionally rescale existing Rational objects in state to the loaded sequence rate
                if state.playhead_position then state.playhead_position = state.playhead_position:rescale(fps_num, fps_den) end
                if state.viewport_start_time then state.viewport_start_time = state.viewport_start_time:rescale(fps_num, fps_den) end
                if state.viewport_duration then state.viewport_duration = state.viewport_duration:rescale(fps_num, fps_den) end
                if state.mark_in_value then state.mark_in_value = state.mark_in_value:rescale(fps_num, fps_den) end
                if state.mark_out_value then state.mark_out_value = state.mark_out_value:rescale(fps_num, fps_den) end

                -- Restore playhead position (Rational)
                local saved_playhead_frame = query:value(0)
                if saved_playhead_frame then
                    state.playhead_position = Rational.new(saved_playhead_frame, fps_num, fps_den)
                else
                    state.playhead_position = Rational.new(0, fps_num, fps_den)
                end

                -- Restore selection
                local saved_selection_json = query:value(1)
                if saved_selection_json and saved_selection_json ~= "" then
                    local success, selected_ids = pcall(json.decode, saved_selection_json)
                    if success and type(selected_ids) == "table" then
                        state.selected_clips = {}
                        for _, clip_id in ipairs(selected_ids) do
                            local clip = lookup_clip(clip_id)
                            if clip then
                                table.insert(state.selected_clips, clip)
                            end
                        end
                    end
                end

                -- Restore edge selection
                local saved_edges_json = query:value(2)
                if saved_edges_json and saved_edges_json ~= "" then
                    local success_edges, edge_infos = pcall(json.decode, saved_edges_json)
                    if success_edges and type(edge_infos) == "table" then
                        state.selected_edges = {}
                        for _, edge_info in ipairs(edge_infos) do
                            if type(edge_info) == "table" and edge_info.clip_id and edge_info.edge_type then
                                if lookup_clip(edge_info.clip_id) then
                                    table.insert(state.selected_edges, {
                                        clip_id = edge_info.clip_id,
                                        edge_type = edge_info.edge_type,
                                        trim_type = edge_info.trim_type
                                    })
                                end
                            end
                        end
                        if #state.selected_edges > 0 then
                            state.selected_clips = {}
                        end
                    end
                end

                -- Marks (Rational)
                local saved_mark_in = query:value(7)
                if saved_mark_in ~= nil then
                    state.mark_in_value = Rational.new(saved_mark_in, fps_num, fps_den)
                else
                    state.mark_in_value = nil
                end

                local saved_mark_out = query:value(8)
                if saved_mark_out ~= nil then
                    state.mark_out_value = Rational.new(saved_mark_out, fps_num, fps_den)
                else
                    state.mark_out_value = nil
                end

                -- Viewport (Rational)
                local saved_view_start = query:value(3)
                local saved_view_dur = query:value(4)
                
                if saved_view_start then
                    state.viewport_start_time = Rational.new(saved_view_start, fps_num, fps_den)
                else
                    state.viewport_start_time = Rational.new(0, fps_num, fps_den)
                end
                
                if saved_view_dur and saved_view_dur > 0 then
                    state.viewport_duration = Rational.new(saved_view_dur, fps_num, fps_den)
                else
                    -- Default 10 seconds duration
                    state.viewport_duration = Rational.new(300, fps_num, fps_den) 
                end
            end
            query:finalize()
        end
    end

    -- Initialize track heights to default first, then override with persisted state/template
    for _, track in ipairs(state.tracks) do
        track.height = M.dimensions.default_track_height
    end

    local restored_track_layout = false
    if db.load_sequence_track_heights then
        local saved_heights = db.load_sequence_track_heights(sequence_id)
        local has_saved_layout = type(saved_heights) == "table" and next(saved_heights) ~= nil
        restored_track_layout = apply_saved_track_heights(saved_heights)
        if not has_saved_layout and db.set_sequence_track_heights then
            db.set_sequence_track_heights(sequence_id, build_track_height_map())
        end
    end

    print(string.format("Timeline state initialized: %d tracks, %d clips",
        #state.tracks, #state.clips))

    -- Calculate initial viewport duration based on content
    local max_clip_end_rat = Rational.new(0, 30, 1)
    if state.sequence_frame_rate then
        max_clip_end_rat = Rational.new(0, state.sequence_frame_rate.fps_numerator, state.sequence_frame_rate.fps_denominator)
    end

    for _, clip in ipairs(state.clips) do
        if clip.timeline_start and clip.duration then
            local clip_end = clip.timeline_start + clip.duration
            if clip_end > max_clip_end_rat then
                max_clip_end_rat = clip_end
            end
        end
    end

    local restored_viewport = state._restored_viewport
    state._restored_viewport = nil

    if not restored_viewport then
        -- Show at least 10 seconds, or enough to see all content
        local min_dur = Rational.new(300, max_clip_end_rat.fps_numerator, max_clip_end_rat.fps_denominator) -- 10s approx
        
        -- 1.2x content
        -- Approximate by adding 20% frames
        local content_plus_buffer = max_clip_end_rat + Rational.new(math.floor(max_clip_end_rat.frames * 0.2), max_clip_end_rat.fps_numerator, max_clip_end_rat.fps_denominator)
        
        if content_plus_buffer > min_dur then
            state.viewport_duration = content_plus_buffer
        else
            state.viewport_duration = min_dur
        end
    end

    notify_listeners()
    return true
end

-- Reload clips from database (for after commands that modify database)
function M.reload_clips(target_sequence_id, opts)
    local active_sequence = state.sequence_id
    if not active_sequence or active_sequence == "" then
        local fallback = target_sequence_id or "default_sequence"
        return M.init(fallback)
    end

    if target_sequence_id and target_sequence_id ~= "" and target_sequence_id ~= active_sequence then
        if opts and opts.allow_sequence_switch then
            return M.init(target_sequence_id)
        end
        return false
    end

    local sequence_id = active_sequence
    local selected_before = state.selected_clips and #state.selected_clips or 0
    state.clips = db.load_clips(sequence_id)
    invalidate_clip_indexes()
    ensure_clip_indexes()

    if state.selected_clips and #state.selected_clips > 0 then
        local refreshed = {}
        for _, clip in ipairs(state.selected_clips) do
            local latest = lookup_clip(clip.id)
            if latest then
                table.insert(refreshed, latest)
            end
        end
        state.selected_clips = refreshed
        if on_selection_changed_callback then
            on_selection_changed_callback(state.selected_clips)
        end
    end
    
    -- Increment version and stamp all clips
    state_version = state_version + 1
    for _, clip in ipairs(state.clips) do
        clip._version = state_version
    end

    local selection_adjusted = normalize_edge_selection()
    -- print(string.format("Reloaded %d clips from database (version %d)", #state.clips, state_version))
    if selection_adjusted then
        M.persist_state_to_db()
    end
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

function M.get_project_id()
    return state.project_id or "default_project"
end

function M.get_sequence_id()
    return state.sequence_id or "default_sequence"
end

function M.get_sequence_frame_rate()
    if not state.sequence_frame_rate or type(state.sequence_frame_rate) ~= "table" or 
       state.sequence_frame_rate.fps_numerator == nil or state.sequence_frame_rate.fps_numerator <= 0 then
        -- Return a default rate if not properly set, ensuring it's always valid
        state.sequence_frame_rate = { fps_numerator = 30, fps_denominator = 1 }
    end
    return state.sequence_frame_rate
end

function M.get_sequence_fps_numerator()
    local seq_fps = M.get_sequence_frame_rate()
    return seq_fps.fps_numerator
end

function M.get_sequence_fps_denominator()
    local seq_fps = M.get_sequence_frame_rate()
    return seq_fps.fps_denominator
end

function M.get_sequence_timecode_start_frame()
    return 0
end

function M.has_explicit_mark_in()
    return state.mark_in_value ~= nil
end

function M.has_explicit_mark_out()
    return state.mark_out_value ~= nil
end

function M.get_timeline_content_length()
    return compute_sequence_content_length()
end

function M.get_timeline_extent_end()
    return calculate_timeline_extent()
end

function M.get_mark_in()
    if state.mark_in_value ~= nil then
        return state.mark_in_value
    end
    if state.mark_out_value ~= nil then
        return Rational.new(0, state.sequence_frame_rate.fps_numerator, state.sequence_frame_rate.fps_denominator)
    end
    return nil
end

function M.get_mark_out()
    if state.mark_out_value ~= nil then
        return state.mark_out_value
    end
    if state.mark_in_value ~= nil then
        local content_end = compute_sequence_content_length()
        if content_end > 0 then
            return Rational.new(content_end, state.sequence_frame_rate.fps_numerator, state.sequence_frame_rate.fps_denominator)
        end
        local viewport_end = (state.viewport_start_time + state.viewport_duration)
        return viewport_end
    end
    return nil
end

function M.set_mark_in(time_obj)
    if time_obj == nil then
        if state.mark_in_value ~= nil then
            state.mark_in_value = nil
            notify_listeners()
            M.persist_state_to_db()
        end
        return
    end

    local sanitized = time_obj
    if type(sanitized) == "number" then
        sanitized = Rational.new(sanitized, state.sequence_frame_rate.fps_numerator, state.sequence_frame_rate.fps_denominator)
    end

    if state.mark_in_value == sanitized then
        return
    end

    if state.mark_out_value and sanitized > state.mark_out_value then
        state.mark_out_value = nil
    end

    state.mark_in_value = sanitized

    notify_listeners()
    M.persist_state_to_db()
end

function M.set_mark_out(time_obj)
    if time_obj == nil then
        if state.mark_out_value ~= nil then
            state.mark_out_value = nil
            notify_listeners()
            M.persist_state_to_db()
        end
        return
    end

    local sanitized = time_obj
    if type(sanitized) == "number" then
        sanitized = Rational.new(sanitized, state.sequence_frame_rate.fps_numerator, state.sequence_frame_rate.fps_denominator)
    end

    if state.mark_in_value and sanitized < state.mark_in_value then
        state.mark_in_value = nil
    end

    if state.mark_out_value == sanitized then
        return
    end

    state.mark_out_value = sanitized
    notify_listeners()
    M.persist_state_to_db()
end

function M.clear_marks()
    local changed = false
    if state.mark_in_value ~= nil then
        state.mark_in_value = nil
        changed = true
    end
    if state.mark_out_value ~= nil then
        state.mark_out_value = nil
        changed = true
    end
    if changed then
        notify_listeners()
        M.persist_state_to_db()
    end
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

function M.get_primary_track_id(track_type)
    local desired_type = normalize_track_type(track_type)
    if not desired_type then
        return nil
    end

    for _, track in ipairs(state.tracks) do
        if track.track_type == desired_type then
            return track.id
        end
    end

    return nil
end

function M.get_default_video_track_id()
    return M.get_primary_track_id("VIDEO")
end

function M.get_default_audio_track_id()
    return M.get_primary_track_id("AUDIO")
end

function M.get_track_height(track_id)
    for _, track in ipairs(state.tracks) do
        if track.id == track_id then
            return track.height or M.dimensions.default_track_height
        end
    end
    return M.dimensions.default_track_height
end

function M.set_track_height(track_id, height)
    for _, track in ipairs(state.tracks) do
        if track.id == track_id then
            if track.height ~= height then
                track.height = height
                track_layout_dirty = true
                notify_listeners()
                M.persist_state_to_db()
            end
            return
        end
    end
end

-- Get all clips (WARNING: returned objects become stale after next reload_clips())
function M.get_clips()
    return state.clips
end

function M.get_clips_for_track(track_id)
    if not track_id then
        return {}
    end
    ensure_clip_indexes()
    local list = track_clip_index[track_id]
    if not list then
        return {}
    end
    local clones = {}
    for _, clip in ipairs(list) do
        clones[#clones + 1] = clone_clip_snapshot(clip)
    end
    return clones
end

function M.get_track_clip_windows(sequence_id)
    local windows = {}
    if not sequence_id or sequence_id ~= state.sequence_id then
        return windows
    end
    ensure_clip_indexes()
    for track, clips in pairs(track_clip_index) do
        local clone_list = {}
        for _, clip in ipairs(clips) do
            clone_list[#clone_list + 1] = clone_clip_snapshot(clip)
        end
        windows[track] = clone_list
    end
    return windows
end

function M.describe_track_neighbors(sequence_id, clip_ids)
    local metadata = {}
    if not sequence_id or sequence_id ~= state.sequence_id then
        return metadata
    end
    ensure_clip_indexes()

    local selection = normalize_clip_id_list(clip_ids)
    if next(selection) == nil then
        return metadata
    end

    local clip_ids_by_track = {}
    for clip_id in pairs(selection) do
        local clip = lookup_clip(clip_id)
        if clip and clip.track_id then
            local track_info = clip_track_positions[clip.id]
            if track_info then
                local entry = metadata[clip.track_id]
                if not entry then
                    entry = {
                        track_id = clip.track_id,
                        sequence_id = clip.owner_sequence_id or clip.track_sequence_id or state.sequence_id,
                        indices = {},
                        selected = {},
                        per_clip = {}
                    }
                    metadata[clip.track_id] = entry
                end
                table.insert(entry.indices, track_info.index)
                table.insert(entry.selected, clone_clip_snapshot(clip))
                clip_ids_by_track[clip.track_id] = clip_ids_by_track[clip.track_id] or {}
                table.insert(clip_ids_by_track[clip.track_id], clip.id)
            end
        end
    end

    for track_id, entry in pairs(metadata) do
        table.sort(entry.indices)
        local list = track_clip_index[track_id] or {}
        local first_index = entry.indices[1]
        local last_index = entry.indices[#entry.indices]

        local left_neighbor = nil
        if first_index and first_index > 1 then
            for idx = first_index - 1, 1, -1 do
                local candidate = list[idx]
                if candidate and not selection[candidate.id] then
                    left_neighbor = candidate
                    break
                end
            end
        end

        local right_neighbor = nil
        if last_index and last_index < #list then
            for idx = last_index + 1, #list do
                local candidate = list[idx]
                if candidate and not selection[candidate.id] then
                    right_neighbor = candidate
                    break
                end
            end
        end

        entry.left_neighbor = left_neighbor and clone_clip_snapshot(left_neighbor) or nil
        entry.right_neighbor = right_neighbor and clone_clip_snapshot(right_neighbor) or nil

        local window_start = first_index or 1
        local window_end = last_index or window_start
        if left_neighbor then
            window_start = math.max(1, window_start - 1)
        end
        if right_neighbor then
            window_end = math.min(#list, window_end + 1)
        end

        local window = {}
        for idx = window_start, window_end do
            local clip = list[idx]
            if clip then
                window[#window + 1] = clone_clip_snapshot(clip)
            end
        end
        entry.window = window

        local first_clip = list[first_index or window_start]
        local last_clip = list[last_index or window_end]
        entry.block_start = first_clip and first_clip.timeline_start or Rational.new(0, 1, 1)
        if last_clip then
            entry.block_end = (last_clip.timeline_start or Rational.new(0, 1, 1)) + (last_clip.duration or Rational.new(0, 1, 1))
        else
            entry.block_end = entry.block_start
        end

        if clip_ids_by_track[track_id] then
            for _, clip_id in ipairs(clip_ids_by_track[track_id]) do
                local info = clip_track_positions[clip_id]
                if info then
                    local idx = info.index
                    local left = nil
                    for scan = idx - 1, 1, -1 do
                        local candidate = list[scan]
                        if candidate and not selection[candidate.id] then
                            left = candidate
                            break
                        end
                    end
                    local right = nil
                    for scan = idx + 1, #list do
                        local candidate = list[scan]
                        if candidate and not selection[candidate.id] then
                            right = candidate
                            break
                        end
                    end
                    entry.per_clip[clip_id] = {
                        left_neighbor = left and clone_clip_snapshot(left) or nil,
                        right_neighbor = right and clone_clip_snapshot(right) or nil
                    }
                end
            end
        end
    end

    return metadata
end

function M.get_clip_by_id(clip_id)
    for _, clip in ipairs(state.clips) do
        if clip.id == clip_id then
            return clip
        end
    end
    return nil
end

function M.get_clips_at_time(time_obj, allowed_clips)
    local time_frames = time_obj.frames

    local filter = nil
    if allowed_clips and #allowed_clips > 0 then
        filter = {}
        for _, entry in ipairs(allowed_clips) do
            if type(entry) == "table" then
                if entry.id and entry.id ~= "" then
                    filter[entry.id] = true
                end
            elseif type(entry) == "string" then
                filter[entry] = true
            end
        end
    end

    local results = {}
    for _, clip in ipairs(state.clips) do
        local clip_start = clip.timeline_start.frames
        local clip_end = clip.timeline_start.frames + clip.duration.frames
        if time_frames > clip_start and time_frames < clip_end then
            if not filter or filter[clip.id] then
                table.insert(results, clip)
            end
        end
    end
    return results
end

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

function M.get_state_version()
    return state_version
end

function M.get_viewport_start_time()
    return state.viewport_start_time
end

function M.get_viewport_duration()
    return state.viewport_duration
end

function M.get_viewport_duration_frames()
    return state.viewport_duration.frames
end

function M.get_viewport_end_time()
    return state.viewport_start_time + state.viewport_duration
end

function M.capture_viewport()
    return {
        start_time = state.viewport_start_time,
        duration = state.viewport_duration,
    }
end

function M.restore_viewport(snapshot)
    if not snapshot then
        return
    end

    local target_duration = snapshot.duration or state.viewport_duration
    local target_start = snapshot.start_time
    if target_start == nil then
        target_start = state.viewport_start_time
    end
    
    local clamped_start_rational = clamp_viewport_start(target_start, target_duration)

    local changed = false

    if state.viewport_duration ~= target_duration then
        state.viewport_duration = target_duration
        changed = true
    end

    if state.viewport_start_time ~= clamped_start_rational then
        state.viewport_start_time = clamped_start_rational
        changed = true
    end

    if changed then
        notify_listeners()
        M.persist_state_to_db()
    end
end

function M.get_playhead_position()
    return state.playhead_position
end

function M.get_selected_clips()
    return state.selected_clips
end

function M.set_viewport_start_time(time_obj)
    local clamped_start_rational = clamp_viewport_start(time_obj, state.viewport_duration)
    if state.viewport_start_time ~= clamped_start_rational then
        state.viewport_start_time = clamped_start_rational
        notify_listeners()
        M.persist_state_to_db()
    end
end

function M.set_viewport_duration(duration_obj)
    local new_duration_rational = duration_obj
    if type(new_duration_rational) == "number" then
        local seq_fps = M.get_sequence_frame_rate()
        new_duration_rational = Rational.new(new_duration_rational, seq_fps.fps_numerator, seq_fps.fps_denominator)
    end

    if state.viewport_duration ~= new_duration_rational then
        local playhead = state.playhead_position
        local half_duration = new_duration_rational / 2
        local desired_start = playhead - half_duration
        local clamped_start_rational = clamp_viewport_start(desired_start, new_duration_rational)

        local changed = false

        if state.viewport_duration ~= new_duration_rational then
            state.viewport_duration = new_duration_rational
            changed = true
        end

        if state.viewport_start_time ~= clamped_start_rational then
            state.viewport_start_time = clamped_start_rational
            changed = true
        end

        if changed then
            notify_listeners()
            M.persist_state_to_db()
        end
    end
end

function M.set_playhead_position(time_obj)
    local normalized_time = time_obj
    if type(normalized_time) == "number" then
        local seq_fps = M.get_sequence_frame_rate()
        normalized_time = Rational.new(normalized_time, seq_fps.fps_numerator, seq_fps.fps_denominator)
    end
    local changed = state.playhead_position ~= normalized_time
    state.playhead_position = normalized_time

    local viewport_adjusted = ensure_playhead_visible()

    if changed then
        notify_listeners()
        M.persist_state_to_db()

        if on_selection_changed_callback then
            on_selection_changed_callback(state.selected_clips)
        end
    elseif viewport_adjusted then
        -- ensure_playhead_visible already persisted via set_viewport_start_value
        if on_selection_changed_callback then
            on_selection_changed_callback(state.selected_clips)
        end
    end
end

function M.set_selection(clips)
    state.selected_clips = clips or {}

    -- Clear edge selection (clips and edges are mutually exclusive)
    state.selected_edges = {}
    state.selected_gaps = {}

    notify_listeners()

    -- Persist selection to database
    M.persist_state_to_db()

    if on_selection_changed_callback then
        on_selection_changed_callback(state.selected_clips)
    end
end

function M.get_selected_edges()
    return state.selected_edges
end

function M.set_edge_selection_raw(edges, opts)
    opts = opts or {}
    state.selected_edges = edges or {}

    if opts.clear_clips ~= false then
        state.selected_clips = {}
    end
    if opts.clear_gaps ~= false then
        state.selected_gaps = {}
    end

    if opts.normalize ~= false then
        normalize_edge_selection()
    end

    if opts.notify ~= false then
        notify_listeners()
    end

    if opts.persist ~= false then
        M.persist_state_to_db()
    end
end

function M.set_edge_selection(edges)
    return M.set_edge_selection_raw(edges, {
        normalize = true,
        notify = true,
        persist = true,
        clear_clips = true,
        clear_gaps = true
    })
end

function M.toggle_edge_selection(clip_id, edge_type, trim_type)
    -- Check if this edge is already selected
    for i, edge in ipairs(state.selected_edges) do
        if edge.clip_id == clip_id and edge.edge_type == edge_type then
            -- Remove it
            table.remove(state.selected_edges, i)
            normalize_edge_selection()
            state.selected_gaps = {}
            notify_listeners()
            M.persist_state_to_db()
            return false  -- Deselected
        end
    end

    -- Clear clip selection when selecting first edge (clips and edges are mutually exclusive)
    if #state.selected_edges == 0 then
        state.selected_clips = {}
        state.selected_gaps = {}
    end

    -- Add new edge
    table.insert(state.selected_edges, {
        clip_id = clip_id,
        edge_type = edge_type,
        trim_type = trim_type
    })

    normalize_edge_selection()

    state.selected_gaps = {}
    notify_listeners()
    M.persist_state_to_db()
    return true  -- Selected
end

function M.clear_edge_selection()
    if #state.selected_edges > 0 then
        state.selected_edges = {}
        normalize_edge_selection()
        state.selected_gaps = {}
        notify_listeners()
        M.persist_state_to_db()
    end
end

function M.get_selected_gaps()
    return state.selected_gaps or {}
end

local function gaps_equal(a, b)
    if not a or not b or a.track_id ~= b.track_id then
        return false
    end
    
    -- Assume Rational objects
    if getmetatable(a.start_value) == Rational.metatable and getmetatable(b.start_value) == Rational.metatable then
        if a.start_value ~= b.start_value then return false end
    else
        -- Fallback (should not happen if fully migrated)
        if (a.start_value or 0) ~= (b.start_value or 0) then return false end
    end

    if getmetatable(a.duration) == Rational.metatable and getmetatable(b.duration) == Rational.metatable then
        if a.duration ~= b.duration then return false end
    else
        if (a.duration or a.duration_value or 0) ~= (b.duration or b.duration_value or 0) then return false end
    end
    
    return true
end

function M.set_gap_selection(gaps)
    state.selected_gaps = gaps or {}
    state.selected_clips = {}
    state.selected_edges = {}
    notify_listeners()
end

function M.clear_gap_selection()
    if state.selected_gaps and #state.selected_gaps > 0 then
        state.selected_gaps = {}
        notify_listeners()
    end
end

function M.toggle_gap_selection(gap)
    if not gap then
        return false
    end

    local current = state.selected_gaps or {}
    if #current == 1 and gaps_equal(current[1], gap) then
        state.selected_gaps = {}
        notify_listeners()
        return false
    else
        state.selected_gaps = {gap}
        state.selected_clips = {}
        state.selected_edges = {}
        notify_listeners()
        return true
    end
end

function M.push_viewport_guard()
    viewport_guard_count = viewport_guard_count + 1
    return viewport_guard_count
end

function M.pop_viewport_guard()
    if viewport_guard_count > 0 then
        viewport_guard_count = viewport_guard_count - 1
    end
    return viewport_guard_count
end

function M.set_on_selection_changed(callback)
    on_selection_changed_callback = callback
    if callback and #state.selected_clips > 0 then
        callback(state.selected_clips)
    end
end

function M.set_project_browser(browser)
    project_browser = browser
end

function M.get_project_browser()
    return project_browser
end

function M.set_rubber_band(band)
    rubber_band = band
end

function M.get_rubber_band()
    return rubber_band
end

function M.time_to_pixel(time_obj, viewport_width)
    local time_ms
    if type(time_obj) == "table" and time_obj.to_seconds then
        time_ms = time_obj:to_seconds() * 1000.0
    else
        time_ms = tonumber(time_obj) or 0
    end

    local start_ms = state.viewport_start_time:to_seconds() * 1000.0
    local duration_ms = state.viewport_duration:to_seconds() * 1000.0
    
    local pixels_per_ms = viewport_width / duration_ms
    return math.floor((time_ms - start_ms) * pixels_per_ms)
end

function M.pixel_to_time(pixel, viewport_width)
    local start_ms = state.viewport_start_time:to_seconds() * 1000.0
    local duration_ms = state.viewport_duration:to_seconds() * 1000.0
    
    local pixels_per_ms = viewport_width / duration_ms
    local time_ms = start_ms + (pixel / pixels_per_ms)
    
    local rate = state.sequence_frame_rate
    return Rational.from_seconds(time_ms / 1000.0, rate.fps_numerator, rate.fps_denominator)
end

function M.debug_begin_layout_capture(view_id, viewport_width, viewport_height)
    if not view_id then return end
    debug_layouts[view_id] = {
        widget_width = viewport_width,
        widget_height = viewport_height,
        tracks = {},
        clips = {}
    }
end

function M.debug_record_track_layout(view_id, track_id, y, height)
    local layout = debug_layouts[view_id]
    if not layout then return end
    layout.tracks[track_id] = { y = y, height = height }
end

function M.debug_record_clip_layout(view_id, clip_id, track_id, x, y, width, height)
    local layout = debug_layouts[view_id]
    if not layout then return end
    layout.clips[clip_id] = { track_id = track_id, x = x, y = y, width = width, height = height }
end

function M.debug_get_clip_layout(view_id, clip_id)
    local layout = debug_layouts[view_id]
    return layout and layout.clips[clip_id] or nil
end

function M.debug_get_track_layout(view_id, track_id)
    local layout = debug_layouts[view_id]
    return layout and layout.tracks[track_id] or nil
end

function M.debug_get_layout_metrics(view_id)
    return debug_layouts[view_id]
end

function M.detect_edge_at_position(clip, click_x, viewport_width)
    local EDGE_ZONE_PX = ui_constants.TIMELINE.EDGE_ZONE_PX
    local clip_start_x = M.time_to_pixel(clip.timeline_start, viewport_width)
    local clip_end_x = M.time_to_pixel(clip.timeline_start + clip.duration, viewport_width)

    if math.abs(click_x - clip_start_x) <= EDGE_ZONE_PX then
        return "in", "ripple"
    end
    if math.abs(click_x - clip_end_x) <= EDGE_ZONE_PX then
        return "out", "ripple"
    end
    return nil, nil
end

function M.detect_roll_between_clips(clip1, clip2, click_x, viewport_width)
    if not clip1 or not clip2 then return false end

    local ROLL_ZONE_PX = ui_constants.TIMELINE.ROLL_ZONE_PX
    local EDGE_ZONE_PX = ui_constants.TIMELINE.EDGE_ZONE_PX or 0
    local gap_start_x = M.time_to_pixel(clip1.timeline_start + clip1.duration, viewport_width)
    local gap_end_x = M.time_to_pixel(clip2.timeline_start, viewport_width)

    if gap_end_x - gap_start_x < ROLL_ZONE_PX then
        local edit_point_x = (gap_start_x + gap_end_x) / 2
        local half_roll_zone = ROLL_ZONE_PX / 2
        if EDGE_ZONE_PX and EDGE_ZONE_PX > 0 then
            half_roll_zone = math.min(half_roll_zone, EDGE_ZONE_PX / 2)
        end
        if half_roll_zone < 1 then
            half_roll_zone = 1
        end
        if math.abs(click_x - edit_point_x) <= half_roll_zone then
            return true
        end
    end
    return false
end

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

function M._internal_add_clip_from_command(clip)
    table.insert(state.clips, clip)
    invalidate_clip_indexes()
    notify_listeners()
end

function M._internal_remove_clip_from_command(clip_id)
    for i, clip in ipairs(state.clips) do
        if clip.id == clip_id then
            table.remove(state.clips, i)
            invalidate_clip_indexes()
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

function M.consume_mutation_failure()
    local failure = last_mutation_failure
    last_mutation_failure = nil
    return failure
end

local function apply_mutation_table(mutations)
    if not mutations then return false end
    local changed = false
    local failure_reason = nil
    local deleted_lookup = {}
    local had_sequence_meta = mutations.sequence_meta ~= nil

    if mutations.deletes then
        for _, clip_id in ipairs(mutations.deletes) do
            if clip_id then
                M._internal_remove_clip_from_command(clip_id)
                deleted_lookup[clip_id] = true
                changed = true
            end
        end
    end

    if mutations.updates and #mutations.updates > 0 then
        local ok, updates_changed = M._internal_apply_clip_updates(mutations.updates, deleted_lookup)
        if ok == false then
            failure_reason = "missing_clip"
            return false, failure_reason
        end
        if updates_changed then
            changed = true
        end
    end

    if mutations.inserts then
        for _, clip in ipairs(mutations.inserts) do
            if clip and clip.id then
                M._internal_add_clip_from_command(clip)
                changed = true
            end
        end
    end

    if not changed and had_sequence_meta then
        changed = true
    end

    return changed, failure_reason
end

function M.apply_mutations(sequence_id, mutations)
    if not mutations then return false end
    local mutation_scope = profile_scope.begin("timeline_state.apply_mutations", {
        details_fn = function() 
            return string.format("sequence=%s", tostring(sequence_id or state.sequence_id))
        end
    })
    sequence_id = sequence_id or (mutations.sequence_id)
    if not state.sequence_id or state.sequence_id == "" then
        record_mutation_failure("inactive_timeline_state", { requested_sequence = sequence_id })
        if mutation_scope then mutation_scope:finish("inactive_state") end
        return false
    end
    if sequence_id and state.sequence_id and sequence_id ~= state.sequence_id then
        record_mutation_failure("sequence_mismatch", { requested_sequence = sequence_id, active_sequence = state.sequence_id })
        if mutation_scope then mutation_scope:finish("sequence_mismatch") end
        return false
    end

    local changed, failure_reason = apply_mutation_table(mutations)
    if failure_reason then
        mutation_scope:finish("failure:" .. failure_reason)
        return false
    end
    local selection_adjusted = normalize_edge_selection()
    if changed or selection_adjusted then
        M.persist_state_to_db()
    end
    mutation_scope:finish(string.format("changed=%s selection_adjusted=%s", tostring(changed), tostring(selection_adjusted)))
    return changed
end

function M._internal_apply_clip_updates(updates, deleted_lookup)
    if not updates or #updates == 0 then return true, false end
    ensure_clip_indexes()
    local changed = false
    local needs_resort = false
    for index, update in ipairs(updates) do
        local clip_id = update.clip_id or update.id
        if clip_id then
            local clip = lookup_clip(clip_id)
            if not clip then
                clip = hydrate_clip_from_database(clip_id, update.track_sequence_id)
                if clip then
                    needs_resort = true
                    changed = true
                end
            end
            if not clip then
                if deleted_lookup and deleted_lookup[clip_id] then
                    goto continue_update_loop
                end
                local update_keys = {}
                for key in pairs(update) do table.insert(update_keys, tostring(key)) end
                table.sort(update_keys)
                record_mutation_failure("missing_clip", { clip_id = clip_id, update_keys = update_keys, update_index = index, total_updates = #updates })
                return false
            end

            if update.track_id and update.track_id ~= clip.track_id then
                clip.track_id = update.track_id
                clip.track_sequence_id = update.track_sequence_id or clip.track_sequence_id
                needs_resort = true
                changed = true
            end
            local seq_fps = M.get_sequence_frame_rate()
            if update.start_value and update.start_value ~= clip.timeline_start.frames then
                clip.timeline_start = Rational.new(update.start_value, seq_fps.fps_numerator, seq_fps.fps_denominator)
                needs_resort = true
                changed = true
            end
            if update.duration_value and update.duration_value ~= clip.duration.frames then
                clip.duration = Rational.new(update.duration_value, seq_fps.fps_numerator, seq_fps.fps_denominator)
                changed = true
            end
            if update.source_in_value and update.source_in_value ~= clip.source_in.frames then
                clip.source_in = Rational.new(update.source_in_value, seq_fps.fps_numerator, seq_fps.fps_denominator)
                changed = true
            end
            if update.source_out_value and update.source_out_value ~= clip.source_out.frames then
                clip.source_out = Rational.new(update.source_out_value, seq_fps.fps_numerator, seq_fps.fps_denominator)
                changed = true
            end
            if update.enabled ~= nil and update.enabled ~= clip.enabled then
                clip.enabled = update.enabled and true or false
                changed = true
            end
        end
        ::continue_update_loop::
    end

    if not changed then return true, false end
    state_version = state_version + 1
    if needs_resort then
        local track_order = {}
        for idx, track in ipairs(state.tracks) do track_order[track.id] = idx end
        table.sort(state.clips, function(a, b)
            local ta = track_order[a.track_id] or math.huge
            local tb = track_order[b.track_id] or math.huge
            if ta == tb then
                local sa = a.timeline_start.frames or 0
                local sb = b.timeline_start.frames or 0
                if sa == sb then return (a.id or "") < (b.id or "") end
                return sa < sb
            end
            return ta < tb
        end)
    end
    if state.selected_clips and #state.selected_clips > 0 then
        local refreshed = {}
        for _, selected in ipairs(state.selected_clips) do
            local clip = lookup_clip(selected.id)
            if clip then table.insert(refreshed, clip) end
        end
        state.selected_clips = refreshed
    end
    invalidate_clip_indexes()
    if needs_resort then ensure_clip_indexes() end
    notify_listeners()
    return true, true
end

function M.update_clip(clip_id, updates)
    error("Direct clip modification is not allowed. Use command_manager to execute a command instead.")
end

function M.get_playhead_value()
    return state.playhead_position
end

---
-- Persist playhead and selection state to sequences table (for session restoration)
---
local function flush_state_to_db()
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

    local success, json_str = pcall(json.encode, selected_ids)
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

    local success_edges, edges_json = pcall(json.encode, edge_descriptors)
    if not success_edges then
        edges_json = "[]"
    end

    -- Update sequences table with current state
    local query = db_conn:prepare([[ 
        UPDATE sequences
        SET playhead_frame = ?, selected_clip_ids = ?, selected_edge_infos = ?, view_start_frame = ?, view_duration_frames = ?, mark_in_frame = ?, mark_out_frame = ?
        WHERE id = ?
    ]])

    if query then
        query:bind_value(1, state.playhead_position.frames)
        query:bind_value(2, json_str)
        query:bind_value(3, edges_json)
        query:bind_value(4, state.viewport_start_time.frames)
        query:bind_value(5, state.viewport_duration.frames)
        query:bind_value(6, state.mark_in_value and state.mark_in_value.frames or nil)
        query:bind_value(7, state.mark_out_value and state.mark_out_value.frames or nil)
        query:bind_value(8, sequence_id)
        query:exec()
    end

    if track_layout_dirty and db.set_sequence_track_heights then
        local height_map = build_track_height_map()
        db.set_sequence_track_heights(sequence_id, height_map)
        track_layout_dirty = false
    end

    if track_template_dirty and db.set_project_setting then
        local template = build_track_height_template()
        if template then
            local project_id = state.project_id or "default_project"
            db.set_project_setting(project_id, TRACK_HEIGHT_TEMPLATE_KEY, template)
        end
        track_template_dirty = false
    end
end

local function schedule_state_persist(immediate)
    persist_dirty = true

    if immediate then
        persist_dirty = false
        flush_state_to_db()
        return
    end

    if persist_timer then
        return
    end

    persist_timer = create_single_shot_timer(PERSIST_DEBOUNCE_MS, function()
        persist_timer = nil
        if not persist_dirty then
            return
        end
        persist_dirty = false
        flush_state_to_db()
    end)
end

function M.persist_state_to_db(force)
    local command_manager = require("core.command_manager") -- Added dynamically
    if force == true then
        schedule_state_persist(true)
    else
        schedule_state_persist(false)
    end
end

return M