--- Smart Bin model: persistent query-based bins.
--
-- CRUD operations for the smart_bins table.
-- Evaluate function applies criteria via query_engine.
--
-- @file smart_bin.lua

local uuid = require("uuid")
local json = require("dkjson")
local query_engine = require("core.query_engine")

local M = {}

-- ============================================================================
-- CRUD
-- ============================================================================

--- Create a new smart bin.
-- @param db database connection
-- @param opts {project_id, name, criteria_json, scope_bin_id}
-- @return smart bin record table
function M.create(db, opts)
    assert(opts.project_id, "smart_bin.create: project_id required")
    assert(opts.name and opts.name ~= "", "smart_bin.create: name required")
    assert(opts.criteria_json, "smart_bin.create: criteria_json required")

    local id = uuid.generate_with_prefix("smart_bin")
    local now = os.time()
    local stmt = db:prepare([[
        INSERT INTO smart_bins (id, project_id, name, scope_bin_id, criteria_json, created_at, modified_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    ]])
    stmt:bind_value(1, id)
    stmt:bind_value(2, opts.project_id)
    stmt:bind_value(3, opts.name)
    stmt:bind_value(4, opts.scope_bin_id)  -- nil = NULL = project-wide
    stmt:bind_value(5, opts.criteria_json)
    stmt:bind_value(6, now)
    stmt:bind_value(7, now)
    assert(stmt:exec(), "smart_bin.create: INSERT failed")
    stmt:finalize()

    return {
        id = id,
        project_id = opts.project_id,
        name = opts.name,
        scope_bin_id = opts.scope_bin_id,
        criteria_json = opts.criteria_json,
        created_at = now,
        modified_at = now,
    }
end

--- Find all smart bins for a project.
-- @param db database connection
-- @param project_id string
-- @return array of smart bin records
function M.find_by_project(db, project_id)
    assert(project_id, "smart_bin.find_by_project: project_id required")
    local stmt = db:prepare([[
        SELECT id, project_id, name, scope_bin_id, criteria_json, created_at, modified_at
        FROM smart_bins WHERE project_id = ? ORDER BY name
    ]])
    stmt:bind_value(1, project_id)
    local results = {}
    if stmt:exec() then
        while stmt:next() do
            results[#results + 1] = {
                id = stmt:value(0),
                project_id = stmt:value(1),
                name = stmt:value(2),
                scope_bin_id = stmt:value(3),
                criteria_json = stmt:value(4),
                created_at = stmt:value(5),
                modified_at = stmt:value(6),
            }
        end
    end
    stmt:finalize()
    return results
end

--- Find a smart bin by ID.
-- @param db database connection
-- @param id string
-- @return smart bin record or nil
function M.find_by_id(db, id)
    assert(id, "smart_bin.find_by_id: id required")
    local stmt = db:prepare([[
        SELECT id, project_id, name, scope_bin_id, criteria_json, created_at, modified_at
        FROM smart_bins WHERE id = ?
    ]])
    stmt:bind_value(1, id)
    local result = nil
    if stmt:exec() and stmt:next() then
        result = {
            id = stmt:value(0),
            project_id = stmt:value(1),
            name = stmt:value(2),
            scope_bin_id = stmt:value(3),
            criteria_json = stmt:value(4),
            created_at = stmt:value(5),
            modified_at = stmt:value(6),
        }
    end
    stmt:finalize()
    return result
end

--- Update a smart bin.
-- @param db database connection
-- @param id string
-- @param fields table of fields to update {name, criteria_json, scope_bin_id}
function M.update(db, id, fields)
    assert(id, "smart_bin.update: id required")
    assert(fields and next(fields), "smart_bin.update: fields required")

    local sets = {}
    local values = {}
    if fields.name ~= nil then
        sets[#sets + 1] = "name = ?"
        values[#values + 1] = fields.name
    end
    if fields.criteria_json ~= nil then
        sets[#sets + 1] = "criteria_json = ?"
        values[#values + 1] = fields.criteria_json
    end
    if fields.scope_bin_id ~= nil then
        sets[#sets + 1] = "scope_bin_id = ?"
        values[#values + 1] = fields.scope_bin_id
    end
    sets[#sets + 1] = "modified_at = ?"
    values[#values + 1] = os.time()

    local sql = "UPDATE smart_bins SET " .. table.concat(sets, ", ") .. " WHERE id = ?"
    values[#values + 1] = id

    local stmt = db:prepare(sql)
    for i, v in ipairs(values) do
        stmt:bind_value(i, v)
    end
    assert(stmt:exec(), "smart_bin.update: UPDATE failed")
    stmt:finalize()
end

--- Delete a smart bin.
-- @param db database connection
-- @param id string
function M.delete(db, id)
    assert(id, "smart_bin.delete: id required")
    local stmt = db:prepare("DELETE FROM smart_bins WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec(), "smart_bin.delete: DELETE failed")
    stmt:finalize()
end

-- ============================================================================
-- Evaluation
-- ============================================================================

--- Evaluate a smart bin's criteria against a list of clips.
-- @param smart_bin_record table with criteria_json field
-- @param clips array of clip_data tables
-- @return array of matching clip IDs
function M.evaluate(smart_bin_record, clips)
    assert(smart_bin_record, "smart_bin.evaluate: smart_bin_record required")
    assert(smart_bin_record.criteria_json, "smart_bin.evaluate: criteria_json required")

    local criteria = json.decode(smart_bin_record.criteria_json)
    assert(criteria, "smart_bin.evaluate: invalid criteria_json")

    local matching, _ = query_engine.filter(clips, criteria)
    local ids = {}
    for _, clip in ipairs(matching) do
        ids[#ids + 1] = clip.id
    end
    return ids
end

return M
