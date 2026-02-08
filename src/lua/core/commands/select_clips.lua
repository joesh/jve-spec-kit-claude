--- SelectClips Command - Handle timeline clip selection with modifier semantics
--
-- Encapsulates all clip selection logic:
-- - Option modifier: expand target clips to include linked clips
-- - Command modifier: toggle (add if not selected, remove if selected)
-- - No modifier on unselected: replace selection
-- - No modifier on selected: no change (allows drag)
--
-- @file select_clips.lua
local M = {}

local clip_links = require("models.clip_link")
local timeline_state = require("ui.timeline.timeline_state")

local SPEC = {
    undoable = false,
    args = {
        project_id = { required = true },
        sequence_id = { required = true },
        target_clip_ids = { required = true, kind = "table" },
        modifiers = { required = false, kind = "table" },
        clear_edges = { required = false, kind = "boolean" },
    },
}

local function expand_to_linked_clips(clip_ids, db)
    local expanded = {}
    local seen = {}
    local processed_groups = {}

    for _, clip_id in ipairs(clip_ids) do
        if not seen[clip_id] then
            seen[clip_id] = true
            table.insert(expanded, clip_id)
        end

        local link_group_id = clip_links.get_link_group_id(clip_id, db)
        if link_group_id and not processed_groups[link_group_id] then
            processed_groups[link_group_id] = true
            local link_group = clip_links.get_link_group(clip_id, db)
            if link_group then
                for _, link_info in ipairs(link_group) do
                    if link_info.enabled and not seen[link_info.clip_id] then
                        seen[link_info.clip_id] = true
                        table.insert(expanded, link_info.clip_id)
                    end
                end
            end
        end
    end

    return expanded
end

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["SelectClips"] = function(command)
        local args = command:get_all_parameters()
        local modifiers = args.modifiers or {}
        local target_ids = args.target_clip_ids or {}

        -- Alt/Option modifier: expand targets to include linked clips
        if modifiers.alt then
            target_ids = expand_to_linked_clips(target_ids, db)
        end

        -- Get current selection from timeline state
        local current_clips = timeline_state.get_selected_clips() or {}
        local current_set = {}
        for _, clip in ipairs(current_clips) do
            current_set[clip.id] = clip
        end

        -- Check if all targets are already selected
        local all_selected = true
        for _, id in ipairs(target_ids) do
            if not current_set[id] then
                all_selected = false
                break
            end
        end

        -- Build target set for quick lookup
        local target_set = {}
        for _, id in ipairs(target_ids) do
            target_set[id] = true
        end

        local new_selection = {}

        if modifiers.command then
            if all_selected then
                -- Remove targets from selection
                for _, clip in ipairs(current_clips) do
                    if not target_set[clip.id] then
                        table.insert(new_selection, clip)
                    end
                end
            else
                -- Add targets to selection (keep existing + add new)
                for _, clip in ipairs(current_clips) do
                    table.insert(new_selection, clip)
                end
                -- Add target clips that aren't already selected
                for _, id in ipairs(target_ids) do
                    if not current_set[id] then
                        local clip = timeline_state.get_clip_by_id(id)
                        if clip then
                            table.insert(new_selection, clip)
                        end
                    end
                end
            end
        else
            if all_selected then
                -- Already selected, no change (allows drag initiation)
                new_selection = current_clips
            else
                -- Replace selection with targets
                for _, id in ipairs(target_ids) do
                    local clip = timeline_state.get_clip_by_id(id)
                    if clip then
                        table.insert(new_selection, clip)
                    end
                end
            end
        end

        -- Apply selection
        local should_clear_edges = args.clear_edges
        if should_clear_edges == nil then
            -- Default: clear edges when replacing selection (not cmd, not already selected)
            should_clear_edges = not modifiers.command and not all_selected
        end

        if should_clear_edges then
            timeline_state.clear_edge_selection()
        end
        timeline_state.set_selection(new_selection)

        return {
            success = true,
            selected_count = #new_selection,
            expanded_linked = modifiers.option and #target_ids > #args.target_clip_ids,
        }
    end

    return {
        ["SelectClips"] = {
            executor = command_executors["SelectClips"],
            spec = SPEC,
        },
    }
end

return M
