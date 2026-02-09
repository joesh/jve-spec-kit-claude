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
local edge_picker = require("ui.timeline.edge_picker")

local SPEC = {
    undoable = false,
    args = {
        project_id = { required = true },
        sequence_id = { required = true },
        target_edges = { required = true, kind = "table" },
        modifiers = { required = false, kind = "table" },
    },
}

--- Determine the "side" of an edge (downstream = out/gap_after, upstream = in/gap_before)
local function edge_to_side(edge_type)
    if edge_type == "out" or edge_type == "gap_after" then
        return "downstream"
    elseif edge_type == "in" or edge_type == "gap_before" then
        return "upstream"
    end
    return nil
end

--- Determine if edges form a roll selection (both edges at same boundary).
--- A roll requires 2+ edges with at least one "out" and one "in" (or gap equivalents),
--- all with trim_type="roll".
local function is_roll_selection(edges)
    if #edges < 2 then return false end

    local has_out = false  -- out or gap_before (left side of boundary)
    local has_in = false   -- in or gap_after (right side of boundary)
    local all_roll = true

    for _, edge in ipairs(edges) do
        if edge.trim_type ~= "roll" then
            all_roll = false
        end
        if edge.edge_type == "out" or edge.edge_type == "gap_before" then
            has_out = true
        elseif edge.edge_type == "in" or edge.edge_type == "gap_after" then
            has_in = true
        end
    end

    return all_roll and has_out and has_in
end

--- Expand edges to include linked clips using the same click gesture.
--- For each edge, finds linked clips and "replays" the same boundary selection on their tracks.
--- This ensures rolls are complete on all linked tracks (both edges at the boundary).
---
--- @param edges table Array of {clip_id, edge_type, trim_type}
--- @param db userdata Database connection
--- @return table Expanded array of edges
local function expand_to_linked_edges(edges, db)
    local expanded = {}
    local seen = {}

    -- Determine click type from input edges
    -- Roll requires a proper boundary pair (out+in edges), not just trim_type="roll"
    local click_type = is_roll_selection(edges) and "roll" or "single"

    local function add_edge(edge_entry)
        local key = edge_entry.clip_id .. ":" .. edge_entry.edge_type
        if seen[key] then return end
        seen[key] = true
        table.insert(expanded, edge_entry)
    end

    local function add_edges_from_result(result, trim_type)
        for _, edge in ipairs(result.edges or {}) do
            add_edge({
                clip_id = edge.clip_id,
                edge_type = edge.edge_type,
                trim_type = trim_type,
                track_id = edge.track_id
            })
        end
    end

    -- Track which clips we've already expanded (avoid redundant work)
    local expanded_clips = {}

    for _, edge in ipairs(edges) do
        -- Add the original edge
        add_edge({
            clip_id = edge.clip_id,
            edge_type = edge.edge_type,
            trim_type = edge.trim_type,
            track_id = edge.track_id
        })

        -- Determine which side of the clip this edge represents
        local side = edge_to_side(edge.edge_type)
        if not side then
            goto continue_edge
        end

        -- Get the clip to find its linked clips
        local clip = timeline_state.get_clip_by_id(edge.clip_id)
        if not clip then
            goto continue_edge
        end

        -- Avoid expanding the same clip+side twice
        local expand_key = edge.clip_id .. ":" .. side
        if expanded_clips[expand_key] then
            goto continue_edge
        end
        expanded_clips[expand_key] = true

        -- Get all linked clips
        local link_group = clip_links.get_link_group(edge.clip_id, db)
        if not link_group then
            goto continue_edge
        end

        -- For each linked clip, "replay" the same boundary selection on its track
        for _, link_info in ipairs(link_group) do
            if link_info.enabled and link_info.clip_id ~= edge.clip_id then
                local linked_clip = timeline_state.get_clip_by_id(link_info.clip_id)
                if linked_clip and linked_clip.track_id then
                    -- Get all clips on the linked clip's track
                    local track_clips = timeline_state.get_clips_for_track(linked_clip.track_id)
                    if track_clips and #track_clips > 0 then
                        -- Use the core boundary selection function
                        local result = edge_picker.select_boundary_edges(
                            track_clips,
                            linked_clip,
                            side,
                            click_type
                        )
                        -- Add all edges from the result, preserving trim_type from original edge
                        add_edges_from_result(result, edge.trim_type)
                    end
                end
            end
        end

        ::continue_edge::
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
