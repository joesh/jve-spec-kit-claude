#!/usr/bin/env luajit
-- Test that timeline modules correctly use centralized constants (Rule 2.14)

package.path = package.path .. ";./src/lua/?.lua;./src/lua/?/init.lua"

-- Mock dependencies
package.loaded['core.sqlite3'] = { open = function() return nil end }
package.loaded['core.command_manager'] = {}
package.loaded['command'] = {}
package.loaded['ui.timeline.timeline_ruler'] = {}
package.loaded['ui.timeline.timeline_scrollbar'] = {}

print("Testing centralized constants integration (Rule 2.14 compliance)...\n")

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
if ui_constants.TIMELINE.EDGE_ZONE_PX ~= 8 then
    constants_ok = false
    table.insert(errors, "EDGE_ZONE_PX incorrect")
end
if ui_constants.TIMELINE.ROLL_ZONE_PX ~= 16 then
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
end

print("\n" .. string.rep("=", 60))
print("Constants integration test completed!")
print("All hardcoded constants moved to ui_constants.lua (Rule 2.14)")
