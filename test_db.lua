#!/usr/bin/env luajit

-- Add src/lua to package path
package.path = package.path .. ";/Users/joe/Local/jve-spec-kit-claude/src/lua/?.lua"

print("Testing database module loading...")

local success, result = pcall(function()
    return require("core.database")
end)

if success then
    print("✅ Database module loaded successfully")
    print("Module: " .. tostring(result))
else
    print("❌ Failed to load database module:")
    print(tostring(result))
end

print("\nTesting sqlite3 module loading...")
local success2, result2 = pcall(function()
    return require("core.sqlite3")
end)

if success2 then
    print("✅ SQLite3 module loaded successfully")
else
    print("❌ Failed to load sqlite3 module:")
    print(tostring(result2))
end
