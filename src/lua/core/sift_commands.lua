--- Sift command functions: wire sift_state to project settings persistence.
--
-- Uses database.get_project_settings / set_project_setting for
-- SQL isolation compliance — no raw db connection needed.
--
-- @file sift_commands.lua

local sift_state = require("core.sift_state")
local database = require("core.database")
local json = require("dkjson")

local M = {}

local SIFT_KEY = "sift_state"

-- ============================================================================
-- Internal: persist/restore via database module (isolation-safe)
-- ============================================================================

local function persist_sift(project_id)
    if sift_state.is_active() then
        database.set_project_setting(project_id, SIFT_KEY, sift_state.to_json())
    else
        database.set_project_setting(project_id, SIFT_KEY, json.null)
    end
end

-- ============================================================================
-- Public API
-- ============================================================================

function M.sift(clips, query, project_id)
    assert(clips, "sift_commands.sift: clips required")
    assert(query, "sift_commands.sift: query required")
    assert(project_id, "sift_commands.sift: project_id required")
    sift_state.apply(clips, query)
    persist_sift(project_id)
end

function M.expand_sift(clips, query, project_id)
    assert(clips, "sift_commands.expand_sift: clips required")
    assert(query, "sift_commands.expand_sift: query required")
    assert(project_id, "sift_commands.expand_sift: project_id required")
    sift_state.expand(clips, query)
    persist_sift(project_id)
end

function M.narrow_sift(clips, query, project_id)
    assert(clips, "sift_commands.narrow_sift: clips required")
    assert(query, "sift_commands.narrow_sift: query required")
    assert(project_id, "sift_commands.narrow_sift: project_id required")
    sift_state.narrow(clips, query)
    persist_sift(project_id)
end

function M.clear_sift(project_id)
    assert(project_id, "sift_commands.clear_sift: project_id required")
    sift_state.clear()
    persist_sift(project_id)
end

function M.restore_sift(clips, project_id)
    assert(project_id, "sift_commands.restore_sift: project_id required")
    local settings = database.get_project_settings(project_id)
    if settings and settings[SIFT_KEY] then
        sift_state.from_json(settings[SIFT_KEY])
        sift_state.evaluate(clips)
    end
end

return M
