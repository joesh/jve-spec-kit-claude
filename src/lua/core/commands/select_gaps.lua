--- SelectGaps Command - Handle timeline gap selection with modifier semantics
--
-- Encapsulates gap selection logic:
-- - Command modifier: toggle (select if not selected, deselect if selected)
-- - No modifier: replace selection with target gap
--
-- @file select_gaps.lua
local M = {}

local timeline_state = require("ui.timeline.timeline_state")

local SPEC = {
    undoable = false,
    args = {
        project_id = { required = true },
        sequence_id = { required = true },
        target_gaps = { required = true, kind = "table" },
        modifiers = { required = false, kind = "table" },
    },
}

local function gaps_equal(a, b)
    if not a or not b or a.track_id ~= b.track_id then return false end
    if (a.start_value or 0) ~= (b.start_value or 0) then return false end
    if (a.duration or a.duration_value or 0) ~= (b.duration or b.duration_value or 0) then return false end
    return true
end

local function selection_contains_gap(selection, gap)
    for _, sel in ipairs(selection) do
        if gaps_equal(sel, gap) then
            return true
        end
    end
    return false
end

local function selection_contains_all(selection, gaps)
    for _, gap in ipairs(gaps) do
        if not selection_contains_gap(selection, gap) then
            return false
        end
    end
    return true
end

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["SelectGaps"] = function(command)
        local args = command:get_all_parameters()
        local modifiers = args.modifiers or {}
        local target_gaps = args.target_gaps or {}

        -- Get current selection
        local current_gaps = timeline_state.get_selected_gaps() or {}

        -- Check if all targets are already selected
        local all_selected = selection_contains_all(current_gaps, target_gaps)

        local new_selection = {}

        if modifiers.command then
            if all_selected then
                -- Remove targets from selection
                for _, gap in ipairs(current_gaps) do
                    local is_target = false
                    for _, target in ipairs(target_gaps) do
                        if gaps_equal(gap, target) then
                            is_target = true
                            break
                        end
                    end
                    if not is_target then
                        table.insert(new_selection, gap)
                    end
                end
            else
                -- Add targets to selection (keep existing + add new)
                for _, gap in ipairs(current_gaps) do
                    table.insert(new_selection, gap)
                end
                for _, gap in ipairs(target_gaps) do
                    if not selection_contains_gap(current_gaps, gap) then
                        table.insert(new_selection, gap)
                    end
                end
            end
        else
            if all_selected and #target_gaps == #current_gaps then
                -- Already selected, no change (allows drag initiation)
                new_selection = current_gaps
            else
                -- Replace selection with targets
                new_selection = target_gaps
            end
        end

        -- Apply selection (clears clips and edges)
        timeline_state.set_gap_selection(new_selection)

        return {
            success = true,
            selected_count = #new_selection,
        }
    end

    return {
        ["SelectGaps"] = {
            executor = command_executors["SelectGaps"],
            spec = SPEC,
        },
    }
end

return M
