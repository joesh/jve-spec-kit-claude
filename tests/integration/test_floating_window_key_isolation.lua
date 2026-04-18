--- Integration test: keystrokes from floating tool windows must not leak
--- to the main window's timeline commands.
---
--- Regression coverage for find_dialog (and other Qt::Tool windows like the
--- edit-history window) leaking j/k/l, bare Delete/Backspace, Cmd+A,
--- Shift+Cmd+A, Shift+arrow, Cmd+C/V/X/Z, Shift+Cmd+Z into the timeline.
---
--- The bug lives in two places:
---   1. The Lua fallback at keyboard_shortcuts.lua (focus_outside_main_window
---      branch) does not guard against text-input focus for non-residual keys
---      and for Delete/Backspace.
---   2. The same fallback passes the stale `focused_panel` from focus_manager
---      (which only tracks main-window panels), so panel-scoped bindings like
---      `@timeline` spuriously match when the focus has actually moved to a
---      floating tool window that focus_manager never registered.
---
--- This test drives `keyboard_shortcuts.handle_key` directly with event tables
--- that mirror what the C++ GlobalKeyFilter produces in each scenario. It
--- verifies the Lua policy — not the C++ ShortcutOverride / QShortcut path,
--- which has its own coverage in test_keyboard_qshortcut_integration.lua.
---
--- Run:
---   ./build/bin/JVEEditor --test tests/integration/test_floating_window_key_isolation.lua

local ui = require("integration.ui_test_env")

print("=== test_floating_window_key_isolation ===")

local _, _ = ui.launch({  -- luacheck: ignore 211
    project_name = "Floating Window Key Isolation Test",
    num_sequences = 1,
})

local keyboard_shortcuts = require("core.keyboard_shortcuts")
local command_manager    = require("core.command_manager")
local focus_manager      = require("ui.focus_manager")

local pass_count = 0
local function pass(label)
    pass_count = pass_count + 1
    print(string.format("  ✅ %s", label))
end

local function fail(label, msg)
    io.stderr:write(string.format("  ❌ %s: %s\n", label, msg or ""))
    ui.cleanup()
    os.exit(1)
end

local function check(label, cond, msg)
    if not cond then fail(label, msg) end
    pass(label)
end

-- Qt key codes (from keyboard_constants.lua / Qt headers).
local KEY_J, KEY_K, KEY_L         = 0x4a, 0x4b, 0x4c
local KEY_A, KEY_C, KEY_V, KEY_X  = 0x41, 0x43, 0x56, 0x58
local KEY_Z, KEY_S                = 0x5a, 0x53
local KEY_DELETE    = 0x01000007
local KEY_BACKSPACE = 0x01000003
local KEY_LEFT      = 0x01000012
local KEY_RIGHT     = 0x01000014
local KEY_HOME      = 0x01000010
local KEY_ESCAPE    = 0x01000000
local KEY_TAB       = 0x01000001

-- Qt modifiers. On macOS Qt::ControlModifier maps to Cmd, Qt::MetaModifier to Ctrl.
local MOD_SHIFT = 0x02000000
local MOD_CTRL  = 0x04000000

---------------------------------------------------------------------------
-- Intercept command_manager.execute_interactive so we can observe which commands
-- would fire, without actually executing them (avoids state pollution).
-- Also stub get_executor so the registry's "has executor" assert doesn't
-- fire for commands whose modules aren't loaded in the headless test env.
---------------------------------------------------------------------------
local dispatched = {}
local orig_execute_interactive = command_manager.execute_interactive
local orig_get_executor = command_manager.get_executor
command_manager.execute_interactive = function(name, params)
    dispatched[#dispatched + 1] = { name = name, params = params }
    return { success = true }
end
command_manager.get_executor = function(_) return function() end end

local function clear_dispatched() dispatched = {} end

local function has_dispatched(name)
    for _, e in ipairs(dispatched) do
        if e.name == name then return true end
    end
    return false
end

local function dispatched_names()
    local names = {}
    for _, e in ipairs(dispatched) do names[#names + 1] = e.name end
    return table.concat(names, ", ")
end

---------------------------------------------------------------------------
-- Event table builders matching what GlobalKeyFilter produces after the
-- C++ helper `is_text_editing_key` lands.
---------------------------------------------------------------------------

-- Focus is inside a floating tool window (Qt::Tool), on a text-input widget.
-- This is the find_dialog QLineEdit scenario.
local function floating_text_event(key, modifiers, is_editing_key)
    return {
        key                       = key,
        modifiers                 = modifiers or 0,
        text                      = "",
        is_auto_repeat            = false,
        focus_widget_is_text_input = true,
        focus_outside_main_window = true,
        is_text_editing_key       = (is_editing_key ~= false),
    }
end

-- Focus is inside a floating tool window but on a non-text widget
-- (e.g. a QTreeWidget in edit_history_window).
local function floating_nontext_event(key, modifiers)
    return {
        key                       = key,
        modifiers                 = modifiers or 0,
        text                      = "",
        is_auto_repeat            = false,
        focus_widget_is_text_input = false,
        focus_outside_main_window = true,
        is_text_editing_key       = false,
    }
end

---------------------------------------------------------------------------
-- PHASE 1: text input inside a floating tool window.
-- For every standard text-editing key, handle_key MUST return false so that
-- Qt continues delivery to the widget. No timeline command may dispatch.
---------------------------------------------------------------------------
print("\n--- Phase 1: floating-window text input traps edit keys ---")

-- Simulate the bug precondition: focus_manager's last known panel is
-- "timeline" (the user opened Find from the timeline). The fallback must
-- NOT trust this value once focus has moved to a floating window.
focus_manager.set_focused_panel("timeline")

-- j / k / l are bare letters. Bound @timeline. Must be trapped.
for _, entry in ipairs({
    { key = KEY_J, label = "bare j", cmd_guard = "ShuttleReverse" },
    { key = KEY_K, label = "bare k", cmd_guard = "ShuttleStop" },
    { key = KEY_L, label = "bare l", cmd_guard = "ShuttleForward" },
}) do
    clear_dispatched()
    local handled = keyboard_shortcuts.handle_key(floating_text_event(entry.key, 0, true))
    check(entry.label .. " in floating text input: not consumed",
        not handled,
        "handler consumed the key; widget will never see it")
    check(entry.label .. " in floating text input: no timeline dispatch",
        not has_dispatched(entry.cmd_guard),
        entry.cmd_guard .. " fired from floating text input; dispatched: " .. dispatched_names())
end

-- bare Delete / Backspace. Bound globally (no @context) — highest-risk leak.
for _, entry in ipairs({
    { key = KEY_DELETE,    label = "bare Delete"    },
    { key = KEY_BACKSPACE, label = "bare Backspace" },
}) do
    clear_dispatched()
    local handled = keyboard_shortcuts.handle_key(floating_text_event(entry.key, 0, true))
    check(entry.label .. " in floating text input: not consumed",
        not handled, "handler consumed the key")
    check(entry.label .. " in floating text input: no DeleteSelection",
        not has_dispatched("DeleteSelection"),
        "DeleteSelection fired; dispatched: " .. dispatched_names())
end

-- macOS text-editing shortcuts: Cmd+A, Shift+arrow, Cmd+C/V/X, Cmd+Z, Shift+Cmd+Z.
for _, entry in ipairs({
    { key = KEY_A,     mods = MOD_CTRL,             label = "Cmd+A",       block = "SelectAll"  },
    { key = KEY_LEFT,  mods = MOD_SHIFT,            label = "Shift+Left",  block = nil          },
    { key = KEY_RIGHT, mods = MOD_SHIFT,            label = "Shift+Right", block = nil          },
    { key = KEY_HOME,  mods = MOD_SHIFT,            label = "Shift+Home",  block = nil          },
    { key = KEY_C,     mods = MOD_CTRL,             label = "Cmd+C",       block = "Copy"       },
    { key = KEY_V,     mods = MOD_CTRL,             label = "Cmd+V",       block = "Paste"      },
    { key = KEY_X,     mods = MOD_CTRL,             label = "Cmd+X",       block = "Cut"        },
    { key = KEY_Z,     mods = MOD_CTRL,             label = "Cmd+Z",       block = "Undo"       },
    { key = KEY_Z,     mods = MOD_CTRL + MOD_SHIFT, label = "Shift+Cmd+Z", block = "Redo"       },
}) do
    clear_dispatched()
    local handled = keyboard_shortcuts.handle_key(floating_text_event(entry.key, entry.mods, true))
    check(entry.label .. " in floating text input: not consumed",
        not handled, "handler consumed the key")
    if entry.block then
        check(entry.label .. " in floating text input: no " .. entry.block,
            not has_dispatched(entry.block),
            entry.block .. " fired; dispatched: " .. dispatched_names())
    end
end

-- Shift+Cmd+A is bound to DeselectAll @timeline. It is NOT a QKeySequence
-- StandardKey, so C++ reports is_text_editing_key=false. The FLOATING_CONTEXT
-- sentinel must still prevent the panel-scoped DeselectAll from dispatching.
clear_dispatched()
keyboard_shortcuts.handle_key(
    floating_text_event(KEY_A, MOD_CTRL + MOD_SHIFT, false))
check("Shift+Cmd+A in floating text input: no DeselectAll",
    not has_dispatched("DeselectAll"),
    "DeselectAll fired; dispatched: " .. dispatched_names())

---------------------------------------------------------------------------
-- PHASE 2: modifier shortcuts that are NOT text-editing keys must still
-- dispatch from floating windows. Cmd+S is the canonical example.
---------------------------------------------------------------------------
print("\n--- Phase 2: global modifier shortcuts still dispatch ---")

focus_manager.set_focused_panel("timeline")  -- still stale, still ignored.

-- Cmd+S → SaveProject (global binding, not a text-editing key).
clear_dispatched()
keyboard_shortcuts.handle_key(floating_text_event(KEY_S, MOD_CTRL, false))
check("Cmd+S from floating text input: dispatches SaveProject",
    has_dispatched("SaveProject"),
    "Cmd+S did not reach SaveProject; dispatched: " .. dispatched_names())

---------------------------------------------------------------------------
-- PHASE 3: floating window, focus on a non-text widget (e.g. the history
-- tree). Display-only floating windows are *transparent* to keyboard
-- shortcuts: the user expects bindings to dispatch against the last
-- main-window panel that had focus, exactly as if the floating window
-- weren't there. The "stale" focused_panel is the correct semantic here.
---------------------------------------------------------------------------
print("\n--- Phase 3: floating non-text dispatches via last main-window panel ---")

focus_manager.set_focused_panel("timeline")

-- J from a non-text floating window MUST dispatch ShuttleReverse on the
-- timeline. The history panel is display-only — it must not eat the key.
clear_dispatched()
keyboard_shortcuts.handle_key(floating_nontext_event(KEY_J))
check("j from floating non-text: dispatches ShuttleReverse on timeline",
    has_dispatched("ShuttleReverse"),
    "expected timeline shuttle to fire as if floating window were absent; dispatched: "
    .. dispatched_names())

-- Global Cmd+S must still dispatch.
clear_dispatched()
keyboard_shortcuts.handle_key(floating_nontext_event(KEY_S, MOD_CTRL))
check("Cmd+S from floating non-text: dispatches SaveProject",
    has_dispatched("SaveProject"),
    "Cmd+S did not reach SaveProject; dispatched: " .. dispatched_names())

-- Tab from a non-text floating window (history): must redirect focus AND
-- fire the focused panel's Tab binding in the SAME keypress. Display-only
-- floating windows are transparent — Tab behaves exactly as if it had been
-- pressed with the focused panel already focused (no "first press to
-- escape" cost). For @timeline, that means ToggleTimecodeFocus dispatches.
clear_dispatched()
local tab_handled = keyboard_shortcuts.handle_key(floating_nontext_event(KEY_TAB))
check("Tab from floating non-text: consumed",
    tab_handled == true,
    "Tab was not consumed")
check("Tab from floating non-text: fires focused panel's binding (no eaten press)",
    has_dispatched("ToggleTimecodeFocus"),
    "expected ToggleTimecodeFocus to dispatch in same press; dispatched: "
    .. dispatched_names())

---------------------------------------------------------------------------
-- PHASE 5: Tab in the main-window timeline panel must dispatch the
-- ToggleTimecodeFocus command via the TOML registry. Qt-native Tab
-- cycling cannot fire (focus chain is empty by design — see
-- timeline_panel focus-policy demotion).
---------------------------------------------------------------------------
print("\n--- Phase 5: Tab in main-window timeline dispatches ToggleTimecodeFocus ---")

focus_manager.set_focused_panel("timeline")

clear_dispatched()
local tab_main_handled = keyboard_shortcuts.handle_key({
    key = KEY_TAB, modifiers = 0, text = "",
    is_auto_repeat = false,
    focus_widget_is_text_input = false,
    focus_outside_main_window = false,
    is_text_editing_key = false,
})
check("Tab in main-window timeline: dispatches ToggleTimecodeFocus",
    has_dispatched("ToggleTimecodeFocus"),
    "ToggleTimecodeFocus did not dispatch; dispatched: " .. dispatched_names())
check("Tab in main-window timeline: returned true (consumed)",
    tab_main_handled == true,
    "Tab was not consumed by the dispatch path")

-- Tab in another main-window panel (e.g. project_browser) must NOT dispatch
-- ToggleTimecodeFocus — the binding is panel-scoped to @timeline only.
focus_manager.set_focused_panel("project_browser")

clear_dispatched()
keyboard_shortcuts.handle_key({
    key = KEY_TAB, modifiers = 0, text = "",
    is_auto_repeat = false,
    focus_widget_is_text_input = false,
    focus_outside_main_window = false,
    is_text_editing_key = false,
})
check("Tab in project_browser: does NOT dispatch ToggleTimecodeFocus",
    not has_dispatched("ToggleTimecodeFocus"),
    "ToggleTimecodeFocus leaked outside @timeline; dispatched: " .. dispatched_names())

---------------------------------------------------------------------------
-- PHASE 4: Escape in a floating text input must NOT be treated as a text
-- edit. The existing Escape cascade (dismiss find_dialog, exit fullscreen,
-- cancel text entry) must continue to run.
---------------------------------------------------------------------------
print("\n--- Phase 4: Escape still routes through cascade ---")

clear_dispatched()
-- Escape is NOT a text-editing key: the Lua cascade must still see it.
-- If find_dialog is open, Escape dismisses it; otherwise the cancel flag is
-- set and the handler returns nil/false. We just check that we didn't
-- accidentally swallow it as a text edit.
keyboard_shortcuts.handle_key(floating_text_event(KEY_ESCAPE, 0, false))
check("Escape from floating text input: no timeline dispatch",
    not has_dispatched("DeleteSelection")
        and not has_dispatched("ShuttleReverse"),
    "Escape fired a timeline command; dispatched: " .. dispatched_names())

---------------------------------------------------------------------------
-- Cleanup
---------------------------------------------------------------------------
command_manager.execute_interactive = orig_execute_interactive
command_manager.get_executor = orig_get_executor
ui.cleanup()

print(string.format("\n✅ test_floating_window_key_isolation.lua passed (%d checks)", pass_count))
