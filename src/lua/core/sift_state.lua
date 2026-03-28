--- Sift state management for project browser filtering.
--
-- Manages the accumulated sift criteria and computes which clips
-- are visible vs hidden. Supports compositional operations:
-- apply (fresh), expand (OR), narrow (AND), clear.
--
-- Persists to/from JSON for project settings storage.
--
-- @file sift_state.lua

local query_engine = require("core.query_engine")
local json = require("dkjson")

local M = {}

-- Internal state
local active = false
local criteria = {}       -- array of {query={column,operator,value}, mode="fresh"|"expand"|"narrow"}
local hidden_ids = {}     -- set: clip_id → true for hidden clips
local visible_ids = {}    -- set: clip_id → true for visible clips

-- ============================================================================
-- Internal: recompute visible/hidden from criteria and clips
-- ============================================================================

local function recompute(clips)
    hidden_ids = {}
    visible_ids = {}

    if not active or #criteria == 0 then
        -- No sift: all visible
        for _, clip in ipairs(clips) do
            visible_ids[clip.id] = true
        end
        return
    end

    -- Build the visible set by replaying criteria in order
    local current_visible = {}  -- set of clip IDs

    for i, entry in ipairs(criteria) do
        local matching, _ = query_engine.filter(clips, {entry.query})

        if entry.mode == "fresh" or i == 1 then
            -- Fresh: visible = matching
            current_visible = {}
            for _, clip in ipairs(matching) do
                current_visible[clip.id] = true
            end
        elseif entry.mode == "expand" then
            -- OR: add matching to visible
            for _, clip in ipairs(matching) do
                current_visible[clip.id] = true
            end
        elseif entry.mode == "narrow" then
            -- AND: intersect — remove from visible anything not matching
            local new_visible = {}
            for _, clip in ipairs(matching) do
                if current_visible[clip.id] then
                    new_visible[clip.id] = true
                end
            end
            current_visible = new_visible
        end
    end

    -- Build hidden/visible sets
    visible_ids = current_visible
    for _, clip in ipairs(clips) do
        if not visible_ids[clip.id] then
            hidden_ids[clip.id] = true
        end
    end
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Apply a fresh sift, replacing any existing criteria.
-- @param clips array of clip_data tables
-- @param query {column, operator, value}
function M.apply(clips, query)
    assert(query and query.column, "sift_state.apply: query required")
    active = true
    criteria = {{query = query, mode = "fresh"}}
    recompute(clips)
end

--- Expand sift (OR) — show additional clips matching new criteria.
-- @param clips array of clip_data tables
-- @param query {column, operator, value}
function M.expand(clips, query)
    assert(query and query.column, "sift_state.expand: query required")
    if not active then
        -- Expand with no active sift acts as fresh apply
        return M.apply(clips, query)
    end
    criteria[#criteria + 1] = {query = query, mode = "expand"}
    recompute(clips)
end

--- Narrow sift (AND) — hide clips within visible set that don't match.
-- @param clips array of clip_data tables
-- @param query {column, operator, value}
function M.narrow(clips, query)
    assert(query and query.column, "sift_state.narrow: query required")
    assert(active, "sift_state.narrow: no active sift to narrow")
    criteria[#criteria + 1] = {query = query, mode = "narrow"}
    recompute(clips)
end

--- Clear all sift state.
function M.clear()
    active = false
    criteria = {}
    hidden_ids = {}
    visible_ids = {}
end

--- Check if a sift filter is currently active.
-- @return boolean
function M.is_active()
    return active
end

--- Get current criteria.
-- @return array of {query, mode}
function M.get_criteria()
    return criteria
end

--- Re-evaluate current criteria against a (possibly changed) clip set.
-- @param clips array of clip_data tables
-- @return table {visible_ids=array of IDs, hidden_ids=array of IDs}
function M.evaluate(clips)
    if not active then
        local vis = {}
        for _, clip in ipairs(clips) do
            vis[#vis + 1] = clip.id
        end
        return {visible_ids = vis, hidden_ids = {}}
    end
    recompute(clips)
    local vis_arr = {}
    for id in pairs(visible_ids) do vis_arr[#vis_arr + 1] = id end
    local hid_arr = {}
    for id in pairs(hidden_ids) do hid_arr[#hid_arr + 1] = id end
    return {visible_ids = vis_arr, hidden_ids = hid_arr}
end

--- Check if a specific clip is hidden by the current sift.
-- @param clip_id string
-- @return boolean
function M.is_hidden(clip_id)
    return hidden_ids[clip_id] == true
end

--- Serialize sift state to JSON for project settings persistence.
-- @return string JSON
function M.to_json()
    local data = {
        active = active,
        criteria = {},
    }
    for _, entry in ipairs(criteria) do
        data.criteria[#data.criteria + 1] = {
            query = entry.query,
            mode = entry.mode,
        }
    end
    return json.encode(data)
end

--- Restore sift state from JSON. Call evaluate() after to compute visibility.
-- @param json_str string
function M.from_json(json_str)
    assert(json_str and json_str ~= "", "sift_state.from_json: json_str required")
    local data = json.decode(json_str)
    assert(data, "sift_state.from_json: invalid JSON")
    active = data.active or false
    criteria = {}
    if data.criteria then
        for _, entry in ipairs(data.criteria) do
            criteria[#criteria + 1] = {
                query = entry.query,
                mode = entry.mode,
            }
        end
    end
    -- Note: caller must call evaluate(clips) to populate hidden/visible sets
    hidden_ids = {}
    visible_ids = {}
end

return M
