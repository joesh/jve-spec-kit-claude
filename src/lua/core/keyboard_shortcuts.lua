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
local arrow_repeat = require("ui.arrow_repeat")
local focus_manager = require("ui.focus_manager")
local log = require("core.logger").for_area("ui")

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

    -- Update menu shortcut display text from TOML registry
    -- pcall: menu_system depends on lxp (C library), unavailable in headless tests
    local ok, menu_system = pcall(require, "core.menu_system")
    if ok and menu_system.update_shortcut_display then
        menu_system.update_shortcut_display()
    end
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

    log.detail("handle_key: key=%d modifiers=0x%x combo_key=%d_%d",
        key, modifiers, key, modifiers)

    local modifier_meta = has_modifier(modifiers, MOD.Control) or has_modifier(modifiers, MOD.Meta)
    local modifier_shift = has_modifier(modifiers, MOD.Shift)
    local modifier_alt = has_modifier(modifiers, MOD.Alt)

    local focused_panel = focus_manager.get_focused_panel()
    assert(focused_panel, "keyboard_shortcuts: focus_manager.get_focused_panel() returned nil")

    log.detail("  focused_panel=%s meta=%s shift=%s alt=%s",
        focused_panel, tostring(modifier_meta), tostring(modifier_shift), tostring(modifier_alt))

    local panel_active_timeline = (focused_panel == "timeline")
    local panel_active_source = (focused_panel == "source_monitor")
    local panel_active_tl_view = (focused_panel == "timeline_monitor")
    local panel_active_browser = (focused_panel == "project_browser")
    local focus_is_text_input = event.focus_widget_is_text_input and event.focus_widget_is_text_input ~= 0

    -- Tab/Backtab: GlobalKeyFilter forwards every Tab to us so the user can
    -- bind it (Qt's native focusNextPrevChild can't be reached via QShortcut).
    -- Three cases, exclusive:
    --   1. Floating display-only window (history): redirect focus back to the
    --      last main-window panel — the window has no useful tab group.
    --   2. Floating text-input (find_dialog): defer to Qt so the dialog can
    --      cycle its own fields natively.
    --   3. Main window (incl. timecode QLineEdit): dispatch via TOML registry
    --      using focused_panel. ToggleTimecodeFocus is the default @timeline
    --      binding. No binding → return false → Qt's native cycling (which is
    --      a no-op inside timeline because every widget there is ClickFocus).
    if key == KEY.Tab or key == KEY.Backtab then
        if event.focus_outside_main_window and focus_is_text_input then
            return false  -- find_dialog: native field cycling
        end
        -- Display-only floating window (history): redirect focus AND fire the
        -- panel's Tab binding in the same press — the floating window is
        -- transparent, so Tab should behave exactly as if it had been pressed
        -- with the panel already focused. No "first press to escape" cost.
        if event.focus_outside_main_window then
            log.detail("  → Tab in display-only floating window, redirect to focused panel %s",
                tostring(focused_panel))
            focus_manager.focus_panel(focused_panel)
            -- fall through to the dispatch below
        end
        -- Dispatch via TOML registry. Tab/Shift+Tab in timeline is fully
        -- owned by the command system (default Tab → ToggleTimecodeFocus,
        -- Shift+Tab user-mappable) — never falls back to Qt focusNextPrevChild
        -- so the user can rely on Tab doing exactly what their keymap says,
        -- nothing more. Other panels keep native Qt cycling when no binding
        -- matches — they don't have a ban on dialog-style Tab cycling.
        local registry = require("core.keyboard_shortcut_registry")
        local dispatched = registry.handle_key_event(key, modifiers, focused_panel)
        if dispatched then return true end
        if event.focus_outside_main_window then return true end  -- redirect already happened
        if panel_active_timeline then return true end
        return false
    end

    -- Escape: set global cancel flag — drag/modal handlers consume on next event
    if key == KEY.Escape then
        local cancel = require("core.cancel")
        cancel.request()
        log.detail("  → Escape: cancel flag set")

        -- Exit fullscreen (highest priority)
        local fv = require("ui.fullscreen_viewer")
        if fv.is_active() then
            log.detail("  → Escape exit fullscreen")
            fv.exit()
            return true
        end

        -- Dismiss floating find dialog if visible
        -- pcall: find_dialog depends on dkjson (C lib), unavailable in headless tests
        local find_ok, find_dlg = pcall(require, "ui.find_dialog")
        if find_ok and find_dlg and find_dlg.is_visible() then
            log.detail("  → Escape dismiss floating find dialog")
            find_dlg.hide()
            return true
        end

        -- Dismiss embedded find bar if visible (browser panel)
        local pb = project_browser
        if pb and pb.find_bar and pb.find_bar.visible then
            log.detail("  → Escape dismiss find bar")
            pb.hide_find_bar()
            return true
        end

        -- Cancel timecode entry
        if focus_is_text_input and panel_active_timeline then
            log.detail("  → Escape cancel timecode entry")
            timeline_panel.cancel_timecode_entry()
            return true
        end

        -- Cancel text editing in any panel (rename, etc.)
        if focus_is_text_input then
            log.detail("  → Escape cancel text input")
            return false  -- Let Qt handle Escape on the widget
        end

        -- Not consumed here — drag handlers check cancel.consume() on next event
    end

    -- Non-residual keys: QShortcut handles dispatch (T003/T004).
    -- Qt's ShortcutOverride on QLineEdit provides text input protection.
    -- Only residual keys below (arrows, Comma/Period, E) need Lua handling.
    -- F9/F10 moved to TOML keymap — Insert/Overwrite resolve context via gather_context.

    -- Text-input priority: when focus is on a text-editing widget and the
    -- key is a canonical text-editing key (typing, caret nav, selection,
    -- clipboard, undo/redo, delete), the widget owns it. Return false so Qt
    -- continues delivery to the widget's keyPressEvent. One rule for main-
    -- window and floating-window text input — covers Left/Right/Comma/Period/E
    -- and every macOS editing shortcut (Cmd+A, Shift+Cmd+Z, etc.).
    if focus_is_text_input and event.is_text_editing_key then
        log.detail("  → text-editing key in text input, deferring to widget")
        return false
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

    -- Comma/Period: Nudge clips/edges (context gathering for edges)
    if (key == KEY.Comma or key == KEY.Period) and panel_active_timeline and not modifier_meta and not modifier_alt then
        -- No-active-sequence state: nudge targets a sequence — silent no-op.
        if not timeline_state.get_sequence_id() then return true end

        local nudge_frames = modifier_shift and 5 or 1
        if key == KEY.Comma then nudge_frames = -nudge_frames end

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
        -- No-active-sequence state: ExtendEdit targets a sequence — silent no-op.
        if not timeline_state.get_sequence_id() then return true end

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

    -- Fallback: TOML registry lookup for keys that weren't handled above.
    -- Only when focus is outside the main window (e.g. floating History
    -- window), because QShortcuts scoped to panel containers can't resolve
    -- there. When focus IS inside the main window, QShortcuts handle TOML-
    -- bound keys.
    --
    -- Two flavors of floating window, distinguished by focus_widget_is_text_input:
    --
    -- * Display-only floating window (focus on a non-text widget like the
    --   history tree): the window is transparent to shortcuts. Dispatch via
    --   focus_manager's focused_panel — the last main-window panel that had
    --   focus — so panel-scoped bindings (J → ShuttleReverse @timeline) fire
    --   exactly as if the floating window weren't there.
    --
    -- * Interactive text-input floating window (focus on a QLineEdit/etc in
    --   find_dialog): is_text_editing_key already trapped typing keys above.
    --   Remaining keys (Cmd+S, F-keys, Shift+Cmd+A, …) must NOT dispatch to
    --   any panel — the user is in a text field, not on a panel. Pass nil as
    --   the context so the registry's first (panel-match) pass finds nothing
    --   and only the second (global) pass can fire. Cmd+S still saves;
    --   panel-scoped @timeline DeselectAll does not leak.
    if event.focus_outside_main_window then
        local registry = require("core.keyboard_shortcut_registry")
        -- focus_is_text_input → nil context (globals only — no panel match);
        -- otherwise → focused_panel (display-only floating window is transparent).
        -- Cannot use `and`/`or` chain: `true and nil or focused_panel` collapses
        -- to focused_panel because nil is falsy in Lua's `or`.
        local fallback_context
        if focus_is_text_input then
            fallback_context = nil
        else
            fallback_context = focused_panel
        end
        if registry.handle_key_event(key, modifiers, fallback_context) then
            return true
        end
    end

    log.detail("  → unhandled key=%d modifiers=0x%x (no cascade match)", event.key, event.modifiers)
    return false
end

-- Public entry: wraps handle_key_impl with command event management
function keyboard_shortcuts.handle_key(event)
    assert(initialized, "keyboard_shortcuts.handle_key: not initialized")
    log.detail("handle_key ENTRY: key=%d modifiers=0x%x", event.key, event.modifiers)

    local owns_command_event = not command_manager.peek_command_event_origin()
    if owns_command_event then
        command_manager.begin_command_event("ui")
    end

    local success, result = pcall(handle_key_impl, event)

    if owns_command_event then
        command_manager.end_command_event()
    end

    if not success then
        log.error("handle_key: %s", tostring(result))
        return false
    end
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
