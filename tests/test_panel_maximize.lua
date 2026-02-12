require('test_env')

-- Test panel_manager maximize/restore splitter logic

print("=== Test Panel Maximize ===")

local current_splitter_sizes = {}

local widgets = {
    main_splitter = {_name = "main_splitter"},
    top_splitter = {_name = "top_splitter"},
}

current_splitter_sizes["main_splitter"] = {450, 450}
current_splitter_sizes["top_splitter"] = {300, 300, 300, 300}

local mock_qt_constants = {
    LAYOUT = {
        GET_SPLITTER_SIZES = function(splitter)
            if splitter == widgets.main_splitter then
                return {unpack(current_splitter_sizes["main_splitter"])}
            elseif splitter == widgets.top_splitter then
                return {unpack(current_splitter_sizes["top_splitter"])}
            end
        end,
        SET_SPLITTER_SIZES = function(splitter, sizes)
            if splitter == widgets.main_splitter then
                current_splitter_sizes["main_splitter"] = sizes
            elseif splitter == widgets.top_splitter then
                current_splitter_sizes["top_splitter"] = sizes
            end
        end,
    },
}
package.loaded["core.qt_constants"] = mock_qt_constants

package.loaded["core.logger"] = {
    info = function() end,
    debug = function() end,
    warn = function() end,
    error = function() end,
    trace = function() end,
}

local focused = "source_view"
local mock_focus_manager = {
    get_focused_panel = function() return focused end,
}

package.loaded["ui.panel_manager"] = nil
local panel_manager = require("ui.panel_manager")

panel_manager.init({
    main_splitter = widgets.main_splitter,
    top_splitter = widgets.top_splitter,
    focus_manager = mock_focus_manager,
})

--------------------------------------------------------------------------------
-- Test 1: Maximize source_view — splitter sizes correct
--------------------------------------------------------------------------------
print("\nTest 1: Maximize source_view — splitter sizes")
focused = "source_view"

local ok, err = panel_manager.toggle_maximize(nil)
assert(ok, "toggle_maximize failed: " .. tostring(err))

local top = current_splitter_sizes["top_splitter"]
assert(top[1] == 0, "project_browser should be 0, got " .. top[1])
assert(top[2] > 0, "source_view should be > 0, got " .. top[2])
assert(top[3] == 0, "timeline_view should be 0, got " .. top[3])
assert(top[4] == 0, "inspector should be 0, got " .. top[4])

local main = current_splitter_sizes["main_splitter"]
assert(main[2] == 0, "timeline should be 0, got " .. main[2])

print("  ✓ splitter sizes correct")

--------------------------------------------------------------------------------
-- Test 2: Restore works
--------------------------------------------------------------------------------
print("\nTest 2: Restore")
ok = panel_manager.toggle_maximize(nil)
assert(ok)
assert(not panel_manager.is_maximized())

top = current_splitter_sizes["top_splitter"]
assert(top[1] == 300 and top[2] == 300 and top[3] == 300 and top[4] == 300,
    string.format("top not restored: %d,%d,%d,%d", top[1], top[2], top[3], top[4]))

print("  ✓ sizes restored")

--------------------------------------------------------------------------------
-- Test 3: Maximize timeline
--------------------------------------------------------------------------------
print("\nTest 3: Maximize timeline")
focused = "timeline"
ok = panel_manager.toggle_maximize(nil)
assert(ok)
assert(panel_manager.is_maximized())

main = current_splitter_sizes["main_splitter"]
assert(main[1] == 0, "top row should be 0, got " .. main[1])
assert(main[2] > 0, "timeline should be > 0, got " .. main[2])

-- Restore
ok = panel_manager.toggle_maximize(nil)
assert(ok)
assert(not panel_manager.is_maximized())

print("  ✓ timeline maximize/restore correct")

--------------------------------------------------------------------------------
-- Test 4: get_persistable_sizes returns pre-maximize sizes while maximized
--------------------------------------------------------------------------------
print("\nTest 4: get_persistable_sizes while maximized")
-- Start from restored state
current_splitter_sizes["main_splitter"] = {450, 450}
current_splitter_sizes["top_splitter"] = {300, 300, 300, 300}

focused = "source_view"
ok = panel_manager.toggle_maximize(nil)
assert(ok)
assert(panel_manager.is_maximized())

-- Qt now reports artificial maximized sizes
assert(current_splitter_sizes["top_splitter"][1] == 0, "sanity: Qt reports 0 for hidden panel")

-- But get_persistable_sizes must return the REAL pre-maximize sizes
local persist = panel_manager.get_persistable_sizes()
assert(persist, "get_persistable_sizes returned nil")
assert(persist.top[1] == 300 and persist.top[2] == 300 and persist.top[3] == 300 and persist.top[4] == 300,
    string.format("top not pre-maximize: %d,%d,%d,%d", persist.top[1], persist.top[2], persist.top[3], persist.top[4]))
assert(persist.main[1] == 450 and persist.main[2] == 450,
    string.format("main not pre-maximize: %d,%d", persist.main[1], persist.main[2]))

print("  ✓ returns pre-maximize sizes")

--------------------------------------------------------------------------------
-- Test 5: get_persistable_sizes returns current sizes when NOT maximized
--------------------------------------------------------------------------------
print("\nTest 5: get_persistable_sizes when not maximized")
panel_manager.toggle_maximize(nil)  -- restore
assert(not panel_manager.is_maximized())

persist = panel_manager.get_persistable_sizes()
assert(persist, "get_persistable_sizes returned nil")
assert(persist.top[1] == 300 and persist.top[2] == 300 and persist.top[3] == 300 and persist.top[4] == 300,
    string.format("top wrong: %d,%d,%d,%d", persist.top[1], persist.top[2], persist.top[3], persist.top[4]))
assert(persist.main[1] == 450 and persist.main[2] == 450,
    string.format("main wrong: %d,%d", persist.main[1], persist.main[2]))

print("  ✓ returns current sizes")

print("\n✅ test_panel_maximize.lua passed")
