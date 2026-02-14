--- Keyboard dispatch: thin dispatcher + input management
--
-- Responsibilities:
-- - TOML loading → registry for command dispatch
-- - Input management: Tab focus, text input bypass, arrow repeat, key release
-- - Context-heavy key handlers (nudge, extend edit, insert/overwrite)
-- - Drag state query (for toggle_snapping command)
--
-- Non-goals:
-- - Command business logic (moved to core/commands/*)
-- - Snapping state (ui/timeline/state/snapping_state.lua)
-- - Zoom state (core/commands/timeline_zoom_*.lua)
--
-- @file keyboard_shortcuts.lua
local keyboard_shortcuts = {}
local shortcut_registry = require("core.keyboard_shortcut_registry")
local panel_manager = require("ui.panel_manager")
local kb_constants = require("core.keyboard_constants")
local undo_redo_controller = require("core.undo_redo_controller")
local arrow_repeat = require("ui.arrow_repeat")
local focus_manager = require("ui.focus_manager")
local logger = require("core.logger")

-- Key and modifier constants
local KEY = kb_constants.KEY
local MOD = kb_constants.MOD

-- Expose for modules that still reference keyboard_shortcuts.KEY/MOD
keyboard_shortcuts.KEY = KEY
keyboard_shortcuts.MOD = MOD

-- Module references (set in init, asserted non-nil)
local timeline_state = nil
local command_manager = nil
local project_browser = nil
local timeline_panel = nil
local initialized = false

local function has_modifier(modifiers, mod)
    local bit = require("bit")
    return bit.band(modifiers, mod) ~= 0
end

local function execute_command(command_name, params)
    assert(type(command_manager.execute_ui) == "function",
        "KeyboardShortcuts: command_manager missing execute_ui()")
    return command_manager.execute_ui(command_name, params)
end

-------------------------------------------------------------------------------
-- INIT
-------------------------------------------------------------------------------

function keyboard_shortcuts.init(state, cmd_mgr, proj_browser, panel)
    assert(state, "keyboard_shortcuts.init: timeline_state required")
    assert(cmd_mgr, "keyboard_shortcuts.init: command_manager required")
    assert(proj_browser, "keyboard_shortcuts.init: project_browser required")
    assert(panel, "keyboard_shortcuts.init: timeline_panel required")

    timeline_state = state
    command_manager = cmd_mgr
    project_browser = proj_browser
    timeline_panel = panel
    initialized = true
    undo_redo_controller.clear_toggle()

    shortcut_registry.set_command_manager(cmd_mgr)

    local keymap_path = "keymaps/default.jvekeys"
    local f = io.open(keymap_path, "r")
    if not f then
        -- Tests run from tests/ directory
        keymap_path = "../keymaps/default.jvekeys"
        f = io.open(keymap_path, "r")
    end
    assert(f, "keyboard_shortcuts.init: keybinding file not found at keymaps/default.jvekeys or ../keymaps/default.jvekeys")
    f:close()
    shortcut_registry.load_keybindings(keymap_path)
end

-------------------------------------------------------------------------------
-- DRAG STATE (used by toggle_snapping command)
-------------------------------------------------------------------------------

function keyboard_shortcuts.is_dragging()
    assert(initialized, "keyboard_shortcuts.is_dragging: not initialized")
    return timeline_panel.is_dragging()
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
    assert(initialized, "keyboard_shortcuts: handle_key called before init")

    local key = event.key
    local modifiers = event.modifiers

    logger.trace("keyboard_shortcuts", string.format(
        "handle_key: key=%d modifiers=0x%x combo_key=%d_%d",
        key, modifiers, key, modifiers))

    local modifier_meta = has_modifier(modifiers, MOD.Control) or has_modifier(modifiers, MOD.Meta)
    local modifier_shift = has_modifier(modifiers, MOD.Shift)
    local modifier_alt = has_modifier(modifiers, MOD.Alt)

    local focused_panel = focus_manager.get_focused_panel()
    assert(focused_panel, "keyboard_shortcuts: focus_manager.get_focused_panel() returned nil")

    logger.trace("keyboard_shortcuts", string.format(
        "  focused_panel=%s meta=%s shift=%s alt=%s",
        focused_panel, tostring(modifier_meta), tostring(modifier_shift), tostring(modifier_alt)))

    local panel_active_timeline = (focused_panel == "timeline")
    local panel_active_source = (focused_panel == "source_monitor")
    local panel_active_tl_view = (focused_panel == "timeline_monitor")
    local panel_active_browser = (focused_panel == "project_browser")
    local focus_is_text_input = event.focus_widget_is_text_input and event.focus_widget_is_text_input ~= 0

    -- Tab: toggle timecode entry in timeline
    if key == KEY.Tab and panel_active_timeline and not modifier_meta and not modifier_alt then
        logger.trace("keyboard_shortcuts", "  → Tab toggle timecode entry")
        if focus_is_text_input then
            timeline_panel.focus_timeline_view()
        else
            timeline_panel.focus_timecode_entry()
        end
        return true
    end

    -- Text input bypass: let text fields consume non-modified keys
    if focus_is_text_input and not modifier_meta then
        logger.trace("keyboard_shortcuts", "  → text input bypass (returning false)")
        return false
    end

    -- Registry dispatch (TOML keybindings → command_manager.execute_ui)
    logger.trace("keyboard_shortcuts", "  → trying registry dispatch")
    if shortcut_registry.handle_key_event(key, modifiers, focused_panel) then
        logger.trace("keyboard_shortcuts", "  → registry handled key")
        return true
    end
    logger.trace("keyboard_shortcuts", "  → registry did NOT handle key")

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
        project_browser.add_selected_to_timeline("Insert", { advance_playhead = true })
        return true
    end

    if key == KEY.F10 and panel_active_timeline then
        project_browser.add_selected_to_timeline("Overwrite", { advance_playhead = true })
        return true
    end

    -- Comma/Period: Nudge clips/edges (context gathering for edges)
    if (key == KEY.Comma or key == KEY.Period) and panel_active_timeline and not modifier_meta and not modifier_alt then
        local nudge_frames = modifier_shift and 5 or 1
        if key == KEY.Comma then nudge_frames = -nudge_frames end
        undo_redo_controller.clear_toggle()

        local selected_edges = timeline_state.get_selected_edges()
        local selected_clips = timeline_state.get_selected_clips()
        local project_id = timeline_state.get_project_id()
        local sequence_id = timeline_state.get_sequence_id()
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
        local selected_edges = timeline_state.get_selected_edges()
        if not selected_edges or #selected_edges == 0 then
            return true
        end
        local playhead_value = timeline_state.get_playhead_position()
        local project_id = timeline_state.get_project_id()
        local sequence_id = timeline_state.get_sequence_id()
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
        return true
    end

    logger.trace("keyboard_shortcuts", string.format(
        "  → unhandled key=%d modifiers=0x%x (no cascade match)", event.key, event.modifiers))
    return false
end

-- Public entry: wraps handle_key_impl with command event management
function keyboard_shortcuts.handle_key(event)
    assert(initialized, "keyboard_shortcuts.handle_key: not initialized")
    logger.trace("keyboard_shortcuts", string.format(
        "handle_key ENTRY: key=%d modifiers=0x%x", event.key, event.modifiers))

    local owns_command_event = not command_manager.peek_command_event_origin()
    if owns_command_event then
        command_manager.begin_command_event("ui")
    end

    local success, result = pcall(handle_key_impl, event)

    if owns_command_event then
        command_manager.end_command_event()
    end

    if not success then error(result) end
    return result
end

-- Key release: K held state + arrow repeat cancellation
function keyboard_shortcuts.handle_key_release(event)
    local key = event.key
    if event.is_auto_repeat then return false end

    local playback = require("core.commands.playback")
    if key == KEY.K then
        playback.set_k_held(false)
    end
    if (key == KEY.J or key == KEY.L) and playback.is_k_held() then
        local sv = panel_manager.get_active_sequence_monitor()
        if sv and sv.engine then sv.engine:stop() end
    end

    if key == KEY.Left or key == KEY.Right then
        arrow_repeat.stop()
    end

    return false
end

return keyboard_shortcuts
