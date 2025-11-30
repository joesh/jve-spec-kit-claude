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

-- Viewport & Playhead
M.get_viewport_start_time = viewport.get_viewport_start_time
M.get_viewport_start_value = viewport.get_viewport_start_time -- Legacy Alias
M.set_viewport_start_time = viewport.set_viewport_start_time
M.set_viewport_start_value = viewport.set_viewport_start_time -- Legacy Alias
M.get_viewport_duration = viewport.get_viewport_duration
M.set_viewport_duration = viewport.set_viewport_duration
M.get_playhead_position = viewport.get_playhead_position
M.get_playhead_value = viewport.get_playhead_position -- Legacy Alias
M.set_playhead_position = viewport.set_playhead_position
M.set_playhead_value = viewport.set_playhead_position -- Legacy Alias
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
M.get_primary_track_id = tracks.get_primary_id
M.get_default_video_track_id = function() return tracks.get_primary_id("VIDEO") end
M.get_default_audio_track_id = function() return tracks.get_primary_id("AUDIO") end

-- Clips
M.get_clips = clips.get_all
M.get_clip_by_id = clips.get_by_id
M.get_clips_for_track = clips.get_for_track
M.apply_mutations = clips.apply_mutations
M.update_clip = function() error("Use commands") end
M.add_clip = function() error("Use commands") end
M.remove_clip = function() error("Use commands") end
M.validate_clip_fresh = function(clip)
    if not clip then return false, "Nil clip" end
    if not clip._version then return false, "No version" end
    if clip._version ~= clips.get_version() then return false, "Stale" end
    return true
end
M.get_state_version = clips.get_version

-- Selection
M.get_selected_clips = selection.get_selected_clips
M.set_selection = selection.set_selection
M.get_selected_edges = selection.get_selected_edges
M.set_edge_selection = selection.set_edge_selection
M.toggle_edge_selection = selection.toggle_edge_selection
M.clear_edge_selection = selection.clear_edge_selection
M.get_selected_gaps = selection.get_selected_gaps
M.set_gap_selection = selection.set_gap_selection
M.toggle_gap_selection = selection.toggle_gap_selection
M.clear_gap_selection = function() selection.set_gap_selection({}) end
M.set_on_selection_changed = selection.set_on_selection_changed
M.normalize_edge_selection = selection.normalize_edge_selection

-- Project/Sequence Accessors (Proxied from data state)
M.get_project_id = function() return data.state.project_id end
M.get_sequence_id = function() return data.state.sequence_id end
M.get_sequence_frame_rate = function() return data.state.sequence_frame_rate end
M.get_sequence_fps_numerator = function() return data.state.sequence_frame_rate.fps_numerator end
M.get_sequence_fps_denominator = function() return data.state.sequence_frame_rate.fps_denominator end

-- Marks
M.get_mark_in = function() return data.state.mark_in_value end
M.get_mark_out = function() return data.state.mark_out_value end
M.set_mark_in = function(val) data.state.mark_in_value = val; data.notify_listeners(); core.persist_state_to_db() end
M.set_mark_out = function(val) data.state.mark_out_value = val; data.notify_listeners(); core.persist_state_to_db() end
M.clear_marks = function() data.state.mark_in_value=nil; data.state.mark_out_value=nil; data.notify_listeners(); core.persist_state_to_db() end

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

-- Roll detection (Logic was in timeline_state.lua? Yes. Move to edge_utils or keep here?)
-- It was exported.
M.detect_edge_at_position = function(...) 
    -- Moved logic to timeline_view or keep? 
    -- Original code had it. I should probably keep it or move it to a helper.
    -- Let's keep a simple implementation or delegate.
    -- The logic uses M.time_to_pixel.
    local clip, click_x, width = ...
    local ui_constants = require("core.ui_constants")
    local EDGE = ui_constants.TIMELINE.EDGE_ZONE_PX
    local sx = M.time_to_pixel(clip.timeline_start, width)
    local ex = M.time_to_pixel(clip.timeline_start + clip.duration, width)
    if math.abs(click_x - sx) <= EDGE then return "in", "ripple" end
    if math.abs(click_x - ex) <= EDGE then return "out", "ripple" end
    return nil
end

M.detect_roll_between_clips = function(c1, c2, x, w)
    local ui_constants = require("core.ui_constants")
    local ROLL = ui_constants.TIMELINE.ROLL_ZONE_PX
    local sx = M.time_to_pixel(c1.timeline_start + c1.duration, w)
    local ex = M.time_to_pixel(c2.timeline_start, w)
    if ex - sx < ROLL then
        local mid = (sx + ex) / 2
        if math.abs(x - mid) <= ROLL/2 then return true end
    end
    return false
end

return M
