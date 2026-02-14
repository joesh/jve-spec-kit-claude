--- Keyboard dispatch: thin dispatcher + input management
--
-- Responsibilities:
-- - TOML loading → registry for command dispatch
-- - Input management: Tab focus, text input bypass, arrow repeat, key release
-- - Snapping API (backward compat wrappers for external callers)
-- - Zoom fit toggle state, handle_command for zoom
--
-- Non-goals:
-- - Command business logic (moved to core/commands/*)
-- - Mark resolution, delete routing, blade assembly (all in commands)
--
-- @file keyboard_shortcuts.lua
local keyboard_shortcuts = {}
local shortcut_registry = require("core.keyboard_shortcut_registry")
local panel_manager = require("ui.panel_manager")
local kb_constants = require("core.keyboard_constants")
local snapping_state = require("ui.timeline.state.snapping_state")
local undo_redo_controller = require("core.undo_redo_controller")
local arrow_repeat = require("ui.arrow_repeat")
local focus_manager = require("ui.focus_manager")

-- Key and modifier constants
local KEY = kb_constants.KEY
local MOD = kb_constants.MOD

-- Expose for modules that still reference keyboard_shortcuts.KEY/MOD
keyboard_shortcuts.KEY = KEY
keyboard_shortcuts.MOD = MOD

-- Module references (set in init)
local timeline_state = nil
local command_manager = nil
local project_browser = nil
local timeline_panel = nil

-- Zoom fit toggle state
local zoom_fit_toggle_state = nil

local function has_modifier(modifiers, mod)
    local bit = require("bit")
    return bit.band(modifiers, mod) ~= 0
end

local function execute_command(command_name, params)
    assert(command_manager, "KeyboardShortcuts: command_manager not initialized")
    if type(command_manager.execute_ui) == "function" then
        return command_manager.execute_ui(command_name, params)
    end
    return command_manager.execute(command_name, params)
end

-------------------------------------------------------------------------------
-- INIT
-------------------------------------------------------------------------------

function keyboard_shortcuts.init(state, cmd_mgr, proj_browser, panel)
    timeline_state = state
    command_manager = cmd_mgr
    project_browser = proj_browser
    timeline_panel = panel
    undo_redo_controller.clear_toggle()
    zoom_fit_toggle_state = nil

    if shortcut_registry.set_command_manager then
        shortcut_registry.set_command_manager(cmd_mgr)
    end

    if shortcut_registry.load_keybindings then
        local keymap_path = "keymaps/default.jvekeys"
        local f = io.open(keymap_path, "r")
        if not f then
            -- Tests run from tests/ directory
            keymap_path = "../keymaps/default.jvekeys"
            f = io.open(keymap_path, "r")
        end
        if f then
            f:close()
            shortcut_registry.load_keybindings(keymap_path)
        end
    end
end

-------------------------------------------------------------------------------
-- SNAPPING API (backward compat wrappers for external callers)
-------------------------------------------------------------------------------

function keyboard_shortcuts.is_snapping_enabled()
    return snapping_state.is_enabled()
end

function keyboard_shortcuts.toggle_baseline_snapping()
    snapping_state.toggle_baseline()
end

function keyboard_shortcuts.invert_drag_snapping()
    snapping_state.invert_drag()
end

function keyboard_shortcuts.reset_drag_snapping()
    snapping_state.reset_drag()
end

function keyboard_shortcuts.is_dragging()
    if timeline_panel then
        return timeline_panel.is_dragging and timeline_panel.is_dragging() or false
    end
    return false
end

-------------------------------------------------------------------------------
-- ZOOM (still lives here until zoom commands handle toggle state internally)
-------------------------------------------------------------------------------

function keyboard_shortcuts.clear_zoom_toggle()
    zoom_fit_toggle_state = nil
end

local function snapshot_viewport(state)
    assert(state, "snapshot_viewport: timeline state is required")
    if state.capture_viewport then
        local viewport = state.capture_viewport()
        assert(type(viewport) == "table", "snapshot_viewport: capture_viewport must return a table")
        return { start_value = viewport.start_value, duration = viewport.duration }
    end
    assert(state.get_viewport_start_time, "snapshot_viewport: state missing get_viewport_start_time")
    assert(state.get_viewport_duration, "snapshot_viewport: state missing get_viewport_duration")
    return {
        start_value = state.get_viewport_start_time(),
        duration = state.get_viewport_duration(),
    }
end

function keyboard_shortcuts.toggle_zoom_fit(target_state)
    local state = target_state or timeline_state
    if not state then return false end

    local snapshot = snapshot_viewport(state)

    if zoom_fit_toggle_state and zoom_fit_toggle_state.previous_view then
        local prev = zoom_fit_toggle_state.previous_view
        local restore_duration = prev.duration
        if not restore_duration and state.get_viewport_duration then
            local ok, current_duration = pcall(state.get_viewport_duration)
            if ok then restore_duration = current_duration end
        end
        assert(type(restore_duration) == "number", "keyboard_shortcuts: restore_duration must be integer")

        if state.set_viewport_duration then
            state.set_viewport_duration(restore_duration)
        elseif state.restore_viewport then
            pcall(state.restore_viewport, prev)
        end

        if state.get_playhead_position and state.set_viewport_start_time then
            local playhead = state.get_playhead_position()
            if playhead then
                state.set_viewport_start_time(playhead - math.floor(restore_duration / 2))
            end
        end

        zoom_fit_toggle_state = nil
        return true
    end

    local clips = {}
    if state.get_clips then
        local ok, clip_list = pcall(state.get_clips)
        if ok and type(clip_list) == "table" then clips = clip_list end
    end

    local min_start, max_end_time = nil, nil
    for _, clip in ipairs(clips) do
        local start_val = clip.timeline_start or clip.start_value
        local dur_val = clip.duration
        if type(start_val) == "number" and type(dur_val) == "number" then
            local end_val = start_val + dur_val
            if not min_start or start_val < min_start then min_start = start_val end
            if not max_end_time or end_val > max_end_time then max_end_time = end_val end
        end
    end

    if not max_end_time or not min_start then
        zoom_fit_toggle_state = nil
        return false
    end

    zoom_fit_toggle_state = { previous_view = snapshot }
    local duration = max_end_time - min_start
    local buffer = math.max(1, math.floor(duration / 10))
    local fit_duration = duration + buffer

    if state.set_viewport_duration then state.set_viewport_duration(fit_duration) end
    if state.set_viewport_start_time then state.set_viewport_start_time(min_start) end
    return true
end

-- Legacy dispatch for zoom commands (used by test_keyboard_shortcuts_zoom.lua etc.)
function keyboard_shortcuts.handle_command(command_name)
    if command_name == "TimelineZoomFit" then
        return keyboard_shortcuts.toggle_zoom_fit(timeline_state)
    elseif command_name == "TimelineZoomIn" then
        if timeline_state and timeline_state.get_viewport_duration and timeline_state.set_viewport_duration then
            local dur = timeline_state.get_viewport_duration()
            assert(type(dur) == "number", "keyboard_shortcuts: viewport_duration must be integer")
            timeline_state.set_viewport_duration(math.max(30, math.floor(dur * 0.8)))
            return true
        end
    elseif command_name == "TimelineZoomOut" then
        if timeline_state and timeline_state.get_viewport_duration and timeline_state.set_viewport_duration then
            local dur = timeline_state.get_viewport_duration()
            assert(type(dur) == "number", "keyboard_shortcuts: viewport_duration must be integer")
            timeline_state.set_viewport_duration(math.floor(dur * 1.25))
            return true
        end
    end
    return false
end

-- Legacy delete dispatch (still called by some tests)
function keyboard_shortcuts.perform_delete_action(opts)
    opts = opts or {}
    local params = {}
    if opts.shift then params.ripple = true end
    return execute_command("DeleteSelection", params)
end

-------------------------------------------------------------------------------
-- ARROW REPEAT (input management — not command dispatch)
-------------------------------------------------------------------------------

local function step_arrow_frame(dir, shift)
    local literal = shift
        and (dir > 0 and "1s" or "-1s")
        or (dir > 0 and "1f" or "-1f")
    execute_command("MovePlayhead", { _positional = { literal } })
end

-------------------------------------------------------------------------------
-- KEY HANDLER
-------------------------------------------------------------------------------

local function handle_key_impl(event)
    local key = event.key
    local modifiers = event.modifiers

    local modifier_meta = has_modifier(modifiers, MOD.Control) or has_modifier(modifiers, MOD.Meta)
    local modifier_shift = has_modifier(modifiers, MOD.Shift)
    local modifier_alt = has_modifier(modifiers, MOD.Alt)

    local focused_panel = focus_manager.get_focused_panel and focus_manager.get_focused_panel() or nil
    local panel_active_timeline = (focused_panel == "timeline") or not focused_panel
    local panel_active_source = (focused_panel == "source_monitor")
    local panel_active_tl_view = (focused_panel == "timeline_monitor")
    local panel_active_browser = (focused_panel == "project_browser")
    local focus_is_text_input = event.focus_widget_is_text_input and event.focus_widget_is_text_input ~= 0

    -- Tab: toggle timecode entry in timeline
    if key == KEY.Tab and panel_active_timeline and not modifier_meta and not modifier_alt then
        if timeline_panel and timeline_panel.focus_timecode_entry and timeline_panel.focus_timeline_view then
            if focus_is_text_input then
                timeline_panel.focus_timeline_view()
            else
                timeline_panel.focus_timecode_entry()
            end
            return true
        end
    end

    -- Text input bypass: let text fields consume non-modified keys
    if focus_is_text_input and not modifier_meta then
        return false
    end

    -- Registry dispatch (TOML keybindings → command_manager.execute_ui)
    local context = focused_panel or "global"
    if shortcut_registry.handle_key_event(key, modifiers, context) then
        return true
    end

    -- Arrow keys: need special handling for arrow_repeat timer
    -- (Not in TOML because arrow repeat is input management, not command dispatch)
    if (key == KEY.Left or key == KEY.Right) and panel_active_browser then
        return false
    end

    if (key == KEY.Left or key == KEY.Right) and (panel_active_timeline or panel_active_source or panel_active_tl_view) then
        if not modifier_meta and not modifier_alt then
            if event.is_auto_repeat then return true end
            local dir = (key == KEY.Right) and 1 or -1
            arrow_repeat.start(dir, modifier_shift, step_arrow_frame)
            return true
        end
    end

    -- F9/F10: Insert/Overwrite (need project_browser context gathering)
    if key == KEY.F9 and panel_active_timeline then
        if command_manager and project_browser then
            project_browser.add_selected_to_timeline("Insert", { advance_playhead = true })
        end
        return true
    end

    if key == KEY.F10 and panel_active_timeline then
        if command_manager and project_browser then
            project_browser.add_selected_to_timeline("Overwrite", { advance_playhead = true })
        end
        return true
    end

    -- Comma/Period: Nudge clips/edges (context gathering for edges)
    if (key == KEY.Comma or key == KEY.Period) and timeline_state and command_manager and panel_active_timeline and not modifier_meta and not modifier_alt then
        local nudge_frames = modifier_shift and 5 or 1
        if key == KEY.Comma then nudge_frames = -nudge_frames end
        undo_redo_controller.clear_toggle()

        local selected_edges = timeline_state.get_selected_edges()
        local selected_clips = timeline_state.get_selected_clips()
        local project_id = timeline_state.get_project_id and timeline_state.get_project_id()
        local sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id()
        assert(project_id and project_id ~= "", "keyboard_shortcuts: missing project_id for nudge")
        assert(sequence_id and sequence_id ~= "", "keyboard_shortcuts: missing sequence_id for nudge")

        if #selected_edges > 0 then
            local all_clips = timeline_state.get_clips()
            local edge_infos = {}
            for _, edge in ipairs(selected_edges) do
                for _, c in ipairs(all_clips) do
                    if c.id == edge.clip_id then
                        edge_infos[#edge_infos + 1] = {
                            clip_id = edge.clip_id,
                            edge_type = edge.edge_type,
                            track_id = c.track_id,
                            trim_type = edge.trim_type,
                        }
                        break
                    end
                end
            end

            if #edge_infos > 1 then
                execute_command("BatchRippleEdit", {
                    edge_infos = edge_infos, delta_frames = nudge_frames,
                    sequence_id = sequence_id, project_id = project_id,
                })
            elseif #edge_infos == 1 then
                execute_command("RippleEdit", {
                    edge_info = edge_infos[1], delta_frames = nudge_frames,
                    sequence_id = sequence_id, project_id = project_id,
                })
            end
        elseif #selected_clips > 0 then
            local clip_ids = {}
            for _, clip in ipairs(selected_clips) do clip_ids[#clip_ids + 1] = clip.id end
            execute_command("Nudge", {
                nudge_amount = nudge_frames, selected_clip_ids = clip_ids,
                sequence_id = sequence_id, project_id = project_id,
            })
        end
        return true
    end

    -- E: ExtendEdit (needs edge gathering from timeline_state)
    if key == KEY.E and panel_active_timeline and not modifier_meta and not modifier_alt then
        if timeline_state and command_manager then
            local selected_edges = timeline_state.get_selected_edges()
            if not selected_edges or #selected_edges == 0 then
                return true
            end
            local playhead_value = timeline_state.get_playhead_position()
            local project_id = timeline_state.get_project_id and timeline_state.get_project_id()
            local sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id()
            assert(project_id and project_id ~= "", "keyboard_shortcuts: missing project_id for ExtendEdit")
            assert(sequence_id and sequence_id ~= "", "keyboard_shortcuts: missing sequence_id for ExtendEdit")

            local all_clips = timeline_state.get_clips()
            local edge_infos = {}
            for _, edge in ipairs(selected_edges) do
                for _, c in ipairs(all_clips) do
                    if c.id == edge.clip_id then
                        edge_infos[#edge_infos + 1] = {
                            clip_id = edge.clip_id, edge_type = edge.edge_type,
                            track_id = c.track_id, trim_type = edge.trim_type,
                        }
                        break
                    end
                end
            end

            if #edge_infos > 0 then
                execute_command("ExtendEdit", {
                    edge_infos = edge_infos, playhead_frame = playhead_value,
                    project_id = project_id, sequence_id = sequence_id,
                })
            end
        end
        return true
    end

    return false
end

-- Public entry: wraps handle_key_impl with command event management
function keyboard_shortcuts.handle_key(event)
    local can_peek = command_manager and type(command_manager.peek_command_event_origin) == "function"
    local owns_command_event = not command_manager or not can_peek or not command_manager.peek_command_event_origin()
    if owns_command_event then
        if command_manager and type(command_manager.begin_command_event) == "function" then
            command_manager.begin_command_event("ui")
        end
    end

    local success, result = pcall(handle_key_impl, event)

    if owns_command_event then
        if command_manager and type(command_manager.end_command_event) == "function" then
            command_manager.end_command_event()
        end
    end

    if not success then error(result) end
    return result
end

-- Key release: K held state + arrow repeat cancellation
function keyboard_shortcuts.handle_key_release(event)
    local key = event.key
    if event.is_auto_repeat then return false end

    -- K key state managed by ShuttleStop command via playback.lua
    -- But K+J/K+L slow play release needs cascade handling:
    -- The playback command sets k_held in its own module.
    -- For release, check if playback module exposes k_held state.
    local ok_pb, playback = pcall(require, "core.commands.playback")
    if ok_pb and playback then
        if key == KEY.K and playback.set_k_held then
            playback.set_k_held(false)
        end
        if (key == KEY.J or key == KEY.L) and playback.is_k_held and playback.is_k_held() then
            local sv = panel_manager.get_active_sequence_monitor()
            if sv and sv.engine then sv.engine:stop() end
        end
    end

    if key == KEY.Left or key == KEY.Right then
        arrow_repeat.stop()
    end

    return false
end

return keyboard_shortcuts
