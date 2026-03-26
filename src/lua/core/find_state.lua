--- Find session state management.
--
-- Manages find/replace session: matches, cycling, previous selection.
-- Pure module, no UI dependencies.
--
-- @file find_state.lua

local query_engine = require("core.query_engine")

local M = {}

-- Internal state
local active = false
local matches = {}           -- array of clip objects (full clip_data)
local current_index = 0      -- 0 = no match, 1-based when active
local previous_selection = {}
local current_query = nil

--- Execute a find: compute matches, set current index.
-- @param clips array of clip_data tables
-- @param query table or array of query tables (column, operator, value)
-- @param opts table with optional scope ("all"|"visible") and hidden_ids
function M.execute(clips, query, opts)
    assert(type(clips) == "table", "find_state.execute: clips must be a table")
    assert(type(query) == "table", "find_state.execute: query must be a table")

    opts = opts or {}
    local scope = opts.scope or "all"

    -- Normalize single query to array
    local queries
    if query.column then
        queries = { query }
    else
        queries = query
    end

    -- Scope filtering
    local scoped_clips
    if scope == "visible" and opts.hidden_ids then
        scoped_clips = {}
        for _, clip in ipairs(clips) do
            if not opts.hidden_ids[clip.id] then
                scoped_clips[#scoped_clips + 1] = clip
            end
        end
    else
        scoped_clips = clips
    end

    -- Run query engine filter
    local matching = query_engine.filter(scoped_clips, queries)

    matches = matching
    current_query = queries
    active = true
    current_index = #matches > 0 and 1 or 0
end

--- Get array of matched clip IDs.
-- @return array of clip ID strings
function M.get_matches()
    local ids = {}
    for _, clip in ipairs(matches) do
        ids[#ids + 1] = clip.id
    end
    return ids
end

--- Get number of matches.
-- @return integer
function M.get_match_count()
    return #matches
end

--- Get current match index (1-based, 0 if no matches).
-- @return integer
function M.get_current_index()
    return current_index
end

--- Get current match clip ID.
-- @return string or nil
function M.get_current_match()
    if current_index < 1 or current_index > #matches then
        return nil
    end
    return matches[current_index].id
end

--- Advance to next match, wrapping at end.
function M.next()
    if #matches == 0 then return end
    current_index = current_index % #matches + 1
end

--- Go to previous match, wrapping at beginning.
function M.previous()
    if #matches == 0 then return end
    current_index = current_index - 1
    if current_index < 1 then current_index = #matches end
end

--- Save selection state before find (for Escape restore).
-- @param sel array of clip IDs
function M.save_selection(sel)
    assert(type(sel) == "table", "find_state.save_selection: sel must be a table")
    previous_selection = sel
end

--- Get saved previous selection.
-- @return array of clip IDs
function M.get_previous_selection()
    return previous_selection
end

--- Check if find session is active.
-- @return boolean
function M.is_active()
    return active
end

--- Get current query.
-- @return array of query tables or nil
function M.get_current_query()
    return current_query
end

--- Clear find session, reset all state.
function M.clear()
    active = false
    matches = {}
    current_index = 0
    previous_selection = {}
    current_query = nil
end

return M
