--- SelectEdges Command - Handle timeline edge selection with modifier semantics
--
-- Encapsulates all edge selection logic:
-- - Alt/Option modifier: expand target edges to include same edge on linked clips
-- - Command modifier: toggle (add if not selected, remove if selected)
-- - No modifier on unselected: replace selection
-- - No modifier on selected: no change (allows drag)
--
-- @file select_edges.lua
local M = {}

local clip_links = require("models.clip_link")
local timeline_state = require("ui.timeline.timeline_state")

local SPEC = {
    undoable = false,
    args = {
        project_id = { required = true },
        sequence_id = { required = true },
        target_edges = { required = true, kind = "table" },
        modifiers = { required = false, kind = "table" },
    },
}

--- Expand edges to include same edge_type on all linked clips
--- For each edge, finds linked clips and adds the same edge_type with same trim_type
local function expand_to_linked_edges(edges, db)
    local expanded = {}
    local seen = {}

    for _, edge in ipairs(edges) do
        -- Add the original edge if not already seen
        local key = edge.clip_id .. ":" .. edge.edge_type
        if not seen[key] then
            seen[key] = true
            table.insert(expanded, {
                clip_id = edge.clip_id,
                edge_type = edge.edge_type,
                trim_type = edge.trim_type,
            })
        end

        -- Find linked clips and add the same edge_type
        -- Note: we don't track processed_groups because the same clip may need
        -- different edge_types added (e.g., roll between clip out + gap_after)
        local link_group = clip_links.get_link_group(edge.clip_id, db)
        if link_group then
            for _, link_info in ipairs(link_group) do
                if link_info.enabled then
                    local linked_key = link_info.clip_id .. ":" .. edge.edge_type
                    if not seen[linked_key] then
                        -- Verify clip exists
                        local clip = timeline_state.get_clip_by_id(link_info.clip_id)
                        if clip then
                            seen[linked_key] = true
                            table.insert(expanded, {
                                clip_id = link_info.clip_id,
                                edge_type = edge.edge_type,
                                trim_type = edge.trim_type,
                            })
                        end
                    end
                end
            end
        end
    end

    return expanded
end

local function edges_equal(a, b)
    return a.clip_id == b.clip_id and a.edge_type == b.edge_type
end

local function selection_contains_edge(selection, edge)
    for _, sel in ipairs(selection) do
        if edges_equal(sel, edge) then
            return true
        end
    end
    return false
end

local function selection_contains_all(selection, edges)
    for _, edge in ipairs(edges) do
        if not selection_contains_edge(selection, edge) then
            return false
        end
    end
    return true
end

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["SelectEdges"] = function(command)
        local args = command:get_all_parameters()
        local modifiers = args.modifiers or {}
        local target_edges = args.target_edges or {}

        -- Alt/Option modifier: expand targets to include linked clip edges
        if modifiers.alt then
            target_edges = expand_to_linked_edges(target_edges, db)
        end

        -- Get current selection
        local current_edges = timeline_state.get_selected_edges() or {}

        -- Check if all targets are already selected
        local all_selected = selection_contains_all(current_edges, target_edges)

        -- Build target set for quick lookup
        local target_set = {}
        for _, edge in ipairs(target_edges) do
            local key = edge.clip_id .. ":" .. edge.edge_type
            target_set[key] = edge
        end

        local new_selection = {}

        if modifiers.command or modifiers.shift then
            if all_selected then
                -- Remove targets from selection
                for _, edge in ipairs(current_edges) do
                    local key = edge.clip_id .. ":" .. edge.edge_type
                    if not target_set[key] then
                        table.insert(new_selection, edge)
                    end
                end
            else
                -- Add targets to selection (keep existing + add new)
                local existing_set = {}
                for _, edge in ipairs(current_edges) do
                    local key = edge.clip_id .. ":" .. edge.edge_type
                    existing_set[key] = true
                    table.insert(new_selection, edge)
                end
                for _, edge in ipairs(target_edges) do
                    local key = edge.clip_id .. ":" .. edge.edge_type
                    if not existing_set[key] then
                        table.insert(new_selection, edge)
                    end
                end
            end
        else
            if all_selected then
                -- Already selected, no change (allows drag initiation)
                new_selection = current_edges
            else
                -- Replace selection with targets
                new_selection = target_edges
            end
        end

        -- Apply selection (clears clips and gaps)
        timeline_state.set_edge_selection(new_selection)

        return {
            success = true,
            selected_count = #new_selection,
            expanded_linked = modifiers.alt and #target_edges > #args.target_edges,
        }
    end

    return {
        ["SelectEdges"] = {
            executor = command_executors["SelectEdges"],
            spec = SPEC,
        },
    }
end

return M
