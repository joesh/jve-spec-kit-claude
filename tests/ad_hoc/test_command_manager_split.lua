#!/usr/bin/env luajit
-- Test command_manager.lua split (Rule 2.27 compliance)

package.path = package.path .. ";./src/lua/?.lua;./src/lua/?/init.lua"

-- Mock dependencies
package.loaded['core.sqlite3'] = { open = function() return nil end }
package.loaded['core.database'] = {
    get_connection = function() return nil end,
    set_path = function() return true end
}
package.loaded['command'] = {}
package.loaded['models.project'] = {}
package.loaded['models.sequence'] = {}
package.loaded['models.track'] = {}
package.loaded['models.clip'] = {}
package.loaded['media.media_reader'] = {}
package.loaded['importers.fcp7_xml_importer'] = {}
package.loaded['importers.resolve_database_importer'] = {}
package.loaded['core.clip_links'] = {}

print("Testing command_manager.lua split (Rule 2.27)...\n")

-- Test 1: command_implementations.lua loads
print("Test 1: command_implementations.lua module loads")
local success, impl = pcall(function()
    return require("core.command_implementations")
end)
if success and impl and type(impl.register_commands) == "function" then
    print("  ✅ PASS: Module loads with register_commands function")
else
    print("  ❌ FAIL:", impl)
    os.exit(1)
end

-- Test 2: command_manager.lua loads
print("\nTest 2: command_manager.lua loads and has core functions")
success, cmd_mgr = pcall(function()
    return require("core.command_manager")
end)
if not success then
    print("  ❌ FAIL:", cmd_mgr)
    os.exit(1)
end

local required_functions = {"init", "execute", "undo", "redo", "replay_events", "get_last_command"}
local all_present = true
for _, fname in ipairs(required_functions) do
    if type(cmd_mgr[fname]) ~= "function" then
        print(string.format("  ❌ FAIL: Missing function %s", fname))
        all_present = false
    end
end

if all_present then
    print("  ✅ PASS: All core functions present")
else
    os.exit(1)
end

-- Test 3: Check file sizes
print("\nTest 3: File sizes are reasonable (Rule 2.27)")
local function get_line_count(filepath)
    local count = 0
    for line in io.lines(filepath) do
        count = count + 1
    end
    return count
end

local cm_lines = get_line_count("src/lua/core/command_manager.lua")
local impl_lines = get_line_count("src/lua/core/command_implementations.lua")

print(string.format("  command_manager.lua: %d lines", cm_lines))
print(string.format("  command_implementations.lua: %d lines", impl_lines))
print(string.format("  Total: %d lines", cm_lines + impl_lines))

if cm_lines < 2500 and impl_lines < 2500 then
    print("  ✅ PASS: Both files under 2,500 lines (down from 4,150)")
else
    print("  ❌ FAIL: Files still too large")
    os.exit(1)
end

print("\n" .. string.rep("=", 60))
print("All tests passed!")
print("command_manager.lua successfully split per Rule 2.27")
print("Original: 4,150 lines → Split: " .. cm_lines .. " + " .. impl_lines .. " lines")
