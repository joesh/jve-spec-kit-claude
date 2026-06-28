--- Regression: menu_system.update_shortcut_display silently produced no
--- shortcuts after keyboard_shortcut_registry.keybindings switched from
--- {combo_key → binding} to {combo_key → array of bindings} (commit
--- b3e74e2d, multi-context dispatch). Menus rendered without shortcut text.
---
--- Domain behavior: after the editor launches with the bundled default keymap,
--- a call to menu_system.update_shortcut_display() must push QAction shortcut
--- strings for the commands that have TOML bindings (Quit, Undo, SaveProject,
--- TogglePlay, etc.). The function silently iterated the wrong table shape
--- and never produced any output — this test verifies it now does.
---
--- We spy on qt.SET_ACTION_SHORTCUT (the binding the function uses to push
--- text into QActions) by swapping it temporarily — the recorder fires only
--- if the iteration walks the keybindings correctly.
---
--- Runs inside ./build/bin/jve --test (full Qt + menu_system populated at
--- editor launch with the bundled default keymap).

local ui = require("synthetic.integration.ui_test_env")

print("=== test_menu_shortcut_display ===")

ui.launch({
    project_name = "Menu Shortcut Display",
    num_sequences = 1,
    sequence_names = { "Seq" },
    active_sequence = 1,
})

local menu_system = require("core.menu_system")

-- menu_system caches its bindings in a module-local `qt` table populated at
-- module load. Reach it via the upvalue on update_shortcut_display so the spy
-- intercepts the same call site the function actually uses.
local function get_local_qt()
    local i = 1
    while true do
        local name, val = debug.getupvalue(menu_system.update_shortcut_display, i)
        if not name then return nil end
        if name == "qt" then return val end
        i = i + 1
    end
end

local qt_local = get_local_qt()
assert(qt_local and qt_local.SET_ACTION_SHORTCUT,
    "menu_system local qt.SET_ACTION_SHORTCUT not reachable — module shape changed")

local recorded = {}
local original = qt_local.SET_ACTION_SHORTCUT
qt_local.SET_ACTION_SHORTCUT = function(action, shortcut_str)
    recorded[#recorded + 1] = { action = action, shortcut = shortcut_str }
    return original(action, shortcut_str)
end

local ok, err = pcall(menu_system.update_shortcut_display)
qt_local.SET_ACTION_SHORTCUT = original
assert(ok, "update_shortcut_display threw: " .. tostring(err))

-- Aggregate by shortcut string for assertion. We don't have a public way to
-- introspect which QAction* belongs to which command name without adding a
-- C++ getter, so we assert by the shortcut strings that MUST appear if the
-- default keymap was walked correctly.
local shortcuts_pushed = {}
for _, r in ipairs(recorded) do
    shortcuts_pushed[r.shortcut] = (shortcuts_pushed[r.shortcut] or 0) + 1
end

-- Menu-bound commands only (actions_by_command holds menu QActions; transport
-- keys like Space/J/K/L bind via the registry but have no menu item).
local must_appear = { "Ctrl+Q", "Ctrl+Z", "Ctrl+S", "Ctrl+I" }
local fail = 0
for _, s in ipairs(must_appear) do
    if not shortcuts_pushed[s] then
        print(string.format("FAIL: shortcut %q never pushed to any QAction", s))
        fail = fail + 1
    else
        print(string.format("  OK: %q pushed (%d action(s))", s, shortcuts_pushed[s]))
    end
end

assert(#recorded > 0,
    "update_shortcut_display pushed ZERO shortcuts — the iteration is broken " ..
    "(this is exactly the b3e74e2d regression)")
assert(fail == 0, string.format("%d expected shortcut(s) missing", fail))

print(string.format("  (total %d shortcut pushes)", #recorded))
print("✅ test_menu_shortcut_display.lua passed")
