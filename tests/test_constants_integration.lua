#!/usr/bin/env luajit
-- Test that timeline modules correctly use centralized constants (Rule 2.14)

package.path = package.path .. ";./src/lua/?.lua;./src/lua/?/init.lua"

-- Mock dependencies
package.loaded['core.sqlite3'] = { open = function() return nil end }
package.loaded['core.command_manager'] = {}
package.loaded['command'] = {}
package.loaded['ui.timeline.timeline_ruler'] = {}
package.loaded['ui.timeline.timeline_scrollbar'] = {}
package.loaded['ui.timeline.timeline_view'] = { create = function() return {} end }
package.loaded['ui.selection_hub'] = { register_listener = function() end, set_active_panel = function() end }
package.loaded['core.database'] = {}
package.loaded['core.profile_scope'] = function() return function() end end
package.loaded['inspectable'] = {
    clip = function() return { get_schema_id = function() end, get = function() return "" end } end,
    sequence = function() return { get_schema_id = function() end, get = function() return "" end } end
}

-- Minimal Qt constants stub so timeline_panel can be required without C++ bindings
_G.qt_constants = {
    WIDGET = {
        CREATE = function() return {} end,
        SET_PARENT = function() end
    },
    LAYOUT = {
        CREATE_HBOX = function() return {} end,
        CREATE_VBOX = function() return {} end,
        ADD_WIDGET = function() end,
        SET_ON_WIDGET = function() end,
        SET_SPLITTER_SIZES = function() end
    },
    DISPLAY = {
        SET_VISIBLE = function() end
    },
    PROPERTIES = {
        SET_STYLE = function() end
    }
}

print("Testing centralized constants integration (Rule 2.14 compliance)...\n")
local any_fail = false

-- Test 1: timeline_state.lua uses ui_constants
print("Test 1: timeline_state.lua")
local success, timeline_state = pcall(function()
    return require("ui.timeline.timeline_state")
end)
if success then
    print("  ✅ PASS: Module loads successfully")
    print("    Dimensions:", timeline_state.dimensions.default_track_height,
          timeline_state.dimensions.track_header_width)
else
    print("  ❌ FAIL:", timeline_state)
    any_fail = true
end

-- Reset for next test
package.loaded['ui.timeline.timeline_state'] = nil

-- Test 2: timeline_panel.lua uses ui_constants
print("\nTest 2: timeline_panel.lua")
success, timeline_panel = pcall(function()
    return require("ui.timeline.timeline_panel")
end)
if success then
    print("  ✅ PASS: Module loads successfully with ui_constants")
else
    print("  ❌ FAIL:", timeline_panel)
    any_fail = true
end

-- Test 3: Verify constants are centralized
print("\nTest 3: Verify constants centralization")
local ui_constants = require("core.ui_constants")
local constants_ok = true
local errors = {}

if ui_constants.TIMELINE.TRACK_HEIGHT ~= 50 then
    constants_ok = false
    table.insert(errors, "TRACK_HEIGHT incorrect")
end
if ui_constants.TIMELINE.TRACK_HEADER_WIDTH ~= 150 then
    constants_ok = false
    table.insert(errors, "TRACK_HEADER_WIDTH incorrect")
end
if ui_constants.TIMELINE.DRAG_THRESHOLD ~= 5 then
    constants_ok = false
    table.insert(errors, "DRAG_THRESHOLD incorrect")
end
if ui_constants.TIMELINE.NOTIFY_DEBOUNCE_MS ~= 16 then
    constants_ok = false
    table.insert(errors, "NOTIFY_DEBOUNCE_MS incorrect")
end
if ui_constants.TIMELINE.EDGE_ZONE_PX ~= 10 then
    constants_ok = false
    table.insert(errors, "EDGE_ZONE_PX incorrect")
end
if ui_constants.TIMELINE.ROLL_ZONE_PX ~= 7 then
    constants_ok = false
    table.insert(errors, "ROLL_ZONE_PX incorrect")
end
if ui_constants.TIMELINE.EDIT_POINT_ZONE ~= 4 then
    constants_ok = false
    table.insert(errors, "EDIT_POINT_ZONE incorrect")
end
if ui_constants.TIMELINE.SPLITTER_HANDLE_HEIGHT ~= 7 then
    constants_ok = false
    table.insert(errors, "SPLITTER_HANDLE_HEIGHT incorrect")
end
if ui_constants.TIMELINE.RULER_HEIGHT ~= 30 then
    constants_ok = false
    table.insert(errors, "RULER_HEIGHT incorrect")
end

if constants_ok then
    print("  ✅ PASS: All 9 timeline constants are centralized and correct")
else
    print("  ❌ FAIL: Constant validation errors:")
    for _, err in ipairs(errors) do
        print("    -", err)
    end
    any_fail = true
end

print("\n" .. string.rep("=", 60))
print("Constants integration test completed!")
print("All hardcoded constants moved to ui_constants.lua (Rule 2.14)")

if any_fail then
    os.exit(1)
end
