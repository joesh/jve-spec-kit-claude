--- Regression test: DRP open timelines should come from FieldsBlob SequenceTabsData,
-- NOT from TimelineHandleVec (which is the full history/MRU of all 125+ timelines).
--
-- Bug: parse_project_metadata used TimelineHandleVec → opened ALL timelines as tabs.
-- Fix: parse SequenceTabsData from binary FieldsBlob → only the 3 actual open tabs.

require("test_env")

local drp = require("importers.drp_importer")

-- ===========================================================================
-- Test 1: parse_fields_blob_tabs extracts SequenceTabsData correctly
-- ===========================================================================
print("=== test_drp_open_timelines.lua ===")

-- Real FieldsBlob hex from the anamnesis DRP fixture (first ~400 bytes contain tabs)
-- Structure after 'SequenceTabsData' (ASCII, len-prefixed):
--   3 zero bytes, active_uuid, count(3), uuid1, uuid2, uuid3, active_uuid_again
local REAL_FIELDS_BLOB = "000000010000000b0000002a00540069006d0065006c0069006e00650056006900650077004f007000740069006f006e0073004200410000000c00000001f500000001000000030000002600530068006f00770053007400610063006b0065006400540069006d0065006c0069006e00650000000100010000002400530045005100550045004e00430045005f0056004900450057005f00440041005400410000000900000000010000007f000000001153657175656e63655461627344617461000000004800310065006500350037003700610037002d0032003500610065002d0034003400630039002d0038003800640064002d003000370037003500340030003900380066006300660031000000030000004800340032006400320033006100640034002d0038003900620061002d0034003100340036002d0061003900310030002d006600350032006100610034006100340037003400610062000000004800370030006200320066003100650064002d0035003800370030002d0034003700390033002d0061003400640062002d003400340061003500310061003100320039006400650034000000004800310065006500350037003700610037002d0032003500610065002d0034003400630039002d0038003800640064002d003000370037003500340030003900380066006300660031000000002e"

print("TEST 1: parse_fields_blob_tabs extracts 3 tab UUIDs + active")
local tabs = drp.parse_fields_blob_tabs(REAL_FIELDS_BLOB)
assert(tabs, "parse_fields_blob_tabs returned nil")
assert(tabs.tab_ids, "missing tab_ids")
assert(#tabs.tab_ids == 3,
    string.format("Expected 3 tabs, got %d", #tabs.tab_ids))
assert(tabs.tab_ids[1] == "42d23ad4-89ba-4146-a910-f52aa4a474ab",
    "Tab 1 mismatch: " .. tostring(tabs.tab_ids[1]))
assert(tabs.tab_ids[2] == "70b2f1ed-5870-4793-a4db-44a51a129de4",
    "Tab 2 mismatch: " .. tostring(tabs.tab_ids[2]))
assert(tabs.tab_ids[3] == "1ee577a7-25ae-44c9-88dd-07754098fcf1",
    "Tab 3 mismatch: " .. tostring(tabs.tab_ids[3]))
assert(tabs.active_id == "1ee577a7-25ae-44c9-88dd-07754098fcf1",
    "Active tab mismatch: " .. tostring(tabs.active_id))
print("  PASS: 3 tabs + active extracted correctly")

-- ===========================================================================
-- Test 2: nil/empty/missing SequenceTabsData → empty result (no crash)
-- ===========================================================================
print("TEST 2: edge cases → empty result")
local empty = drp.parse_fields_blob_tabs(nil)
assert(empty and #empty.tab_ids == 0, "nil → empty tabs")
empty = drp.parse_fields_blob_tabs("")
assert(empty and #empty.tab_ids == 0, "empty string → empty tabs")
-- Hex with no SequenceTabsData
empty = drp.parse_fields_blob_tabs("00000001000000ff")
assert(empty and #empty.tab_ids == 0, "no SequenceTabsData → empty tabs")
print("  PASS: all edge cases return empty tab list")

-- ===========================================================================
-- Test 3: single tab (no extra UUIDs after count=1)
-- ===========================================================================
print("TEST 3: single tab blob")
-- Construct minimal blob: 'SequenceTabsData' + 1 UUID + count=1 + 1 UUID + active UUID
local function hex_utf16be(s)
    local out = {}
    for i = 1, #s do
        out[#out + 1] = string.format("00%02x", s:byte(i))
    end
    return table.concat(out)
end

local uuid1 = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
local uuid1_hex = hex_utf16be(uuid1)
-- SequenceTabsData as ASCII with length prefix (17 = 0x11)
local field_name = "1153657175656e636554616273446174610000"
-- Structure: field_name + 00 (padding) + 0048 + uuid + 00 00 01 + 0048 + uuid + 00 00 00 + 0048 + uuid (active repeat)
local single_tab_blob = "0000000000000000" ..  -- some prefix padding
    field_name ..
    "00" ..  -- padding
    "0048" .. uuid1_hex ..  -- active UUID
    "000001" ..  -- count = 1
    "0048" .. uuid1_hex ..  -- tab 1
    "000000" ..  -- separator
    "0048" .. uuid1_hex  -- active UUID again

local single = drp.parse_fields_blob_tabs(single_tab_blob)
assert(single and #single.tab_ids == 1,
    string.format("Expected 1 tab, got %d", single and #single.tab_ids or -1))
assert(single.tab_ids[1] == uuid1,
    "Single tab mismatch: " .. tostring(single.tab_ids[1]))
assert(single.active_id == uuid1,
    "Active tab mismatch: " .. tostring(single.active_id))
print("  PASS: single tab extracted correctly")

-- ===========================================================================
-- Test 4: Full parse_drp_file with real fixture uses SequenceTabsData (not HandleVec)
-- ===========================================================================
print("TEST 4: real DRP fixture — open_timeline_ids from SequenceTabsData, not HandleVec")
local fixture_path = "fixtures/resolve/2026-03-01-anamnesis joe edit.drp"
local f = io.open(fixture_path, "rb")
if f then
    f:close()
    local result = drp.parse_drp_file(fixture_path)
    assert(result.success, "parse_drp_file failed: " .. tostring(result.error))

    -- TimelineHandleVec has 125 entries, but SequenceTabsData has only 3
    assert(result.open_timeline_names and #result.open_timeline_names <= 10,
        string.format("Expected ≤10 open timelines (from tabs), got %d — "
            .. "likely using TimelineHandleVec (125 entries) instead of SequenceTabsData",
            result.open_timeline_names and #result.open_timeline_names or 0))
    assert(#result.open_timeline_names == 3,
        string.format("Expected exactly 3 open timelines from SequenceTabsData, got %d",
            #result.open_timeline_names))
    print(string.format("  PASS: %d open timelines (not 125)", #result.open_timeline_names))

    -- Active timeline should be set
    assert(result.active_timeline_name,
        "Expected active_timeline_name to be set")
    print(string.format("  PASS: active timeline = '%s'", result.active_timeline_name))
else
    print("  SKIP: DRP fixture not found (run from tests/ directory)")
end

print("✅ test_drp_open_timelines.lua passed")
