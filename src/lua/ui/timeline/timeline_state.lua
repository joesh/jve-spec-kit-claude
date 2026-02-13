--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~203 LOC
-- Volatility: unknown
--
-- @file timeline_state.lua
-- Original intent (unreviewed):
-- Timeline State Module (Facade)
-- Aggregates sub-modules for backward compatibility and API surface
local M = {}

-- Sub-modules
local data = require("ui.timeline.state.timeline_state_data")
local core = require("ui.timeline.state.timeline_core_state")
local viewport = require("ui.timeline.state.viewport_state")
local selection = require("ui.timeline.state.selection_state")
local tracks = require("ui.timeline.state.track_state")
local clips = require("ui.timeline.state.clip_state")

-- Shared Data & Constants
M.dimensions = data.dimensions
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
    edge_selected_available = "#66ff66",
    edge_selected_limit = "#ff6666",
}

-- Core Lifecycle
M.init = core.init
M.reset = data.reset
M.persist_state_to_db = core.persist_state_to_db
M.reload_clips = core.reload_clips
M.add_listener = data.add_listener
M.remove_listener = data.remove_listener

-- Active Edge Drag State (shared across panes; not persisted)
M.get_active_edge_drag_state = function()
    return data.state.active_edge_drag_state
end

M.set_active_edge_drag_state = function(edge_drag_state)
    data.state.active_edge_drag_state = edge_drag_state
    data.notify_listeners()
end

M.clear_active_edge_drag_state = function()
    data.state.active_edge_drag_state = nil
    data.notify_listeners()
end

-- Viewport & Playhead
M.get_viewport_start_time = viewport.get_viewport_start_time
M.set_viewport_start_time = function(time_obj)
    return viewport.set_viewport_start_time(time_obj, core.persist_state_to_db)
end
M.get_viewport_duration = viewport.get_viewport_duration
M.set_viewport_duration = function(duration_obj)
    return viewport.set_viewport_duration(duration_obj, core.persist_state_to_db)
end
M.get_playhead_position = viewport.get_playhead_position
M.set_playhead_position = viewport.set_playhead_position
M.time_to_pixel = viewport.time_to_pixel
M.pixel_to_time = viewport.pixel_to_time
M.capture_viewport = function()
    return {
        start_time = viewport.get_viewport_start_time(),
        duration = viewport.get_viewport_duration()
    }
end
M.restore_viewport = function(snapshot)
    if not snapshot then return end
    if snapshot.duration then viewport.set_viewport_duration(snapshot.duration) end
    if snapshot.start_time then viewport.set_viewport_start_time(snapshot.start_time) end
end
M.push_viewport_guard = viewport.push_viewport_guard
M.pop_viewport_guard = viewport.pop_viewport_guard

-- Tracks
M.get_all_tracks = tracks.get_all
M.get_video_tracks = tracks.get_video_tracks
M.get_audio_tracks = tracks.get_audio_tracks
M.get_track_height = tracks.get_height
M.set_track_height = tracks.set_height
M.get_track_by_id = tracks.get_by_id
M.get_primary_track_id = tracks.get_primary_id
M.get_default_video_track_id = function() return tracks.get_primary_id("VIDEO") end
M.get_default_audio_track_id = function() return tracks.get_primary_id("AUDIO") end

-- Clips
M.get_clips = function()
    assert(not M.__forbid_get_clips, "timeline_state.get_clips is forbidden in this context (renderer should use clip indices)")
    return clips.get_all()
end
M.get_clip_by_id = clips.get_by_id
M.get_clips_for_track = clips.get_for_track
M.get_track_clip_index = clips.get_track_clip_index
M.get_clips_at_time = clips.get_at_time
local function apply_mutations(sequence_or_mutations, maybe_mutations, persist_callback)
    local mutations = sequence_or_mutations
    local callback = maybe_mutations

    -- Accept legacy signature apply_mutations(sequence_id, mutations, callback)
    if type(sequence_or_mutations) == "string" or type(sequence_or_mutations) == "number" then
        mutations = maybe_mutations
        callback = persist_callback
    end

    assert(type(mutations) == "table",
        "timeline_state.apply_mutations: mutations must be a table, got " .. type(mutations))
    return clips.apply_mutations(mutations, callback)
end

M.apply_mutations = apply_mutations
M.update_clip = function() error("Use commands") end
M.add_clip = function() error("Use commands") end
M.remove_clip = function() error("Use commands") end
M._internal_add_clip_from_command = function(clip)
    if not clip then return false end
    return apply_mutations({inserts = {clip}})
end
M._internal_remove_clip_from_command = function(clip_id)
    if not clip_id then return false end
    return apply_mutations({deletes = {clip_id}})
end
M.validate_clip_fresh = function(clip)
    if not clip then return false, "Nil clip" end
    if not clip._version then return false, "No version" end
    if clip._version ~= clips.get_version() then return false, "Stale" end
    return true
end
M.get_state_version = clips.get_version

-- Selection
M.get_selected_clips = selection.get_selected_clips
local function persist_selection_state()
    if core and core.persist_state_to_db then
        core.persist_state_to_db()
    end
end

M.set_selection = function(clip_list)
    selection.set_selection(clip_list, persist_selection_state)
end

M.get_selected_edges = selection.get_selected_edges

M.set_edge_selection = function(edges, opts)
    selection.set_edge_selection(edges, opts, persist_selection_state)
end

M.restore_edge_selection = function(edges, opts)
    selection.restore_edge_selection(edges, opts, persist_selection_state)
end

M.toggle_edge_selection = function(clip_id, edge_type, trim_type)
    return selection.toggle_edge_selection(clip_id, edge_type, trim_type, persist_selection_state)
end

M.clear_edge_selection = function()
    selection.clear_edge_selection(persist_selection_state)
end

M.get_selected_gaps = selection.get_selected_gaps

M.set_gap_selection = function(gaps)
    selection.set_gap_selection(gaps)
    persist_selection_state()
end

M.toggle_gap_selection = function(gap)
    local changed = selection.toggle_gap_selection(gap)
    if changed ~= nil then
        persist_selection_state()
    end
    return changed
end
M.clear_gap_selection = function() selection.set_gap_selection({}) end
M.set_on_selection_changed = selection.set_on_selection_changed
M.normalize_edge_selection = selection.normalize_edge_selection

-- Project/Sequence Accessors (Proxied from data state)
M.get_project_id = function() return data.state.project_id end
M.get_sequence_id = function() return data.state.sequence_id end
M.get_sequence_frame_rate = function() return data.state.sequence_frame_rate end
M.get_sequence_fps_numerator = function()
    assert(data.state.sequence_frame_rate, "timeline_state.get_sequence_fps_numerator: sequence_frame_rate not initialized")
    return data.state.sequence_frame_rate.fps_numerator
end
M.get_sequence_fps_denominator = function()
    assert(data.state.sequence_frame_rate, "timeline_state.get_sequence_fps_denominator: sequence_frame_rate not initialized")
    return data.state.sequence_frame_rate.fps_denominator
end

-- Marks: read from sequence model (set via undoable mark commands)
M.get_mark_in = function() return data.sequence and data.sequence.mark_in end
M.get_mark_out = function() return data.sequence and data.sequence.mark_out end

-- Debug (Proxied to local vars in original? No, original had local debug_layouts. We can move that to view logic or keep it here if views call it.)
-- Since views call `debug_record...`, we need to support it.
-- I'll add a simple debug store to this facade or data.lua.
local debug_layouts = {}
M.debug_begin_layout_capture = function(id, w, h) debug_layouts[id] = {w=w, h=h, tracks={}, clips={}} end
M.debug_record_track_layout = function(id, tid, y, h) if debug_layouts[id] then debug_layouts[id].tracks[tid] = {y=y, h=h} end end
M.debug_record_clip_layout = function(id, cid, tid, x, y, w, h) if debug_layouts[id] then debug_layouts[id].clips[cid] = {x=x, y=y, w=w, h=h, track_id=tid} end end

-- Dragging (Interaction state is in data)
M.is_dragging_playhead = function() return data.state.dragging_playhead end
M.set_dragging_playhead = function(v) data.state.dragging_playhead = v end

-- Roll detection - now uses integer frame arithmetic
M.detect_edge_at_position = function(...)
    local clip, click_x, width = ...
    local ui_constants = require("core.ui_constants")
    local EDGE = ui_constants.TIMELINE.EDGE_ZONE_PX
    assert(type(clip.timeline_start) == "number", "detect_edge_at_position: timeline_start must be integer")
    assert(type(clip.duration) == "number", "detect_edge_at_position: duration must be integer")
    local sx = M.time_to_pixel(clip.timeline_start, width)
    local ex = M.time_to_pixel(clip.timeline_start + clip.duration, width)
    if math.abs(click_x - sx) <= EDGE then return "in", "ripple" end
    if math.abs(click_x - ex) <= EDGE then return "out", "ripple" end
    return nil
end

M.detect_roll_between_clips = function(c1, c2, x, w)
    local ui_constants = require("core.ui_constants")
    local ROLL = ui_constants.TIMELINE.ROLL_ZONE_PX or 0
    assert(type(c1.timeline_start) == "number" and type(c1.duration) == "number",
        "detect_roll_between_clips: c1 coords must be integers")
    assert(type(c2.timeline_start) == "number",
        "detect_roll_between_clips: c2.timeline_start must be integer")
    local boundary_left = c1.timeline_start + c1.duration
    local boundary_right = c2.timeline_start

    local sx = M.time_to_pixel(boundary_left, w)
    local ex = M.time_to_pixel(boundary_right, w)
    local span = math.abs(ex - sx)
    if span > ROLL then
        return false
    end

    local mid = (sx + ex) / 2
    return math.abs(x - mid) <= (ROLL / 2)
end

--- Clear state that shouldn't persist across projects
function M.on_project_change()
    data.state.sequence_id = nil
    data.state.project_id = nil
    data.sequence = nil
end

-- Register for project_changed signal
local Signals = require("core.signals")
Signals.connect("project_changed", M.on_project_change, 40)

return M
