--- Property Model
--
-- Responsibilities:
-- - Load clip properties from database
-- - Save clip properties to database
-- - Copy properties from one clip to another
-- - Delete properties for clips
--
-- Non-goals:
-- - Property validation (done by caller)
-- - Property type conversion (done by caller)
--
-- Invariants:
-- - All properties belong to a clip (clip_id foreign key)
-- - Property values stored as JSON strings
--
-- Size: ~150 LOC
-- Volatility: low
--
-- @file property.lua
local database = require("core.database")
local uuid = require("uuid")
local json = require("dkjson")

local Property = {}
Property.__index = Property

local function resolve_db()
    local conn = database.get_connection()
    assert(conn, "Property model: No database connection available")
    return conn
end

local function encode_property_json(raw)
    if raw == nil or raw == "" then
        return json.encode({ value = nil })
    end
    if type(raw) == "string" then
        return raw
    end
    local encoded = json.encode({ value = raw })
    if not encoded then
        return json.encode({ value = nil })
    end
    return encoded
end

function Property.load_for_clip(clip_id)
    assert(clip_id and clip_id ~= "", "Property.load_for_clip: clip_id is required")

    local conn = resolve_db()
    local stmt = conn:prepare([[
        SELECT id, property_name, property_value, property_type, default_value
        FROM properties
        WHERE clip_id = ?
    ]])

    assert(stmt, "Property.load_for_clip: Failed to prepare query")

    stmt:bind_value(1, clip_id)

    local ok = stmt:exec()
    assert(ok, string.format(
        "Property.load_for_clip: Query execution failed for clip_id=%s",
        tostring(clip_id)
    ))

    local props = {}
    while stmt:next() do
        table.insert(props, {
            id = stmt:value(0),
            property_name = stmt:value(1),
            property_value = stmt:value(2),
            property_type = stmt:value(3),
            default_value = stmt:value(4)
        })
    end

    stmt:finalize()
    return props
end

function Property.copy_for_clip(source_clip_id)
    assert(source_clip_id and source_clip_id ~= "", "Property.copy_for_clip: source_clip_id is required")

    local conn = resolve_db()
    local stmt = conn:prepare([[
        SELECT property_name, property_value, property_type, default_value
        FROM properties
        WHERE clip_id = ?
    ]])

    assert(stmt, "Property.copy_for_clip: Failed to prepare query")

    stmt:bind_value(1, source_clip_id)

    local ok = stmt:exec()
    assert(ok, string.format(
        "Property.copy_for_clip: Query execution failed for clip_id=%s",
        tostring(source_clip_id)
    ))

    local props = {}
    while stmt:next() do
        local property_name = stmt:value(0)
        local property_value = encode_property_json(stmt:value(1))
        local property_type = stmt:value(2) or "STRING"
        local default_value = stmt:value(3)
        if default_value == nil or default_value == "" then
            default_value = json.encode({ value = nil })
        end

        table.insert(props, {
            id = uuid.generate(),
            property_name = property_name,
            property_value = property_value,
            property_type = property_type,
            default_value = default_value
        })
    end

    stmt:finalize()
    return props
end

function Property.save_for_clip(clip_id, properties)
    assert(clip_id and clip_id ~= "", "Property.save_for_clip: clip_id is required")

    if not properties or #properties == 0 then
        return true
    end

    local conn = resolve_db()
    -- Use ON CONFLICT DO UPDATE for consistency with other models
    local stmt = conn:prepare([[
        INSERT INTO properties
        (id, clip_id, property_name, property_value, property_type, default_value)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            clip_id = excluded.clip_id,
            property_name = excluded.property_name,
            property_value = excluded.property_value,
            property_type = excluded.property_type,
            default_value = excluded.default_value
    ]])

    assert(stmt, string.format(
        "Property.save_for_clip: Failed to prepare INSERT statement for clip_id=%s",
        tostring(clip_id)
    ))

    for _, prop in ipairs(properties) do
        stmt:bind_value(1, prop.id or uuid.generate())
        stmt:bind_value(2, clip_id)
        stmt:bind_value(3, prop.property_name)
        stmt:bind_value(4, encode_property_json(prop.property_value))
        stmt:bind_value(5, prop.property_type or "STRING")
        stmt:bind_value(6, encode_property_json(prop.default_value))

        local ok = stmt:exec()
        local err = stmt.last_error and stmt:last_error(stmt) or "unknown"

        assert(ok, string.format(
            "Property.save_for_clip: Failed to insert property %s for clip %s: %s",
            tostring(prop.property_name),
            tostring(clip_id),
            tostring(err)
        ))

        stmt:reset()
        stmt:clear_bindings()
    end

    stmt:finalize()
    return true
end

function Property.delete_for_clip(clip_id)
    assert(clip_id and clip_id ~= "", "Property.delete_for_clip: clip_id is required")

    local conn = resolve_db()
    local stmt = conn:prepare("DELETE FROM properties WHERE clip_id = ?")
    assert(stmt, string.format(
        "Property.delete_for_clip: Failed to prepare DELETE statement for clip_id=%s",
        tostring(clip_id)
    ))

    stmt:bind_value(1, clip_id)
    local ok = stmt:exec()
    local err = stmt.last_error and stmt:last_error(stmt) or "unknown"

    stmt:finalize()

    assert(ok, string.format(
        "Property.delete_for_clip: Failed to delete properties for clip %s: %s",
        tostring(clip_id),
        tostring(err)
    ))

    return true
end

function Property.delete_by_ids(property_ids)
    if not property_ids or #property_ids == 0 then
        return true
    end

    local conn = resolve_db()
    local stmt = conn:prepare("DELETE FROM properties WHERE id = ?")
    assert(stmt, "Property.delete_by_ids: Failed to prepare DELETE statement")

    for _, prop_id in ipairs(property_ids) do
        if prop_id and prop_id ~= "" then
            stmt:bind_value(1, prop_id)
            local ok = stmt:exec()
            local err = stmt.last_error and stmt:last_error(stmt) or "unknown"

            assert(ok, string.format(
                "Property.delete_by_ids: Failed to delete property %s: %s",
                tostring(prop_id),
                tostring(err)
            ))

            stmt:reset()
            stmt:clear_bindings()
        end
    end

    stmt:finalize()
    return true
end

return Property
