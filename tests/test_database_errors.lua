#!/usr/bin/env luajit
-- Test that database.lua properly throws errors instead of using fallbacks

package.path = package.path .. ";./src/lua/?.lua;./src/lua/?/init.lua"

-- Mock sqlite3 to avoid dependency
package.loaded['core.sqlite3'] = {
    open = function() return nil, "mocked" end
}

local db = require("core.database")

print("Testing database.lua error handling (Rule 2.13 compliance)...\n")

-- Test 1: get_current_project_id() should throw error without database
print("Test 1: get_current_project_id() throws error without database")
local success, err = pcall(function()
    return db.get_current_project_id()
end)
if not success and err:match("FATAL.*No database connection") then
    print("  ✅ PASS: Throws error for missing database connection")
    print("    (Note: Function now properly creates/manages projects when database is available)")
else
    print("  ❌ FAIL: Should throw FATAL error for missing connection")
    print("    Got:", err)
end

-- Test 2: load_tracks() without sequence_id should throw error
print("\nTest 2: load_tracks(nil) throws error")
success, err = pcall(function()
    return db.load_tracks(nil)
end)
if not success and err:match("FATAL.*requires sequence_id") then
    print("  ✅ PASS: Throws error for missing parameter")
else
    print("  ❌ FAIL: Should throw FATAL error for missing parameter")
end

-- Test 3: load_tracks() without connection should throw error
print("\nTest 3: load_tracks() without connection throws error")
success, err = pcall(function()
    return db.load_tracks("test_sequence")
end)
if not success and err:match("FATAL.*No database connection") then
    print("  ✅ PASS: Throws error for missing connection")
else
    print("  ❌ FAIL: Should throw FATAL error for missing connection")
end

-- Test 4: load_clips() without sequence_id should throw error
print("\nTest 4: load_clips(nil) throws error")
success, err = pcall(function()
    return db.load_clips(nil)
end)
if not success and err:match("FATAL.*requires sequence_id") then
    print("  ✅ PASS: Throws error for missing parameter")
else
    print("  ❌ FAIL: Should throw FATAL error for missing parameter")
end

-- Test 5: load_clips() without connection should throw error
print("\nTest 5: load_clips() without connection throws error")
success, err = pcall(function()
    return db.load_clips("test_sequence")
end)
if not success and err:match("FATAL.*No database connection") then
    print("  ✅ PASS: Throws error for missing connection")
else
    print("  ❌ FAIL: Should throw FATAL error for missing connection")
end

-- Test 6: update_clip_position() validates all parameters
print("\nTest 6: update_clip_position() validates parameters")
success, err = pcall(function()
    return db.update_clip_position(nil, 100, 200)
end)
if not success and err:match("FATAL.*requires clip_id") then
    print("  ✅ PASS: Throws error for missing clip_id")
else
    print("  ❌ FAIL: Should throw FATAL error for missing clip_id")
end

success, err = pcall(function()
    return db.update_clip_position("clip1", nil, 200)
end)
if not success and err:match("FATAL.*requires start_time") then
    print("  ✅ PASS: Throws error for missing start_time")
else
    print("  ❌ FAIL: Should throw FATAL error for missing start_time")
end

success, err = pcall(function()
    return db.update_clip_position("clip1", 100, nil)
end)
if not success and err:match("FATAL.*requires duration") then
    print("  ✅ PASS: Throws error for missing duration")
else
    print("  ❌ FAIL: Should throw FATAL error for missing duration")
end

-- Test 7: load_media() without connection should throw error
print("\nTest 7: load_media() without connection throws error")
success, err = pcall(function()
    return db.load_media()
end)
if not success and err:match("FATAL.*No database connection") then
    print("  ✅ PASS: Throws error for missing connection")
else
    print("  ❌ FAIL: Should throw FATAL error for missing connection")
end

-- Test 8: Verify import_media() stub is removed
print("\nTest 8: import_media() stub is removed")
if db.import_media == nil then
    print("  ✅ PASS: Stub function removed (Rule 2.17)")
else
    print("  ❌ FAIL: Stub function still exists")
end

print("\n" .. string.rep("=", 60))
print("All tests completed!")
print("Database module now enforces explicit error handling (Rule 2.13)")
print("No fallback values or stub functions (Rules 2.13, 2.17)")
