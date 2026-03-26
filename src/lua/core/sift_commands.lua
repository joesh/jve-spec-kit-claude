--- Sift command functions: wire sift_state to project settings persistence.
--
-- These are called by command executors or directly by UI.
-- They apply sift operations and persist criteria to project settings.
--
-- @file sift_commands.lua

local sift_state = require("core.sift_state")
local json = require("dkjson")

local M = {}

-- ============================================================================
-- Internal: read/write project settings
-- ============================================================================

local function read_settings(db, project_id)
    local stmt = db:prepare("SELECT settings FROM projects WHERE id = ?")
    stmt:bind_value(1, project_id)
    assert(stmt:exec() and stmt:next(), "sift_commands: project not found: " .. tostring(project_id))
    local raw = stmt:value(0)
    stmt:finalize()
    return json.decode(raw) or {}
end

local function write_settings(db, project_id, settings)
    local stmt = db:prepare("UPDATE projects SET settings = ? WHERE id = ?")
    stmt:bind_value(1, json.encode(settings))
    stmt:bind_value(2, project_id)
    assert(stmt:exec(), "sift_commands: failed to write settings")
    stmt:finalize()
end

local function persist_sift(db, project_id)
    local settings = read_settings(db, project_id)
    if sift_state.is_active() then
        settings.sift_state = sift_state.to_json()
    else
        settings.sift_state = nil
    end
    write_settings(db, project_id, settings)
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Apply a fresh sift filter.
function M.sift(clips, query, db, project_id)
    assert(clips, "sift_commands.sift: clips required")
    assert(query, "sift_commands.sift: query required")
    sift_state.apply(clips, query)
    persist_sift(db, project_id)
end

--- Expand sift (OR — show additional matches).
function M.expand_sift(clips, query, db, project_id)
    assert(clips, "sift_commands.expand_sift: clips required")
    assert(query, "sift_commands.expand_sift: query required")
    sift_state.expand(clips, query)
    persist_sift(db, project_id)
end

--- Narrow sift (AND — hide within visible set).
function M.narrow_sift(clips, query, db, project_id)
    assert(clips, "sift_commands.narrow_sift: clips required")
    assert(query, "sift_commands.narrow_sift: query required")
    sift_state.narrow(clips, query)
    persist_sift(db, project_id)
end

--- Clear all sift state.
function M.clear_sift(db, project_id)
    sift_state.clear()
    persist_sift(db, project_id)
end

--- Restore sift state from project settings (called on project open).
function M.restore_sift(clips, db, project_id)
    local settings = read_settings(db, project_id)
    if settings.sift_state then
        sift_state.from_json(settings.sift_state)
        sift_state.evaluate(clips)
    end
end

return M
