-- Timeline View Input Handler
-- Manages mouse and keyboard interactions

local M = {}
local ui_constants = require("core.ui_constants")
local edge_picker = require("ui.timeline.edge_picker")
local keyboard_shortcuts = require("core.keyboard_shortcuts")
local focus_manager = require("ui.focus_manager")
local magnetic_snapping = require("core.magnetic_snapping")
local Rational = require("core.rational")
local time_utils = require("core.time_utils")

local RIGHT_MOUSE_BUTTON = 2
local DRAG_THRESHOLD = ui_constants.TIMELINE.DRAG_THRESHOLD

local function edges_match(a, b)
    return a and b
        and a.clip_id == b.clip_id
        and a.edge_type == b.edge_type
        and (a.trim_type or "ripple") == (b.trim_type or "ripple")
end

local function selection_contains_all(existing, target_edges)
    if not existing or not target_edges then return false end
    for _, target in ipairs(target_edges) do
        local found = false
        for _, current in ipairs(existing) do
            if edges_match(current, target) then
                found = true
                break
            end
        end
        if not found then return false end
    end
    return true
end

local function find_clip_under_cursor(view, x, y, width, height)
    local state = view.state
    for _, clip in ipairs(state.get_clips()) do
        local clip_y = view.get_track_y_by_id(clip.track_id, height)
        if clip_y >= 0 then
            local track_height = view.get_track_visual_height(clip.track_id)
            if y >= clip_y and y <= clip_y + track_height then
                local clip_x = state.time_to_pixel(clip.timeline_start, width)
                local clip_width = math.max(0, math.floor((clip.duration / state.get_viewport_duration()) * width) - 1)
                if x >= clip_x and x <= clip_x + clip_width then
                    return clip
                end
            end
        end
    end
    return nil
end

local function find_gap_at_time(view, track_id, time_obj)
    if not track_id or not time_obj then return nil end
    local state = view.state
    local clips_on_track = {}
    for _, clip in ipairs(state.get_clips() or {}) do
        if clip.track_id == track_id then table.insert(clips_on_track, clip) end
    end
    table.sort(clips_on_track, function(a, b)
        if a.timeline_start == b.timeline_start then return a.id < b.id end
        return a.timeline_start < b.timeline_start
    end)
    
    local seq_fps = state.get_sequence_frame_rate()
    local previous_end = Rational.new(0, seq_fps.fps_numerator, seq_fps.fps_denominator)
    local previous_clip_id = nil
    
    for _, clip in ipairs(clips_on_track) do
        local gap_start = previous_end
        local gap_end = clip.timeline_start
        local gap_duration = gap_end - gap_start
        if gap_duration.frames > 0 and time_obj >= gap_start and time_obj < gap_end then
            return {
                track_id = track_id,
                start_value = gap_start,
                duration = gap_duration,
                prev_clip_id = previous_clip_id,
                next_clip_id = clip.id
            }
        end
        previous_end = clip.timeline_start + clip.duration
        previous_clip_id = clip.id
    end
    return nil
end

function M.handle_wheel(view, delta_x, delta_y, modifiers)
    local horizontal = delta_x or 0
    if math.abs(horizontal) < 0.0001 and modifiers and modifiers.shift then
        horizontal = delta_y or 0
    end

    if horizontal and math.abs(horizontal) > 0.0001 then
        local width = timeline.get_dimensions(view.widget)
        if width and width > 0 then
            local viewport_duration = view.state.get_viewport_duration()
            local delta_time = (-horizontal / width) * viewport_duration
            local new_start = view.state.get_viewport_start_time() + delta_time
            view.state.set_viewport_start_time(new_start)
            view.render()
        end
    end
end

local function pick_edges_for_track(state, track_id, cursor_x, viewport_width)
    if not track_id then return nil end
    local track_clips = {}
    for _, clip in ipairs(state.get_clips() or {}) do
        if clip.track_id == track_id then
            track_clips[#track_clips + 1] = clip
        end
    end
    if #track_clips == 0 then return nil end
    return edge_picker.pick_edges(track_clips, cursor_x, viewport_width, {
        edge_zone = ui_constants.TIMELINE.EDGE_ZONE_PX,
        roll_zone = ui_constants.TIMELINE.ROLL_ZONE_PX,
        time_to_pixel = function(time_value)
            return state.time_to_pixel(time_value, viewport_width)
        end
    })
end

local function clone_edge(edge)
    if not edge then return nil end
    return {
        clip_id = edge.clip_id,
        edge_type = edge.edge_type,
        trim_type = edge.trim_type,
        track_id = edge.track_id
    }
end

function M.handle_mouse(view, event_type, x, y, button, modifiers)
    local state = view.state
    local width, height = timeline.get_dimensions(view.widget)

    if event_type == "press" then
        view.pending_gap_click = nil
        if focus_manager and focus_manager.set_focused_panel then pcall(focus_manager.set_focused_panel, "timeline") end
        if qt_set_focus then pcall(qt_set_focus, view.widget) end
        if button == RIGHT_MOUSE_BUTTON then return end -- Context menu handled separately

        -- Playhead
        local playhead_value = state.get_playhead_position()
        local playhead_x = state.time_to_pixel(playhead_value, width)
        if math.abs(x - playhead_x) < 5 then
            state.set_dragging_playhead(true)
            return
        end

        local track_id = view.get_track_id_at_y(y, height)
        local picked_edges = pick_edges_for_track(state, track_id, x, width)
        if picked_edges and picked_edges.selection and #picked_edges.selection > 0 then
            local target_edges = {}
            for _, edge in ipairs(picked_edges.selection) do
                table.insert(target_edges, {
                    clip_id = edge.clip_id,
                    edge_type = edge.edge_type,
                    trim_type = edge.trim_type,
                    track_id = edge.track_id
                })
            end
            local dragged_edge = clone_edge(picked_edges.dragged_edge)
            if not dragged_edge then
                error("edge_picker did not return dragged_edge for selected edges")
            end
            local lead_edge = dragged_edge

            if modifiers and modifiers.command then
                for _, edge in ipairs(target_edges) do
                    state.toggle_edge_selection(edge.clip_id, edge.edge_type, edge.trim_type)
                end
            elseif modifiers and modifiers.shift then
                for _, edge in ipairs(target_edges) do
                    state.toggle_edge_selection(edge.clip_id, edge.edge_type, edge.trim_type)
                end
            elseif not selection_contains_all(state.get_selected_edges(), target_edges) then
                state.set_edge_selection(target_edges)
            end

            view.potential_drag = {
                type = "edges",
                start_x = x,
                start_y = y,
                start_value = state.pixel_to_time(x, width),
                edges = state.get_selected_edges(),
                lead_edge = lead_edge,
                modifiers = modifiers
            }
            view.render()
            return
        end

        -- Clip Selection
        local clicked_clip = find_clip_under_cursor(view, x, y, width, height)
        if clicked_clip then
            local selected_clips = state.get_selected_clips()
            local is_selected = false
            for _, s in ipairs(selected_clips) do if s.id == clicked_clip.id then is_selected = true break end end
            
            if is_selected then
                if modifiers and modifiers.command then
                    -- Deselect
                    local new_sel = {}
                    for _, s in ipairs(selected_clips) do if s.id ~= clicked_clip.id then table.insert(new_sel, s) end end
                    state.set_selection(new_sel)
                    view.render()
                    return
                else
                    -- Prepare drag
                    view.potential_drag = {
                        type = "clips",
                        start_x = x,
                        start_y = y,
                        start_value = state.pixel_to_time(x, width),
                        clips = selected_clips,
                        modifiers = modifiers,
                        anchor_clip_id = clicked_clip.id
                    }
                    return
                end
            else
                if not (modifiers and modifiers.command) then
                    state.clear_edge_selection()
                    state.set_selection({clicked_clip})
                else
                    -- Add
                    local new_sel = {}
                    for _, s in ipairs(selected_clips) do table.insert(new_sel, s) end
                    table.insert(new_sel, clicked_clip)
                    state.set_selection(new_sel)
                end
                
                view.potential_drag = {
                    type = "clips",
                    start_x = x,
                    start_y = y,
                    start_value = state.pixel_to_time(x, width),
                    clips = state.get_selected_clips(),
                    modifiers = modifiers,
                    anchor_clip_id = clicked_clip.id
                }
                view.render()
                return
            end
        end

        -- Gap Selection
        track_id = track_id or view.get_track_id_at_y(y, height)
        if track_id then
            local time = state.pixel_to_time(x, width)
            local gap = find_gap_at_time(view, track_id, time)
            if gap then
                view.pending_gap_click = {
                    initial_gap = gap,
                    command_modifier = modifiers and modifiers.command or false
                }
            end
        end

        -- Empty space drag (Rubber band)
        if not (modifiers and modifiers.command) then
            state.clear_edge_selection()
            state.clear_gap_selection()
            state.set_selection({})
        end
        if view.on_drag_start then
            view.panel_drag_move, view.panel_drag_end = view.on_drag_start(view.widget, x, y, modifiers)
        end

    elseif event_type == "move" then
        if view.potential_drag then
            local dx = math.abs(x - view.potential_drag.start_x)
            local dy = math.abs(y - view.potential_drag.start_y)
            if dx >= DRAG_THRESHOLD or dy >= DRAG_THRESHOLD then
                view.pending_gap_click = nil
                view.drag_state = {
                    type = view.potential_drag.type,
                    start_x = view.potential_drag.start_x,
                    start_y = view.potential_drag.start_y,
                    start_value = view.potential_drag.start_value,
                    clips = view.potential_drag.clips,
                    edges = view.potential_drag.edges,
                    anchor_clip_id = view.potential_drag.anchor_clip_id,
                    lead_edge = view.potential_drag.lead_edge,
                    current_x = x,
                    current_y = y,
                    current_time = state.pixel_to_time(x, width)
                }
                if not view.drag_state.anchor_clip_id and view.drag_state.clips and #view.drag_state.clips > 0 then
                    view.drag_state.anchor_clip_id = view.drag_state.clips[1].id
                end
                local diff = view.drag_state.current_time - view.drag_state.start_value
                view.drag_state.delta_rational = diff
                view.drag_state.delta_ms = math.floor(time_utils.to_milliseconds(diff))
                
                if view.drag_state.type == "edges" then
                    for _, edge in ipairs(view.drag_state.edges) do
                        local clips = state.get_clips()
                        for _, c in ipairs(clips) do
                            if c.id == edge.clip_id then
                                if edge.edge_type == "in" then edge.original_time = c.timeline_start
                                elseif edge.edge_type == "out" then edge.original_time = c.timeline_start + c.duration
                                elseif edge.edge_type == "gap_before" then edge.original_time = c.timeline_start
                                elseif edge.edge_type == "gap_after" then edge.original_time = c.timeline_start + c.duration
                                end
                                break
                            end
                        end
                    end
                end
                view.potential_drag = nil
                view.render()
            end
        elseif view.drag_state then
            view.pending_gap_click = nil
            local current_time = state.pixel_to_time(x, width)

            if keyboard_shortcuts.is_snapping_enabled() then
                if view.drag_state.type == "clips" then
                    local delta = current_time - view.drag_state.start_value
                    local best_snap = nil
                    local best_dist = math.huge
                    for _, c in ipairs(view.drag_state.clips) do
                        local new_in = c.timeline_start + delta
                        local new_out = new_in + c.duration
                        local ex_in = {{clip_id=c.id, edge_type="in"}}
                        local _, si_in = magnetic_snapping.apply_snap(state, new_in, true, {}, ex_in, width)
                        if si_in.snapped and si_in.distance_px < best_dist then best_snap = {time=si_in.snap_point.time, original=new_in}; best_dist = si_in.distance_px end
                        local ex_out = {{clip_id=c.id, edge_type="out"}}
                        local _, si_out = magnetic_snapping.apply_snap(state, new_out, true, {}, ex_out, width)
                        if si_out.snapped and si_out.distance_px < best_dist then best_snap = {time=si_out.snap_point.time, original=new_out}; best_dist = si_out.distance_px end
                    end
                    if best_snap then current_time = current_time + (best_snap.time - best_snap.original) end
                elseif view.drag_state.type == "edges" then
                    local delta = current_time - view.drag_state.start_value
                    local best_snap = nil
                    local best_dist = math.huge
                    for _, edge in ipairs(view.drag_state.edges) do
                        local new_edge = edge.original_time + delta
                        local ex = {{clip_id=edge.clip_id, edge_type=edge.edge_type}}
                        local _, si = magnetic_snapping.apply_snap(state, new_edge, true, {}, ex, width)
                        if si.snapped and si.distance_px < best_dist then best_snap = {time=si.snap_point.time, original=new_edge}; best_dist = si.distance_px end
                    end
                    if best_snap then current_time = current_time + (best_snap.time - best_snap.original) end
                end
            end

            view.drag_state.current_y = y
            if modifiers and modifiers.shift then
                view.drag_state.current_x = view.drag_state.start_x
                view.drag_state.current_time = view.drag_state.start_value
                local zero = view.drag_state.start_value - view.drag_state.start_value
                view.drag_state.delta_rational = zero
                view.drag_state.delta_ms = 0
                view.drag_state.shift_constrained = true
            else
                view.drag_state.current_x = x
                view.drag_state.current_time = current_time
                local diff = current_time - view.drag_state.start_value
                view.drag_state.delta_rational = diff
                view.drag_state.delta_ms = math.floor(time_utils.to_milliseconds(diff))
                view.drag_state.shift_constrained = false
            end
            view.drag_state.alt_copy = (modifiers and modifiers.alt)
            view.render()

        elseif state.is_dragging_playhead() then
            local time = state.pixel_to_time(x, width)
            state.set_playhead_position(time)
        elseif view.panel_drag_move then
            view.pending_gap_click = nil
            view.panel_drag_move(view.widget, x, y)
        else
            -- Hover cursor update
            local cursor = "arrow"

            local track_id = view.get_track_id_at_y and view.get_track_id_at_y(y, height)
            if track_id then
                local hover_pick = pick_edges_for_track(state, track_id, x, width)
                if hover_pick and hover_pick.selection and #hover_pick.selection > 0 then
                    if hover_pick.roll_used and #hover_pick.selection >= 2 then
                        cursor = "split_h"
                    else
                        local sel = hover_pick.selection[1]
                        if hover_pick.zone == "left" then
                            cursor = "trim_left"
                        elseif hover_pick.zone == "right" then
                            cursor = "trim_right"
                        elseif sel and (sel.edge_type == "in" or sel.edge_type == "gap_after") then
                            cursor = "trim_left"
                        else
                            cursor = "trim_right"
                        end
                    end
                end
            end

            qt_set_widget_cursor(view.widget, cursor)
        end

    elseif event_type == "release" then
        if view.potential_drag then view.potential_drag = nil end
        if view.drag_state then
            local drag = view.drag_state
            local drag_handler = require("ui.timeline.view.timeline_view_drag_handler")
            drag_handler.handle_release(view, drag, modifiers)
            
            view.drag_state = nil
            keyboard_shortcuts.reset_drag_snapping()
            view.render()
        elseif view.panel_drag_end then
            view.panel_drag_end(view.widget, x, y)
            view.panel_drag_move = nil; view.panel_drag_end = nil
        end

        if view.pending_gap_click then
            local gap = view.pending_gap_click.initial_gap
            local tid = view.get_track_id_at_y(y, height)
            if tid then
                if view.pending_gap_click.command_modifier then state.toggle_gap_selection(gap)
                else state.set_gap_selection({gap}) end
            end
            view.pending_gap_click = nil
        end
        state.set_dragging_playhead(false)
        view.render()
    end
end

return M
