--- Keyboard dispatch: thin dispatcher + input management
--
-- Responsibilities:
-- - TOML loading → registry for command dispatch
-- - Input management: Tab focus, text input bypass, arrow repeat, key release
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
local command_manager = nil
local timeline_panel = nil
local initialized = false

local function has_modifier(modifiers, mod)
    local bit = require("bit")
    return bit.band(modifiers, mod) ~= 0
end

local function execute_command(command_name, params)
    assert(type(command_manager.execute_interactive) == "function",
        "KeyboardShortcuts: command_manager missing execute_interactive()")
    return command_manager.execute_interactive(command_name, params)
end

-------------------------------------------------------------------------------
-- INIT
-------------------------------------------------------------------------------

function keyboard_shortcuts.init(cmd_mgr, _, panel)
    assert(cmd_mgr, "keyboard_shortcuts.init: command_manager required")
    assert(panel, "keyboard_shortcuts.init: timeline_panel required")

    command_manager = cmd_mgr
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
    -- Load active user preset if one is set, otherwise the bundled default.
    -- loaded_toml_path always points at the bundled default so reset_to_defaults works.
    shortcut_registry.load_active_or_default(keymap_path)

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

-- ============================================================================
-- handle_key_impl — per-key dispatch handlers
-- ============================================================================
--
-- Each handler returns:
--   nil   — key not handled here; caller falls through to the next case
--   true  — key consumed
--   false — key not consumed (let Qt dispatch natively)

-- Tab/Backtab: GlobalKeyFilter forwards every Tab to us so the user can
-- bind it (Qt's native focusNextPrevChild can't be reached via QShortcut).
-- Arrow keys: timeline frame-step with arrow_repeat timer. Browser delegates
-- left/right to Qt for tree navigation; non-timeline panels fall through.
-- (Not in TOML because arrow repeat is input management, not command
-- dispatch.)
local function try_handle_arrow_keys(event, key, panel_active_browser,
                                     panel_active_timeline, panel_active_source,
                                     panel_active_tl_view, modifier_meta,
                                     modifier_alt, modifier_shift)
    if key ~= KEY.Left and key ~= KEY.Right then return nil end
    if panel_active_browser then return false end
    if not (panel_active_timeline or panel_active_source or panel_active_tl_view) then
        return nil
    end
    if modifier_meta or modifier_alt then return nil end
    if event.is_auto_repeat then return true end
    local dir = (key == KEY.Right) and 1 or -1
    arrow_repeat.start(dir, modifier_shift, step_arrow_frame)
    return true
end

-- Floating-window fallback: TOML registry lookup for keys that weren't
-- handled above. Only fires when focus is outside the main window (e.g.
-- floating History). When focus IS inside the main window, QShortcuts
-- handle TOML-bound keys.
--
-- Two flavors of floating window, distinguished by focus_is_text_input:
--   * Display-only floating window (history tree): transparent to
--     shortcuts. Dispatch via the focused panel — panel-scoped bindings
--     (J → ShuttleReverse @timeline) fire as if the floating window
--     weren't there.
--   * Interactive text-input floating window (QLineEdit in find_dialog):
--     is_text_editing_key already trapped typing keys above. Remaining
--     keys (Cmd+S, F-keys, …) must NOT dispatch to any panel — user is
--     in a text field. Pass nil context so only the global pass fires.
local function try_handle_floating_window_fallback(event, key, modifiers,
                                                   focused_panel, focus_is_text_input)
    if not event.focus_outside_main_window then return nil end
    local registry = require("core.keyboard_shortcut_registry")
    local fallback_context
    if focus_is_text_input then
        fallback_context = nil
    else
        fallback_context = focused_panel
    end
    if registry.handle_key_event(key, modifiers, fallback_context) then
        return true
    end
    return nil
end

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

    -- Dispatch through per-key handlers. Each returns nil to fall through.
    -- Order: Tab → Escape → arrow keys → floating-window TOML fallback.
    -- Tab, Escape, Comma, Period, E used to live here as a residual cascade;
    -- they now bind in TOML and dispatch via the QShortcut path or the thin
    -- handlers below.

    local r

    -- Tab/Backtab: GlobalKeyFilter forwards every Tab to us so the user can
    -- bind it (Qt's native focusNextPrevChild can't be reached via QShortcut).
    if key == KEY.Tab or key == KEY.Backtab then
        if event.focus_outside_main_window and focus_is_text_input then
            return false  -- find_dialog: native field cycling
        end
        if event.focus_outside_main_window then
            focus_manager.focus_panel(focused_panel)
        end
        -- Dispatch via TOML registry. Tab → CycleFocus is the default.
        local registry = require("core.keyboard_shortcut_registry")
        if registry.handle_key_event(key, modifiers, focused_panel) then
            return true
        end
        return true  -- last resort: consume rather than let native cycling escape
    end

    -- Text-input priority: when focus is on a text-editing widget and the
    -- key is a canonical text-editing key (typing, caret nav, selection,
    -- clipboard, undo/redo, delete, OR ESCAPE to cancel entry), the widget
    -- owns it. Return false so Qt continues delivery to the widget's
    -- keyPressEvent. One rule for main-window and floating-window text
    -- input — covers Left/Right and every macOS editing shortcut (Cmd+A,
    -- Shift+Cmd+Z, etc.).
    if focus_is_text_input and (event.is_text_editing_key or key == KEY.Escape) then
        if key == KEY.Escape and panel_active_timeline then
            log.detail("  → Escape in timeline text input, canceling TC entry")
            timeline_panel.cancel_timecode_entry()
            return true
        end
        -- Escape in non-timeline text input falls through to the registry
        -- dispatch below so the Cancel command can dismiss a visible find
        -- bar / floating dialog / fullscreen — none of which a QLineEdit
        -- handles natively. Text-editing keys (caret nav, typing, clipboard)
        -- still defer to the widget.
        if key ~= KEY.Escape then
            log.detail("  → text-editing key in text input, deferring to widget")
            return false
        end
    end

    -- Escape: dispatch via TOML registry to reach the 'Cancel' command.
    if key == KEY.Escape then
        local registry = require("core.keyboard_shortcut_registry")
        local params = { focus_is_text_input = focus_is_text_input }
        if registry.handle_key_event(key, modifiers, focused_panel, params) then
            return true
        end
    end

    r = try_handle_arrow_keys(event, key, panel_active_browser, panel_active_timeline,
        panel_active_source, panel_active_tl_view, modifier_meta, modifier_alt, modifier_shift)
    if r ~= nil then return r end

    r = try_handle_floating_window_fallback(event, key, modifiers,
        focused_panel, focus_is_text_input)
    if r ~= nil then return r end

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
