require("test_env")

local database = require("core.database")
local Property = require("models.property")
local json = require("dkjson")
local uuid = require("uuid")

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

local function expect_error(label, fn)
    local ok, err = pcall(fn)
    if not ok then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
    end
    return err
end

-- Decode the JSON envelope that encode_property_json wraps values in
local function decode_value(raw)
    if not raw then return nil end
    local decoded = json.decode(raw)
    if type(decoded) == "table" then
        return decoded.value
    end
    return decoded
end

-- Count rows in properties table
local function count_properties(db, clip_id)
    local stmt = db:prepare("SELECT count(*) FROM properties WHERE clip_id = ?")
    assert(stmt)
    stmt:bind_value(1, clip_id)
    assert(stmt:exec())
    stmt:next()
    local n = stmt:value(0)
    stmt:finalize()
    return n
end

print("\n=== Property Model Tests ===")

local db_path = "/tmp/jve/test_property_model.db"
os.remove(db_path)

assert(database.init(db_path))
local db = database.get_connection()

-- Load schema + create properties table (not in schema.sql)
db:exec(require("import_schema"))
db:exec([[
    CREATE TABLE IF NOT EXISTS properties (
        id TEXT PRIMARY KEY,
        clip_id TEXT NOT NULL,
        property_name TEXT NOT NULL,
        property_value TEXT,
        property_type TEXT,
        default_value TEXT
    );
]])

-- Seed: project + sequence + track + clip for FK context
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'timeline', 24000, 1001, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels,
        codec, metadata, created_at, modified_at)
    VALUES ('med1', 'proj1', 'media.mov', '/tmp/jve/media.mov', 1000,
        24000, 1001, 1920, 1080, 2, 'prores', '{}', %d, %d);
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id,
        timeline_start_num, timeline_start_den, timeline_start_rate_num, timeline_start_rate_den,
        duration_num, duration_den, duration_rate_num, duration_rate_den,
        source_in_num, source_in_den, source_in_rate_num, source_in_rate_den,
        source_out_num, source_out_den, source_out_rate_num, source_out_rate_den,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip1', 'proj1', 'timeline', 'Clip1', 'trk1', 'med1',
        0, 1, 24000, 1001,
        100, 1, 24000, 1001,
        0, 1, 24000, 1001,
        100, 1, 24000, 1001,
        24000, 1001, 1, 0, %d, %d);
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id,
        timeline_start_num, timeline_start_den, timeline_start_rate_num, timeline_start_rate_den,
        duration_num, duration_den, duration_rate_num, duration_rate_den,
        source_in_num, source_in_den, source_in_rate_num, source_in_rate_den,
        source_out_num, source_out_den, source_out_rate_num, source_out_rate_den,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip2', 'proj1', 'timeline', 'Clip2', 'trk1', 'med1',
        100, 1, 24000, 1001,
        50, 1, 24000, 1001,
        100, 1, 24000, 1001,
        150, 1, 24000, 1001,
        24000, 1001, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now))

-- ═══════════════════════════════════════════════════════════════
-- 1. save_for_clip — basic insert
-- ═══════════════════════════════════════════════════════════════

print("\n--- save_for_clip: insert new properties ---")
do
    local props = {
        { id = "prop1", property_name = "opacity", property_value = 0.75, property_type = "FLOAT", default_value = 1.0 },
        { id = "prop2", property_name = "audio:volume", property_value = -6, property_type = "FLOAT", default_value = 0 },
        { id = "prop3", property_name = "label", property_value = "take 1", property_type = "STRING", default_value = nil },
    }
    local ok = Property.save_for_clip("clip1", props)
    check("save_for_clip returns true", ok == true)
    check("3 properties inserted", count_properties(db, "clip1") == 3)
end

print("--- save_for_clip: empty list is no-op ---")
do
    local ok = Property.save_for_clip("clip1", {})
    check("empty list returns true", ok == true)
    check("count unchanged after empty save", count_properties(db, "clip1") == 3)
end

print("--- save_for_clip: nil list is no-op ---")
do
    local ok = Property.save_for_clip("clip1", nil)
    check("nil list returns true", ok == true)
end

print("--- save_for_clip: upsert existing property ---")
do
    local props = {
        { id = "prop1", property_name = "opacity", property_value = 0.50, property_type = "FLOAT", default_value = 1.0 },
    }
    Property.save_for_clip("clip1", props)
    check("count still 3 after upsert", count_properties(db, "clip1") == 3)
end

print("--- save_for_clip: auto-generates id when missing ---")
do
    local props = {
        { property_name = "autoid_prop", property_value = "test", property_type = "STRING" },
    }
    Property.save_for_clip("clip1", props)
    check("count is 4 after auto-id insert", count_properties(db, "clip1") == 4)
end

-- ═══════════════════════════════════════════════════════════════
-- 2. load_for_clip
-- ═══════════════════════════════════════════════════════════════

print("\n--- load_for_clip: returns all properties ---")
do
    local loaded = Property.load_for_clip("clip1")
    check("loaded 4 properties", #loaded == 4)

    -- Find opacity by name
    local opacity
    for _, p in ipairs(loaded) do
        if p.property_name == "opacity" then opacity = p end
    end
    check("opacity property found", opacity ~= nil)
    check("opacity id preserved", opacity and opacity.id == "prop1")
    -- property_value is stored as JSON envelope
    local val = opacity and decode_value(opacity.property_value)
    check("opacity value is 0.5 after upsert", val == 0.5)
    check("opacity type is FLOAT", opacity and opacity.property_type == "FLOAT")
end

print("--- load_for_clip: clip with no properties returns empty ---")
do
    local loaded = Property.load_for_clip("clip2")
    check("clip2 has 0 properties", #loaded == 0)
end

print("--- load_for_clip: nonexistent clip returns empty ---")
do
    local loaded = Property.load_for_clip("nonexistent_clip")
    check("nonexistent clip returns empty table", #loaded == 0)
end

-- ═══════════════════════════════════════════════════════════════
-- 3. copy_for_clip — copies with fresh UUIDs
-- ═══════════════════════════════════════════════════════════════

print("\n--- copy_for_clip: copies properties with new ids ---")
do
    local copies = Property.copy_for_clip("clip1")
    check("copied 4 properties", #copies == 4)

    -- Verify all IDs are new (not prop1/prop2/prop3)
    local original_ids = { prop1 = true, prop2 = true, prop3 = true }
    local all_new = true
    for _, c in ipairs(copies) do
        if original_ids[c.id] then all_new = false end
    end
    check("all copied ids are fresh UUIDs", all_new)

    -- Verify names preserved
    local names = {}
    for _, c in ipairs(copies) do names[c.property_name] = true end
    check("opacity name preserved in copy", names["opacity"] == true)
    check("audio:volume name preserved in copy", names["audio:volume"] == true)

    -- Verify default_value for nil defaults gets JSON-encoded
    local label_copy
    for _, c in ipairs(copies) do
        if c.property_name == "label" then label_copy = c end
    end
    check("label copy has encoded default_value", label_copy and label_copy.default_value ~= nil)
    check("label default decodes to nil value", label_copy and decode_value(label_copy.default_value) == nil)
end

print("--- copy_for_clip: empty source returns empty ---")
do
    local copies = Property.copy_for_clip("clip2")
    check("copying from clip with no props returns empty", #copies == 0)
end

print("--- copy_for_clip: save copied properties to new clip ---")
do
    local copies = Property.copy_for_clip("clip1")
    Property.save_for_clip("clip2", copies)
    check("clip2 now has 4 properties", count_properties(db, "clip2") == 4)
end

-- ═══════════════════════════════════════════════════════════════
-- 4. delete_for_clip
-- ═══════════════════════════════════════════════════════════════

print("\n--- delete_for_clip: removes all properties for clip ---")
do
    local ok = Property.delete_for_clip("clip2")
    check("delete_for_clip returns true", ok == true)
    check("clip2 has 0 properties after delete", count_properties(db, "clip2") == 0)
    -- clip1 unaffected
    check("clip1 still has 4 properties", count_properties(db, "clip1") == 4)
end

print("--- delete_for_clip: deleting from empty clip is no-op ---")
do
    local ok = Property.delete_for_clip("clip2")
    check("delete empty clip returns true", ok == true)
end

-- ═══════════════════════════════════════════════════════════════
-- 5. delete_by_ids
-- ═══════════════════════════════════════════════════════════════

print("\n--- delete_by_ids: deletes specific properties ---")
do
    local ok = Property.delete_by_ids({"prop1", "prop2"})
    check("delete_by_ids returns true", ok == true)
    check("clip1 has 2 remaining", count_properties(db, "clip1") == 2)
end

print("--- delete_by_ids: empty list is no-op ---")
do
    local ok = Property.delete_by_ids({})
    check("empty list returns true", ok == true)
    check("count unchanged", count_properties(db, "clip1") == 2)
end

print("--- delete_by_ids: nil list is no-op ---")
do
    local ok = Property.delete_by_ids(nil)
    check("nil returns true", ok == true)
end

print("--- delete_by_ids: nonexistent id is silent (no row affected) ---")
do
    local ok = Property.delete_by_ids({"does_not_exist"})
    check("nonexistent id returns true", ok == true)
    check("count unchanged", count_properties(db, "clip1") == 2)
end

print("--- delete_by_ids: skips empty string entries ---")
do
    local ok = Property.delete_by_ids({"", "prop3", ""})
    check("mixed list returns true", ok == true)
    check("clip1 has 1 remaining after deleting prop3", count_properties(db, "clip1") == 1)
end

-- ═══════════════════════════════════════════════════════════════
-- 6. Error paths — missing/invalid arguments
-- ═══════════════════════════════════════════════════════════════

print("\n--- error paths: load_for_clip ---")
do
    local err = expect_error("nil clip_id asserts", function()
        Property.load_for_clip(nil)
    end)
    check("error mentions clip_id", err and err:find("clip_id") ~= nil)

    expect_error("empty string clip_id asserts", function()
        Property.load_for_clip("")
    end)
end

print("--- error paths: copy_for_clip ---")
do
    expect_error("nil source_clip_id asserts", function()
        Property.copy_for_clip(nil)
    end)

    expect_error("empty source_clip_id asserts", function()
        Property.copy_for_clip("")
    end)
end

print("--- error paths: save_for_clip ---")
do
    expect_error("nil clip_id asserts", function()
        Property.save_for_clip(nil, {{ property_name = "x" }})
    end)

    expect_error("empty clip_id asserts", function()
        Property.save_for_clip("", {{ property_name = "x" }})
    end)
end

print("--- error paths: delete_for_clip ---")
do
    expect_error("nil clip_id asserts", function()
        Property.delete_for_clip(nil)
    end)

    expect_error("empty clip_id asserts", function()
        Property.delete_for_clip("")
    end)
end

-- ═══════════════════════════════════════════════════════════════
-- 7. JSON encoding edge cases
-- ═══════════════════════════════════════════════════════════════

print("\n--- JSON encoding: nil value stored correctly ---")
do
    Property.save_for_clip("clip1", {
        { id = "json_nil", property_name = "nil_test", property_value = nil }
    })
    local loaded = Property.load_for_clip("clip1")
    local found
    for _, p in ipairs(loaded) do
        if p.property_name == "nil_test" then found = p end
    end
    check("nil_test property exists", found ~= nil)
    check("nil value decodes to nil", found and decode_value(found.property_value) == nil)
end

print("--- JSON encoding: boolean value ---")
do
    Property.save_for_clip("clip1", {
        { id = "json_bool", property_name = "bool_test", property_value = true }
    })
    local loaded = Property.load_for_clip("clip1")
    local found
    for _, p in ipairs(loaded) do
        if p.property_name == "bool_test" then found = p end
    end
    check("boolean property exists", found ~= nil)
    check("boolean value decodes to true", found and decode_value(found.property_value) == true)
end

print("--- JSON encoding: string passthrough ---")
do
    -- When property_value is already a string, encode_property_json passes it through as-is
    local raw_json = '{"value":"already encoded"}'
    Property.save_for_clip("clip1", {
        { id = "json_str", property_name = "str_test", property_value = raw_json }
    })
    local loaded = Property.load_for_clip("clip1")
    local found
    for _, p in ipairs(loaded) do
        if p.property_name == "str_test" then found = p end
    end
    check("string passthrough property exists", found ~= nil)
    -- String is passed through unchanged
    check("string value passed through", found and found.property_value == raw_json)
end

-- ═══════════════════════════════════════════════════════════════
-- Summary
-- ═══════════════════════════════════════════════════════════════

print(string.format("\n%d passed, %d failed", pass_count, fail_count))

if fail_count > 0 then
    os.exit(1)
else
    print("✅ test_property_model.lua passed")
end
