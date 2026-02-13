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
-- Size: ~445 LOC
-- Volatility: unknown
--
-- @file timeline_view_input.lua
-- Original intent (unreviewed):
-- Timeline View Input Handler
-- Manages mouse and keyboard interactions
local M = {}
local ui_constants = require("core.ui_constants")
local edge_picker = require("ui.timeline.edge_picker")
local keyboard_shortcuts = require("core.keyboard_shortcuts")
local focus_manager = require("ui.focus_manager")
local magnetic_snapping = require("core.magnetic_snapping")
local TimelineActiveRegion = require("core.timeline_active_region")
local command_manager = require("core.command_manager")

local RIGHT_MOUSE_BUTTON = 2
local DRAG_THRESHOLD = ui_constants.TIMELINE.DRAG_THRESHOLD
local qt_constants = require("core.qt_constants")
local logger = require("core.logger")

local function edges_match(a, b)
    return a and b
        and a.clip_id == b.clip_id
        and a.edge_type == b.edge_type
        and (a.trim_type or "ripple") == (b.trim_type or "ripple")
end

-- luacheck: ignore 211 (selection_contains_all - unused for now, kept for future use)
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
    if not state.get_track_clip_index then
        error("timeline_view_input: state.get_track_clip_index is required", 2)
    end

    local track_id = view.get_track_id_at_y(y, height)
    if not track_id then
        return nil
    end

    local track_clips = state.get_track_clip_index(track_id)
    if not track_clips or #track_clips == 0 then
        return nil
    end

    -- pixel_to_time now returns integer frame
    local target_frames = state.pixel_to_time(x, width)
    if type(target_frames) ~= "number" then
        return nil
    end

    -- Binary search to find the first clip starting at or after the cursor time,
    -- then check the previous clip for overlap.
    local lo = 1
    local hi = #track_clips
    local idx = #track_clips + 1
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local clip = track_clips[mid]
        local start_frames = type(clip.timeline_start) == "number" and clip.timeline_start or nil
        if start_frames and start_frames >= target_frames then
            idx = mid
            hi = mid - 1
        else
            lo = mid + 1
        end
    end
    if idx > 1 then
        idx = idx - 1
    end

    for i = idx, #track_clips do
        local clip = track_clips[i]
        if type(clip.timeline_start) ~= "number" or type(clip.duration) ~= "number" then
            goto continue_clip
        end
        local start_frames = clip.timeline_start
        if start_frames > target_frames then
            break
        end
        local end_frames = start_frames + clip.duration
        if target_frames >= start_frames and target_frames <= end_frames then
            return clip
        end
        ::continue_clip::
    end
    return nil
end

local function find_gap_at_time(view, track_id, time_frame)
    if not track_id or type(time_frame) ~= "number" then return nil end
    local state = view.state
    if not state.get_track_clip_index then
        error("timeline_view_input: state.get_track_clip_index is required", 2)
    end
    local clips_on_track = state.get_track_clip_index(track_id)
    if not clips_on_track or #clips_on_track == 0 then
        return nil
    end

    local previous_end = 0
    local previous_clip_id = nil

    for _, clip in ipairs(clips_on_track) do
        if type(clip.timeline_start) ~= "number" or type(clip.duration) ~= "number" then
            goto continue_clip
        end
        local gap_start = previous_end
        local gap_end = clip.timeline_start
        local gap_duration = gap_end - gap_start
        if gap_duration > 0 and time_frame >= gap_start and time_frame < gap_end then
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
        ::continue_clip::
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
            local new_start = math.floor(view.state.get_viewport_start_time() + delta_time)
            view.state.set_viewport_start_time(new_start)
            view.render()
        end
    end
end

-- Scan the requested track for clips near the cursor and return whichever edges
-- fall inside the configured trim zone. Returns nil when no handles are within range.
local function pick_edges_for_track(state, track_id, cursor_x, viewport_width)
    if not track_id then return nil end
    if not state.get_track_clip_index then
        error("timeline_view_input: state.get_track_clip_index is required", 2)
    end
    local track_clips = state.get_track_clip_index(track_id)
    if not track_clips or #track_clips == 0 then return nil end
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

--- Show context menu for timeline clips
-- @param view Timeline view
-- @param x Mouse x position (widget-local)
-- @param y Mouse y position (widget-local)
-- @param clicked_clip The clip under cursor (or nil)
-- @param event The mouse event object (may contain global_x, global_y)
local function show_clip_context_menu(view, x, y, clicked_clip, event)
    local state = view.state
    local _width, _height = timeline.get_dimensions(view.widget)

    -- Get global mouse position for popup
    -- First check if event has global coordinates (like project_browser)
    local global_x = event and event.global_x and math.floor(event.global_x) or nil
    local global_y = event and event.global_y and math.floor(event.global_y) or nil

    -- Fall back to coordinate conversion
    if (not global_x or not global_y) and qt_constants.WIDGET and qt_constants.WIDGET.MAP_TO_GLOBAL then
        global_x, global_y = qt_constants.WIDGET.MAP_TO_GLOBAL(view.widget, math.floor(x), math.floor(y))
    end

    -- Last resort: use local coords (won't be positioned correctly)
    if not global_x or not global_y then
        global_x, global_y = math.floor(x), math.floor(y)
    end

    -- If right-clicking on a clip that's not selected, select it first
    local selected_clips = state.get_selected_clips and state.get_selected_clips() or {}
    if clicked_clip then
        local is_selected = false
        for _, s in ipairs(selected_clips) do
            if s.id == clicked_clip.id then is_selected = true; break end
        end
        if not is_selected then
            command_manager.execute("SelectClips", {
                project_id = state.get_project_id(),
                sequence_id = state.get_sequence_id(),
                target_clip_ids = { clicked_clip.id },
            })
            selected_clips = state.get_selected_clips and state.get_selected_clips() or {}
        end
    end

    if #selected_clips == 0 then
        return  -- No clips selected, no menu
    end

    local actions = {}

    -- Reveal in Filesystem (only for clips with media)
    local has_media = false
    for _, clip in ipairs(selected_clips) do
        if clip.media_id then has_media = true; break end
    end
    if has_media then
        table.insert(actions, {
            label = "Reveal in Filesystem",
            handler = function()
                local result = command_manager.execute("RevealInFilesystem", {
                    project_id = state.get_project_id(),
                    sequence_id = state.get_sequence_id(),
                    source = "timeline",
                })
                if result and not result.success then
                    logger.warn("timeline_clip_context", "Reveal failed: " .. (result.error_message or "unknown"))
                end
            end
        })
    end

    -- Match Frame
    table.insert(actions, {
        label = "Match Frame",
        handler = function()
            command_manager.execute("MatchFrame", {
                project_id = state.get_project_id(),
                sequence_id = state.get_sequence_id(),
            })
        end
    })

    -- Separator (visual grouping)
    table.insert(actions, { separator = true })

    -- Split at Playhead
    table.insert(actions, {
        label = "Split at Playhead",
        shortcut = "S",
        handler = function()
            command_manager.execute("Split", {
                project_id = state.get_project_id(),
                sequence_id = state.get_sequence_id(),
            })
        end
    })

    -- Delete
    table.insert(actions, {
        label = "Delete",
        shortcut = "Delete",
        handler = function()
            command_manager.execute("DeleteClip", {
                project_id = state.get_project_id(),
                sequence_id = state.get_sequence_id(),
            })
        end
    })

    -- Ripple Delete
    table.insert(actions, {
        label = "Ripple Delete",
        shortcut = "Shift+Delete",
        handler = function()
            command_manager.execute("RippleDeleteSelection", {
                project_id = state.get_project_id(),
                sequence_id = state.get_sequence_id(),
            })
        end
    })

    table.insert(actions, { separator = true })

    -- Enable/Disable
    table.insert(actions, {
        label = "Toggle Enabled",
        shortcut = "D",
        handler = function()
            command_manager.execute("ToggleClipEnabled", {
                project_id = state.get_project_id(),
                sequence_id = state.get_sequence_id(),
            })
        end
    })

    if #actions == 0 then
        return
    end

    -- Create and show the menu
    -- The timeline's custom OpenGL widget may not work as a menu parent.
    -- Use the project_browser's tree widget which is known to work.
    local parent = view.widget
    local ok, project_browser = pcall(require, "ui.project_browser")
    if ok and project_browser and project_browser.tree then
        parent = project_browser.tree
    end
    local menu = qt_constants.MENU.CREATE_MENU(parent, "TimelineClipContext")
    for _, action_def in ipairs(actions) do
        if action_def.separator then
            qt_constants.MENU.ADD_MENU_SEPARATOR(menu)
        else
            local label = action_def.label
            if action_def.shortcut then
                label = label .. "\t" .. action_def.shortcut
            end
            local qt_action = qt_constants.MENU.CREATE_MENU_ACTION(menu, label)
            if action_def.enabled == false then
                qt_constants.MENU.SET_ACTION_ENABLED(qt_action, false)
            else
                qt_constants.MENU.CONNECT_MENU_ACTION(qt_action, function()
                    action_def.handler()
                end)
            end
        end
    end

    qt_constants.MENU.SHOW_POPUP(menu, math.floor(global_x or 0), math.floor(global_y or 0))
end

function M.handle_mouse(view, event_type, x, y, button, modifiers)
    local state = view.state
    local width, height = timeline.get_dimensions(view.widget)

    if event_type == "press" then
        view.pending_gap_click = nil
        if focus_manager and focus_manager.set_focused_panel then pcall(focus_manager.set_focused_panel, "timeline") end
        if qt_set_focus then pcall(qt_set_focus, view.widget) end

        -- Right-click: show context menu
        if button == RIGHT_MOUSE_BUTTON then
            local clicked_clip = find_clip_under_cursor(view, x, y, width, height)
            show_clip_context_menu(view, x, y, clicked_clip, modifiers)  -- modifiers is the event object
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

            -- Execute SelectEdges command (handles Option→linked, Cmd/Shift→toggle)
            command_manager.execute("SelectEdges", {
                project_id = state.get_project_id(),
                sequence_id = state.get_sequence_id(),
                target_edges = target_edges,
                modifiers = modifiers,
            })

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

        -- Clip Selection (via SelectClips command)
        local clicked_clip = find_clip_under_cursor(view, x, y, width, height)
        if clicked_clip then
            local selected_clips = state.get_selected_clips()
            local is_selected = false
            for _, s in ipairs(selected_clips) do if s.id == clicked_clip.id then is_selected = true break end end

            -- Execute SelectClips command (handles Option→linked, Cmd→toggle)
            command_manager.execute("SelectClips", {
                project_id = state.get_project_id(),
                sequence_id = state.get_sequence_id(),
                target_clip_ids = { clicked_clip.id },
                modifiers = modifiers,
            })

            -- For already-selected clips without Cmd: just prepare drag, no selection change
            -- SelectClips handles this by returning same selection
            if is_selected and not (modifiers and modifiers.command) then
                view.potential_drag = {
                    type = "clips",
                    start_x = x,
                    start_y = y,
                    start_value = state.pixel_to_time(x, width),
                    clips = state.get_selected_clips(),
                    modifiers = modifiers,
                    anchor_clip_id = clicked_clip.id
                }
                return
            end

            -- Prepare drag with newly selected clips
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
                -- Gap click pending - don't fall through to playhead
                return
            end
        end

        -- Playhead (lowest priority - only if no edge, clip, or gap was clicked)
        local playhead_value = state.get_playhead_position()
        local playhead_x = state.time_to_pixel(playhead_value, width)
        if math.abs(x - playhead_x) < 5 then
            -- Stop playback on click (standard NLE: click-to-park)
            local pm = require("ui.panel_manager")
            local tl_sv = pm.get_sequence_view("timeline_view")
            if tl_sv and tl_sv.engine:is_playing() then
                tl_sv.engine:stop()
            end
            state.set_dragging_playhead(true)
            return
        end

        -- Empty space drag (Rubber band)
        if not (modifiers and modifiers.command) then
            command_manager.execute("DeselectAll", {
                project_id = state.get_project_id(),
                sequence_id = state.get_sequence_id(),
            })
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
                view.drag_state.delta_frames = diff
                
                if view.drag_state.type == "edges" then
                    for _, edge in ipairs(view.drag_state.edges) do
                        local c = state.get_clip_by_id and state.get_clip_by_id(edge.clip_id) or nil
                        if c and c.timeline_start and c.duration then
                            if edge.edge_type == "in" then edge.original_time = c.timeline_start
                            elseif edge.edge_type == "out" then edge.original_time = c.timeline_start + c.duration
                            elseif edge.edge_type == "gap_before" then edge.original_time = c.timeline_start
                            elseif edge.edge_type == "gap_after" then edge.original_time = c.timeline_start + c.duration
                            end
                        end
                    end

                    -- Compute and cache the active interaction region + snapshot once at drag start.
                    local rate = state.get_sequence_frame_rate and state.get_sequence_frame_rate() or nil
                    assert(rate and rate.fps_numerator and rate.fps_denominator, "timeline_view_input: missing sequence frame rate for TimelineActiveRegion")
                    local multiplier = ui_constants.TIMELINE.ACTIVE_REGION_PAD_FRAMES_MULTIPLIER
                    assert(type(multiplier) == "number" and multiplier > 0, "timeline_view_input: ui_constants.TIMELINE.ACTIVE_REGION_PAD_FRAMES_MULTIPLIER must be set")
                    view.drag_state.timeline_active_region = TimelineActiveRegion.compute_for_edge_drag(state, view.drag_state.edges, {
                        pad_frames = rate.fps_numerator * multiplier
                    })
                    view.drag_state.preloaded_clip_snapshot = TimelineActiveRegion.build_snapshot_for_region(state, view.drag_state.timeline_active_region)

                    -- Share edge drag state across timeline panes so only one preview computation runs.
                    state.set_active_edge_drag_state(view.drag_state)
                end
                view.potential_drag = nil
                if view.drag_state.type ~= "edges" then
                    view.render()
                end
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
                    local snap_opts = nil
                    if view.drag_state.preloaded_clip_snapshot then
                        snap_opts = {clip_snapshot = view.drag_state.preloaded_clip_snapshot}
                    end
                    for _, edge in ipairs(view.drag_state.edges) do
                        local new_edge = edge.original_time + delta
                        local ex = {{clip_id=edge.clip_id, edge_type=edge.edge_type}}
                        local _, si = magnetic_snapping.apply_snap(state, new_edge, true, {}, ex, width, snap_opts)
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
                view.drag_state.delta_frames = zero
                view.drag_state.shift_constrained = true
            else
                view.drag_state.current_x = x
                view.drag_state.current_time = current_time
                local diff = current_time - view.drag_state.start_value
                view.drag_state.delta_frames = diff
                view.drag_state.shift_constrained = false
            end
            view.drag_state.alt_copy = (modifiers and modifiers.alt)
            if view.drag_state.type == "edges" then
                state.set_active_edge_drag_state(view.drag_state)
            else
                view.render()
            end

        elseif state.is_dragging_playhead() then
            local time = state.pixel_to_time(x, width)
            state.set_playhead_position(time)
            command_manager.execute("SetPlayhead", {
                project_id = state.get_project_id(),
                sequence_id = state.get_sequence_id(),
                playhead_position = time,
            })
        elseif view.panel_drag_move then
            view.pending_gap_click = nil
            view.panel_drag_move(view.widget, x, y)
        else
            -- Hover cursor update
            -- IMPORTANT: Cursor MUST reflect what will happen on click.
            -- Base cursor on the actual selected edge type, not on zone position.
            local cursor = "arrow"

            local track_id = view.get_track_id_at_y and view.get_track_id_at_y(y, height)
            if track_id then
                local hover_pick = pick_edges_for_track(state, track_id, x, width)
                if hover_pick and hover_pick.selection and #hover_pick.selection > 0 then
                    if hover_pick.roll_used and #hover_pick.selection >= 2 then
                        cursor = "split_h"
                    else
                        -- Single edge selection: cursor based on edge type
                        -- From misc_bindings.cpp: trim_left = ] bracket, trim_right = [ bracket
                        -- Must match renderer logic (timeline_view_renderer.lua:429):
                        --   is_in = (normalized_edge == "in") or (raw_edge_type == "gap_after")
                        -- So: "in" or "gap_after" → [ bracket → trim_right
                        --     "out" or "gap_before" → ] bracket → trim_left
                        local sel = hover_pick.selection[1]
                        if sel and (sel.edge_type == "in" or sel.edge_type == "gap_after") then
                            cursor = "trim_right"
                        else
                            cursor = "trim_left"
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

            if drag.type == "edges" then
                state.clear_active_edge_drag_state()
            end
            view.drag_state = nil
            keyboard_shortcuts.reset_drag_snapping()
            if drag.type ~= "edges" then
                view.render()
            end
        elseif view.panel_drag_end then
            view.panel_drag_end(view.widget, x, y)
            view.panel_drag_move = nil; view.panel_drag_end = nil
        end

        if view.pending_gap_click then
            local gap = view.pending_gap_click.initial_gap
            local tid = view.get_track_id_at_y(y, height)
            if tid then
                -- Execute SelectGaps command (handles Cmd→toggle)
                command_manager.execute("SelectGaps", {
                    project_id = state.get_project_id(),
                    sequence_id = state.get_sequence_id(),
                    target_gaps = { gap },
                    modifiers = { command = view.pending_gap_click.command_modifier },
                })
            end
            view.pending_gap_click = nil
        end
        state.set_dragging_playhead(false)
        view.render()
    end
end

return M
