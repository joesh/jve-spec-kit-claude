#!/usr/bin/env luajit
-- Unit test T012d: property type mapping (TIMECODE distinctness).
-- Derived from data-model.md §2.6 and Q3 resolution: TIMECODE end-to-end.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local schemas = require("ui.metadata_schemas")
local ft = schemas.FIELD_TYPES

print("=== Inspector: property-type mapping unit test ===\n")

local expected = {
    [ft.STRING]    = "STRING",
    [ft.TEXT_AREA] = "STRING",
    [ft.DROPDOWN]  = "ENUM",
    [ft.INTEGER]   = "NUMBER",
    [ft.DOUBLE]    = "NUMBER",
    [ft.BOOLEAN]   = "BOOLEAN",
    [ft.TIMECODE]  = "TIMECODE",
}

local pass, fail = 0, 0
for field_type, want in pairs(expected) do
    local got = schemas.get_property_type(field_type)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print(string.format("FAIL: %s → expected %s, got %s", field_type, want, tostring(got)))
    end
end

-- Property type for TIMECODE is NOT NUMBER (this was the buggy historical behavior).
if schemas.get_property_type(ft.TIMECODE) == "NUMBER" then
    fail = fail + 1
    print("FAIL: TIMECODE must not collapse to NUMBER (Q3 resolution)")
else
    pass = pass + 1
end

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_inspector_property_type_mapping.lua passed")
