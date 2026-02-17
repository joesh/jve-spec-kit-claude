--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~178 LOC
-- Volatility: unknown
--
-- @file tag_service.lua
-- Original intent (unreviewed):
-- Tag service: higher-level helpers for hierarchical tag namespaces
local database = require("core.database")
local uuid = require("uuid")

local M = {}
local DEFAULT_NAMESPACE = "bin"

local function trim(value)
    if type(value) ~= "string" then
        return ""
    end
    local stripped = value:match("^%s*(.-)%s*$")
    return stripped or ""
end

local function normalize_namespace(opts)
    opts = opts or {}
    local namespace_id = opts.namespace_id or DEFAULT_NAMESPACE
    local display_name = opts.display_name
    if not display_name or display_name == "" then
        if namespace_id == DEFAULT_NAMESPACE then
            display_name = "Bins"
        else
            display_name = namespace_id
        end
    end
    return namespace_id, display_name, {namespace_id = namespace_id, display_name = display_name}
end

local function load_hierarchy(project_id, opts)
    local _, _, namespace_opts = normalize_namespace(opts)
    return database.load_bins(project_id, namespace_opts), namespace_opts
end

local function persist_hierarchy(project_id, bins, namespace_opts)
    return database.save_bins(project_id, bins, namespace_opts)
end

local function find_bin(bins, bin_id)
    for index, bin in ipairs(bins) do
        if bin.id == bin_id then
            return index, bin
        end
    end
    return nil, nil
end

function M.list(project_id, opts)
    local bins = database.load_bins(project_id, opts)
    return bins or {}
end

function M.save_hierarchy(project_id, bins, opts)
    if not project_id or project_id == "" then
        return false, "tag_service.save_hierarchy: missing project_id"
    end
    local _, _, namespace_opts = normalize_namespace(opts)
    return database.save_bins(project_id, bins, namespace_opts)
end

function M.create_bin(project_id, params)
    params = params or {}
    local _, _, namespace_opts = normalize_namespace(params)
    local bins = database.load_bins(project_id, namespace_opts)

    local name = trim(params.name)
    if name == "" then
        name = "New Bin"
    end

    local new_id = params.id or uuid.generate()
    for _, existing in ipairs(bins) do
        if existing.id == new_id then
            return false, "Duplicate bin identifier"
        end
    end

    local parent_id = params.parent_id
    if parent_id and parent_id ~= "" then
        local _, parent = find_bin(bins, parent_id)
        if not parent then
            return false, string.format("Parent bin %s not found", tostring(parent_id))
        end
    else
        parent_id = nil
    end

    local definition = {
        id = new_id,
        name = name,
        parent_id = parent_id
    }
    table.insert(bins, definition)

    if not persist_hierarchy(project_id, bins, namespace_opts) then
        return false, "Failed to persist bin hierarchy"
    end

    return true, definition
end

function M.rename_bin(project_id, bin_id, new_name, opts)
    new_name = trim(new_name or "")
    if new_name == "" then
        return false, "New name cannot be empty"
    end

    local bins, namespace_opts = load_hierarchy(project_id, opts)
    local _, target = find_bin(bins, bin_id)
    if not target then
        return false, "Bin not found"
    end

    local previous = target.name
    if previous == new_name then
        return true, {previous_name = previous}
    end

    target.name = new_name
    if not persist_hierarchy(project_id, bins, namespace_opts) then
        return false, "Failed to persist bin hierarchy"
    end

    return true, {previous_name = previous}
end

function M.remove_bin(project_id, bin_id, opts)
    local bins, namespace_opts = load_hierarchy(project_id, opts)
    local index, target = find_bin(bins, bin_id)
    if not target then
        return false, "Bin not found"
    end

    local child_snapshot = {}
    for _, bin in ipairs(bins) do
        if bin.parent_id == bin_id then
            table.insert(child_snapshot, {id = bin.id, parent_id = bin.parent_id})
            bin.parent_id = nil
        end
    end

    table.remove(bins, index)
    if not persist_hierarchy(project_id, bins, namespace_opts) then
        return false, "Failed to persist bin hierarchy"
    end

    return true, {
        definition = target,
        child_snapshot = child_snapshot,
        insert_index = index
    }
end

function M.restore_bin(project_id, definition, insert_index, child_snapshot, opts)
    if not definition or not definition.id then
        return false, "Missing bin definition"
    end

    local bins, namespace_opts = load_hierarchy(project_id, opts)
    local existing_index = select(1, find_bin(bins, definition.id))
    if existing_index then
        return true, {}
    end

    local index = tonumber(insert_index) or (#bins + 1)
    if index < 1 then
        index = 1
    elseif index > (#bins + 1) then
        index = #bins + 1
    end
    table.insert(bins, index, {
        id = definition.id,
        name = definition.name,
        parent_id = definition.parent_id
    })

    if type(child_snapshot) == "table" then
        local restore_lookup = {}
        for _, entry in ipairs(child_snapshot) do
            if entry.id then
                restore_lookup[entry.id] = entry.parent_id
            end
        end
        for _, bin in ipairs(bins) do
            if restore_lookup[bin.id] ~= nil then
                bin.parent_id = restore_lookup[bin.id]
            end
        end
    end

    if not persist_hierarchy(project_id, bins, namespace_opts) then
        return false, "Failed to persist bin hierarchy"
    end

    return true, {}
end

function M.list_master_clip_assignments(project_id)
    return database.load_master_clip_bin_map(project_id)
end

function M.list_sequence_assignments(project_id)
    return database.load_bin_map(project_id, "sequence")
end

--- Add entities to a bin (INSERT OR IGNORE — idempotent, many-to-many safe).
-- Use for import paths where an entity may already be in the bin.
function M.add_to_bin(project_id, entity_ids, bin_id, entity_type)
    return database.add_to_bin(project_id, entity_ids, bin_id, entity_type or "master_clip")
end

--- Remove entities from a specific bin (targeted DELETE, many-to-many safe).
-- Use for MoveToBin where only the source assignment should be removed.
function M.remove_from_bin(project_id, entity_ids, bin_id, entity_type)
    return database.remove_from_bin(project_id, entity_ids, bin_id, entity_type or "master_clip")
end

--- Move entities to a bin (DELETE ALL old + INSERT new — exclusive assignment).
-- Use only when entity should be in exactly one bin.
function M.set_bin(project_id, entity_ids, bin_id, entity_type)
    return database.set_bin(project_id, entity_ids, bin_id, entity_type or "master_clip")
end

-- Legacy aliases
function M.assign_master_clips(project_id, clip_ids, bin_id)
    return M.set_bin(project_id, clip_ids, bin_id, "master_clip")
end

function M.assign_master_clip(project_id, clip_id, bin_id)
    if not clip_id or clip_id == "" then
        return false
    end
    return M.set_bin(project_id, {clip_id}, bin_id, "master_clip")
end

return M
