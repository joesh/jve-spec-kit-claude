--- Browser sort: key extractors, type grouping, primary+secondary comparator
--
-- Responsibilities:
-- - Sort browser items by column with type grouping (bins < timelines < clips)
-- - Support primary + optional secondary sort with independent directions
--
-- @file browser_sort.lua
local M = {}

-- Column indices (0-based, matching tree widget columns)
M.COL_NAME       = 0
M.COL_DURATION   = 1
M.COL_RESOLUTION = 2
M.COL_FPS        = 3
M.COL_CODEC      = 4
M.COL_DATE       = 5

-- Type rank: bins first, then timelines, then clips
local TYPE_RANK = {
    bin          = 0,
    timeline     = 1,
    master_clip  = 2,
}

local function type_rank(item)
    return TYPE_RANK[item.type] or 3
end

-- Key extractors: return a comparable value for each column
local function extract_name(item)
    return (item.name or ""):lower()
end

local function extract_duration(item)
    return item.duration or 0
end

local function extract_resolution(item)
    return (item.width or 0) * (item.height or 0)
end

local function extract_fps(item)
    return item.fps_float or 0
end

local function extract_codec(item)
    return (item.codec or ""):lower()
end

local function extract_date(item)
    return item.modified_at or item.created_at or ""
end

local EXTRACTORS = {
    [M.COL_NAME]       = extract_name,
    [M.COL_DURATION]   = extract_duration,
    [M.COL_RESOLUTION] = extract_resolution,
    [M.COL_FPS]        = extract_fps,
    [M.COL_CODEC]      = extract_codec,
    [M.COL_DATE]       = extract_date,
}

--- Compare two values with direction.
-- Returns true if a should come before b in the given order.
local function compare_values(a, b, order)
    if a == b then return nil end  -- tie
    local less
    if type(a) == "number" and type(b) == "number" then
        less = a < b
    else
        less = tostring(a) < tostring(b)
    end
    if order == "desc" then
        return not less
    end
    return less
end

--- Sort items in-place.
-- @param items         array of item tables (must have .type, and fields for extractors)
-- @param primary_col   column index (0-based)
-- @param primary_order "asc" or "desc"
-- @param secondary_col optional column index (nil = no secondary)
-- @param secondary_order optional "asc" or "desc"
function M.sort_items(items, primary_col, primary_order, secondary_col, secondary_order)
    assert(EXTRACTORS[primary_col], "browser_sort: invalid primary_col " .. tostring(primary_col))
    if secondary_col ~= nil then
        assert(EXTRACTORS[secondary_col], "browser_sort: invalid secondary_col " .. tostring(secondary_col))
    end

    local primary_ext = EXTRACTORS[primary_col]
    local secondary_ext = secondary_col and EXTRACTORS[secondary_col] or nil
    local name_ext = EXTRACTORS[M.COL_NAME]

    table.sort(items, function(a, b)
        -- 1. Type grouping (always first)
        local ra, rb = type_rank(a), type_rank(b)
        if ra ~= rb then return ra < rb end

        -- 2. Primary sort
        local pa, pb = primary_ext(a), primary_ext(b)
        local cmp = compare_values(pa, pb, primary_order)
        if cmp ~= nil then return cmp end

        -- 3. Secondary sort (if set)
        if secondary_ext then
            local sa, sb = secondary_ext(a), secondary_ext(b)
            cmp = compare_values(sa, sb, secondary_order or "asc")
            if cmp ~= nil then return cmp end
        end

        -- 4. Name tiebreaker (always ascending)
        local na, nb = name_ext(a), name_ext(b)
        if na ~= nb then return na < nb end

        return false
    end)
end

--- Handle a header click — update sort state.
-- @param state       sort state table {primary_col, primary_order, secondary_col, secondary_order}
-- @param col         clicked column index
-- @param cmd_held    boolean, true if Cmd/Ctrl was held
-- @return state (mutated in place)
function M.handle_header_click(state, col, cmd_held)
    if cmd_held then
        -- Cmd+click: secondary sort
        if col == state.primary_col then
            -- Can't be both primary and secondary — ignore
            return state
        end
        if col == state.secondary_col then
            -- Toggle secondary direction
            state.secondary_order = (state.secondary_order == "asc") and "desc" or "asc"
        else
            -- New secondary column
            state.secondary_col = col
            state.secondary_order = "asc"
        end
    else
        -- Plain click: primary sort
        if col == state.primary_col then
            -- Toggle primary direction
            state.primary_order = (state.primary_order == "asc") and "desc" or "asc"
        else
            -- New primary column
            -- If it was the secondary, clear secondary
            if col == state.secondary_col then
                state.secondary_col = nil
                state.secondary_order = nil
            end
            state.primary_col = col
            state.primary_order = "asc"
        end
    end
    return state
end

--- Build header labels with sort indicators.
-- @param base_headers array of base header strings (1-indexed)
-- @param state        sort state table
-- @return array of header strings with indicators
function M.build_header_labels(base_headers, state)
    local labels = {}
    for i, base in ipairs(base_headers) do
        local col = i - 1  -- 0-based
        if col == state.primary_col then
            local arrow = (state.primary_order == "asc") and " \xe2\x96\xb2" or " \xe2\x96\xbc"
            labels[i] = base .. arrow
        elseif col == state.secondary_col then
            local arrow = (state.secondary_order == "asc") and " \xe2\x96\xb3" or " \xe2\x96\xbd"
            labels[i] = base .. arrow
        else
            labels[i] = base
        end
    end
    return labels
end

return M
