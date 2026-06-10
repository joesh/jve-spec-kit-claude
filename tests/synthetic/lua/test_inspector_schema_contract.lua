#!/usr/bin/env luajit
-- Contract test: metadata_schemas module shape (T006).
-- Validates the schema-definition contract documented in
-- specs/012-rewrite-the-inspector/contracts/schema-definition-contract.md.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local schemas = require("ui.metadata_schemas")

local pass, fail = 0, 0
local function check(label, ok, msg)
    if ok then
        pass = pass + 1
    else
        fail = fail + 1
        print("FAIL: " .. label .. (msg and (": " .. msg) or ""))
    end
end

print("=== Inspector: schema definition contract ===\n")

-- FIELD_TYPES enumeration.
local ft = schemas.FIELD_TYPES
check("FIELD_TYPES has STRING",    ft.STRING    == "STRING")
check("FIELD_TYPES has TEXT_AREA", ft.TEXT_AREA == "TEXT_AREA")
check("FIELD_TYPES has DROPDOWN",  ft.DROPDOWN  == "DROPDOWN")
check("FIELD_TYPES has INTEGER",   ft.INTEGER   == "INTEGER")
check("FIELD_TYPES has DOUBLE",    ft.DOUBLE    == "DOUBLE")
check("FIELD_TYPES has BOOLEAN",   ft.BOOLEAN   == "BOOLEAN")
check("FIELD_TYPES has TIMECODE",          ft.TIMECODE          == "TIMECODE")
check("FIELD_TYPES has TIMESTAMP",         ft.TIMESTAMP         == "TIMESTAMP")
local key_count = 0
for _ in pairs(ft) do key_count = key_count + 1 end
check("FIELD_TYPES has exactly 8 keys (no stale)", key_count == 8,
    "got " .. key_count)

-- PROPERTY_TYPES enumeration.
local pt = schemas.PROPERTY_TYPES
check("PROPERTY_TYPES has STRING",   pt.STRING   == "STRING")
check("PROPERTY_TYPES has NUMBER",   pt.NUMBER   == "NUMBER")
check("PROPERTY_TYPES has BOOLEAN",  pt.BOOLEAN  == "BOOLEAN")
check("PROPERTY_TYPES has ENUM",     pt.ENUM     == "ENUM")
check("PROPERTY_TYPES has TIMECODE", pt.TIMECODE == "TIMECODE")
local pt_count = 0
for _ in pairs(pt) do pt_count = pt_count + 1 end
check("PROPERTY_TYPES has exactly 5 keys", pt_count == 5)

-- property_type mapping (including TIMECODE -> TIMECODE, not NUMBER).
check("map STRING → STRING",       schemas.get_property_type(ft.STRING)    == "STRING")
check("map TEXT_AREA → STRING",    schemas.get_property_type(ft.TEXT_AREA) == "STRING")
check("map DROPDOWN → ENUM",       schemas.get_property_type(ft.DROPDOWN)  == "ENUM")
check("map INTEGER → NUMBER",      schemas.get_property_type(ft.INTEGER)   == "NUMBER")
check("map DOUBLE → NUMBER",       schemas.get_property_type(ft.DOUBLE)    == "NUMBER")
check("map BOOLEAN → BOOLEAN",     schemas.get_property_type(ft.BOOLEAN)   == "BOOLEAN")
check("map TIMECODE → TIMECODE",   schemas.get_property_type(ft.TIMECODE)  == "TIMECODE")

-- Clip sections in the expected Resolve-style order.
local clip_sections = schemas.get_sections("clip")
check("clip has ≥4 sections",   #clip_sections >= 4)
check("clip [1] = File",        clip_sections[1] and clip_sections[1].name == "File")
check("clip [2] = Source Range",clip_sections[2] and clip_sections[2].name == "Source Range")
check("clip [3] = Enable",      clip_sections[3] and clip_sections[3].name == "Enable")
check("clip [4] = Audio",       clip_sections[4] and clip_sections[4].name == "Audio")

-- Sequence sections.
local seq_sections = schemas.get_sections("sequence")
check("sequence has ≥3 sections", #seq_sections >= 3)
check("sequence [1] = Project",   seq_sections[1] and seq_sections[1].name == "Project")
check("sequence [2] = Viewport",  seq_sections[2] and seq_sections[2].name == "Viewport")
check("sequence [3] = Marks",     seq_sections[3] and seq_sections[3].name == "Marks")

-- Viewport contains only playhead_frame (I1 resolution — no view_start_frame
-- / view_duration_frames). Field keys are DB column names so the write path
-- works through SetSequenceMetadata's column whitelist.
do
    local viewport = seq_sections[2]
    check("viewport section has exactly 1 field", #viewport.schema.fields == 1,
        "got " .. tostring(#viewport.schema.fields))
    check("viewport field = playhead_frame (real DB column name)",
        viewport.schema.fields[1] and viewport.schema.fields[1].key == "playhead_frame")
end

-- No stale sections anywhere.
local stale = { "Camera", "Production", "Review", "Transform Properties",
                "Cropping Properties", "Composite Properties", "Premiere Project",
                "IPTC Core", "Dublin Core", "Dynamic Media", "EXIF" }
for _, stale_name in ipairs(stale) do
    local found = false
    for _, s in ipairs(clip_sections) do if s.name == stale_name then found = true end end
    for _, s in ipairs(seq_sections)  do if s.name == stale_name then found = true end end
    check("no stale section " .. stale_name, not found)
end

-- read_only flag present on File/rate_display (clip) and Project/frame_rate_display (sequence).
do
    local rate_display = schemas.get_field("clip", "rate_display")
    check("clip.rate_display exists", rate_display ~= nil)
    check("clip.rate_display is read_only", rate_display and rate_display.read_only == true)

    local frame_rate_display = schemas.get_field("sequence", "frame_rate_display")
    check("sequence.frame_rate_display is read_only",
        frame_rate_display and frame_rate_display.read_only == true)

    local name_clip = schemas.get_field("clip", "name")
    check("clip.name is NOT read_only", name_clip and name_clip.read_only == false)
end

-- Field validation: missing key / label / type asserts.
local function expect_assert(fn, needle)
    local ok, err = pcall(fn)
    if ok then return false, "expected assertion failure" end
    if needle and not tostring(err):find(needle, 1, true) then
        return false, "expected error containing " .. needle .. ", got " .. tostring(err)
    end
    return true
end

-- get_sections with unknown schema asserts.
local ok, _ = expect_assert(function() schemas.get_sections("bogus") end, "unknown schema_id")
check("get_sections(bogus) asserts with context", ok)

-- get_property_type with unknown type asserts.
ok, _ = expect_assert(function() schemas.get_property_type("SOMETHING_ELSE") end, "unknown field_type")
check("get_property_type(unknown) asserts", ok)

-- No stale top-level exports.
check("no clip_inspector_schemas export",     schemas.clip_inspector_schemas == nil)
check("no sequence_inspector_schemas export", schemas.sequence_inspector_schemas == nil)
check("no get_clip_inspector_schemas export", schemas.get_clip_inspector_schemas == nil)
check("no add_custom_schema export",          schemas.add_custom_schema == nil)
check("no add_custom_field export",           schemas.add_custom_field == nil)

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_inspector_schema_contract.lua passed")
