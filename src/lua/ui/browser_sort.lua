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

-- Sorting is now handled by Qt's SORT_TREE (QTreeWidget::sortItems).
-- This module only provides header click state management and label building.

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
