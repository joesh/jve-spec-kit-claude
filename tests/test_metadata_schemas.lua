require("test_env")

local schemas = require("ui.metadata_schemas")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

print("\n=== Metadata Schemas Tests (T18) ===")

-- ============================================================
-- FIELD_TYPES exports
-- ============================================================
print("\n--- FIELD_TYPES ---")
do
    check("STRING", schemas.FIELD_TYPES.STRING == "string")
    check("INTEGER", schemas.FIELD_TYPES.INTEGER == "integer")
    check("DOUBLE", schemas.FIELD_TYPES.DOUBLE == "double")
    check("BOOLEAN", schemas.FIELD_TYPES.BOOLEAN == "boolean")
    check("TIMECODE", schemas.FIELD_TYPES.TIMECODE == "timecode")
    check("DROPDOWN", schemas.FIELD_TYPES.DROPDOWN == "dropdown")
    check("TEXT_AREA", schemas.FIELD_TYPES.TEXT_AREA == "text_area")
end

-- ============================================================
-- clip_inspector_schemas — schema structure
-- ============================================================
print("\n--- clip inspector schemas ---")
do
    local clip_schemas = schemas.get_clip_inspector_schemas()
    check("clip schemas is table", type(clip_schemas) == "table")

    -- Known categories
    check("Camera exists", clip_schemas["Camera"] ~= nil)
    check("Production exists", clip_schemas["Production"] ~= nil)
    check("Transform Properties exists", clip_schemas["Transform Properties"] ~= nil)
    check("Review exists", clip_schemas["Review"] ~= nil)
    check("Audio exists", clip_schemas["Audio"] ~= nil)
    check("IPTC Core exists", clip_schemas["IPTC Core"] ~= nil)
    check("Dublin Core exists", clip_schemas["Dublin Core"] ~= nil)
    check("Dynamic Media exists", clip_schemas["Dynamic Media"] ~= nil)
    check("EXIF exists", clip_schemas["EXIF"] ~= nil)
    check("Cropping Properties exists", clip_schemas["Cropping Properties"] ~= nil)
    check("Composite Properties exists", clip_schemas["Composite Properties"] ~= nil)
    check("Premiere Project exists", clip_schemas["Premiere Project"] ~= nil)
end

-- ============================================================
-- field structure
-- ============================================================
print("\n--- field structure ---")
do
    local camera = schemas.get_clip_inspector_schemas()["Camera"]
    check("Camera has description", type(camera.description) == "string")
    check("Camera has fields", type(camera.fields) == "table")
    check("Camera field count >= 8", #camera.fields >= 8)

    local field = camera.fields[1]
    check("field has key", type(field.key) == "string")
    check("field has label", type(field.label) == "string")
    check("field has type", type(field.type) == "string")
    check("field has default", field.default ~= nil)
    check("first field key = camera:make", field.key == "camera:make")
    check("first field type = string", field.type == "string")
end

-- ============================================================
-- field types — dropdown with options
-- ============================================================
print("\n--- dropdown field ---")
do
    local review = schemas.get_clip_inspector_schemas()["Review"]
    local status_field = review.fields[1]
    check("status key", status_field.key == "review:status")
    check("status type = dropdown", status_field.type == "dropdown")
    check("status has options", type(status_field.options) == "table")
    check("status default = Pending", status_field.default == "Pending")
    check("5 status options", #status_field.options == 5)
end

-- ============================================================
-- field types — numeric with min/max
-- ============================================================
print("\n--- numeric with constraints ---")
do
    local composite = schemas.get_clip_inspector_schemas()["Composite Properties"]
    -- Find opacity field
    local opacity
    for _, f in ipairs(composite.fields) do
        if f.key == "composite:opacity" then opacity = f end
    end
    check("opacity found", opacity ~= nil)
    check("opacity type = double", opacity.type == "double")
    check("opacity has min", opacity.min == 0.0)
    check("opacity has max", opacity.max == 100.0)
    check("opacity default = 100", opacity.default == 100.0)
end

-- ============================================================
-- field types — boolean
-- ============================================================
print("\n--- boolean field ---")
do
    local composite = schemas.get_clip_inspector_schemas()["Composite Properties"]
    local drop_shadow
    for _, f in ipairs(composite.fields) do
        if f.key == "composite:drop_shadow" then drop_shadow = f end
    end
    check("drop_shadow found", drop_shadow ~= nil)
    check("drop_shadow type = boolean", drop_shadow.type == "boolean")
    check("drop_shadow default = false", drop_shadow.default == false)
end

-- ============================================================
-- field types — integer
-- ============================================================
print("\n--- integer field ---")
do
    local camera = schemas.get_clip_inspector_schemas()["Camera"]
    local iso
    for _, f in ipairs(camera.fields) do
        if f.key == "camera:iso" then iso = f end
    end
    check("iso found", iso ~= nil)
    check("iso type = integer", iso.type == "integer")
    check("iso default = 100", iso.default == 100)
end

-- ============================================================
-- field types — timecode
-- ============================================================
print("\n--- timecode field ---")
do
    local dynamic = schemas.get_clip_inspector_schemas()["Dynamic Media"]
    local tc_in
    for _, f in ipairs(dynamic.fields) do
        if f.key == "dynamic:timecode_in" then tc_in = f end
    end
    check("timecode_in found", tc_in ~= nil)
    check("timecode_in type = timecode", tc_in.type == "timecode")
    check("timecode_in default", tc_in.default == "00:00:00:00")
end

-- ============================================================
-- sequence_inspector_schemas
-- ============================================================
print("\n--- sequence inspector schemas ---")
do
    local seq_schemas = schemas.get_sequence_inspector_schemas()
    check("seq schemas is table", type(seq_schemas) == "table")
    check("Timeline Settings exists", seq_schemas["Timeline Settings"] ~= nil)
    check("Timeline Viewport exists", seq_schemas["Timeline Viewport"] ~= nil)

    local settings = seq_schemas["Timeline Settings"]
    check("settings has fields", #settings.fields >= 6)

    -- Verify specific field
    local name_field = settings.fields[1]
    check("first seq field = name", name_field.key == "name")
end

-- ============================================================
-- get_sections — clip
-- ============================================================
print("\n--- get_sections clip ---")
do
    local sections = schemas.get_sections("clip")
    check("sections is table", type(sections) == "table")
    check("sections count matches schemas", #sections == 12)

    -- Sections are sorted alphabetically
    check("first section alphabetical", sections[1].name == "Audio")
    check("section has schema", sections[1].schema ~= nil)
    check("section schema has fields", #sections[1].schema.fields > 0)

    -- Verify order
    for i = 2, #sections do
        check("sorted: " .. sections[i-1].name .. " < " .. sections[i].name,
              sections[i-1].name < sections[i].name)
    end
end

-- ============================================================
-- get_sections — sequence
-- ============================================================
print("\n--- get_sections sequence ---")
do
    local sections = schemas.get_sections("sequence")
    check("sequence sections", #sections == 2)
end

-- ============================================================
-- get_sections — unknown
-- ============================================================
print("\n--- get_sections unknown ---")
do
    local sections = schemas.get_sections("nonexistent")
    check("unknown schema → empty", #sections == 0)

    local nil_sections = schemas.get_sections(nil)
    check("nil schema → empty", #nil_sections == 0)
end

-- ============================================================
-- iter_fields_for_schema
-- ============================================================
print("\n--- iter_fields_for_schema ---")
do
    local count = 0
    local keys = {}
    for field in schemas.iter_fields_for_schema("clip") do
        count = count + 1
        keys[field.key] = true
    end
    check("iterates all clip fields", count > 50) -- 12 schemas × ~5-10 fields each
    check("camera:make in fields", keys["camera:make"] == true)
    check("review:status in fields", keys["review:status"] == true)
    check("dc:title in fields", keys["dc:title"] == true)

    -- Sequence fields
    local seq_count = 0
    for _ in schemas.iter_fields_for_schema("sequence") do
        seq_count = seq_count + 1
    end
    check("sequence fields count", seq_count >= 10) -- 6 + 4

    -- Unknown → no iterations
    local unknown_count = 0
    for _ in schemas.iter_fields_for_schema("bogus") do
        unknown_count = unknown_count + 1
    end
    check("unknown → 0 iterations", unknown_count == 0)
end

-- ============================================================
-- add_custom_schema
-- ============================================================
print("\n--- add_custom_schema ---")
do
    local custom = {
        description = "Test custom schema",
        fields = {
            {key = "custom:field1", label = "F1", type = "string", default = ""},
        }
    }
    schemas.add_custom_schema("Test Custom", custom)
    local all = schemas.get_clip_inspector_schemas()
    check("custom schema added", all["Test Custom"] ~= nil)
    check("custom schema fields", #all["Test Custom"].fields == 1)

    -- Clean up
    schemas.clip_inspector_schemas["Test Custom"] = nil
end

-- ============================================================
-- add_custom_field
-- ============================================================
print("\n--- add_custom_field ---")
do
    local camera_before = #schemas.get_clip_inspector_schemas()["Camera"].fields
    local ok = schemas.add_custom_field("Camera", {
        key = "camera:custom_test", label = "Custom", type = "string", default = ""
    })
    check("add_custom_field returns true", ok == true)
    check("field added", #schemas.get_clip_inspector_schemas()["Camera"].fields == camera_before + 1)

    -- Nonexistent schema
    local nok = schemas.add_custom_field("NonexistentSchema", {
        key = "x", label = "X", type = "string", default = ""
    })
    check("nonexistent schema → false", nok == false)

    -- Clean up: remove added field
    local fields = schemas.get_clip_inspector_schemas()["Camera"].fields
    table.remove(fields, #fields)
end

-- ============================================================
-- create_field default handling
-- ============================================================
print("\n--- field defaults ---")
do
    -- Fields with nil default get "" as default
    local camera = schemas.get_clip_inspector_schemas()["Camera"]
    local make = camera.fields[1] -- camera:make with default ""
    check("empty string default", make.default == "")

    -- Fields with explicit default keep it
    local iso
    for _, f in ipairs(camera.fields) do
        if f.key == "camera:iso" then iso = f end
    end
    check("explicit int default", iso.default == 100)
end

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n=== Metadata Schemas: %d passed, %d failed ===", pass_count, fail_count))
if fail_count > 0 then
    os.exit(1)
end
print("✅ test_metadata_schemas.lua passed")
