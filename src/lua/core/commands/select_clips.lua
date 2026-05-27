--- SelectClips Command - Handle timeline clip selection with modifier semantics
--
-- Encapsulates all clip selection logic:
-- - Shift modifier: range select — all clips between anchor and target (Resolve-style)
-- - Option modifier: expand target clips to include linked clips
-- - Command modifier: toggle (add if not selected, remove if selected)
-- - No modifier on unselected: replace selection
-- - No modifier on selected: no change (allows drag)
--
-- @file select_clips.lua
local M = {}

local clip_links = require("models.clip_link")
local timeline_state = require("ui.timeline.timeline_state")

-- Selection anchor: position + track of the last individually clicked clip.
-- Shift+Click forms a box from anchor to target (time × track range).
local selection_anchor = nil  -- {sequence_start, sequence_end, track_index, track_type}

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

        -- Resolve the target clip (for anchor tracking and Shift range)
        local target_clip = target_ids[1] and timeline_state.get_tab_strip():clip_by_id(target_ids[1])

        -- Shift modifier: range select (box from anchor to target)
        if modifiers.shift and selection_anchor and target_clip then
            local target_track = timeline_state.get_track_by_id
                and timeline_state.get_track_by_id(target_clip.track_id)
            if target_track then
                local target_index = target_track.track_index
                    or (timeline_state.get_track_index and timeline_state.get_track_index(target_clip.track_id))
                local target_start = target_clip.sequence_start
                local target_end = target_start + target_clip.duration

                -- Box bounds: time range and track index range
                local time_min = math.min(selection_anchor.sequence_start, target_start)
                local time_max = math.max(selection_anchor.sequence_end, target_end)
                local idx_min = math.min(selection_anchor.track_index, target_index)
                local idx_max = math.max(selection_anchor.track_index, target_index)
                local anchor_type = selection_anchor.track_type

                -- Find all clips in the box
                local all_clips = timeline_state.get_tab_strip():displayed_clips()
                local new_selection = {}
                for _, clip in ipairs(all_clips) do
                    local clip_end = clip.sequence_start + clip.duration
                    -- Time overlap: clip intersects [time_min, time_max)
                    if clip.sequence_start < time_max and clip_end > time_min then
                        local track = timeline_state.get_track_by_id
                            and timeline_state.get_track_by_id(clip.track_id)
                        if track then
                            -- Only same track type as anchor (video or audio)
                            if track.track_type == anchor_type then
                                local ti = track.track_index
                                    or (timeline_state.get_track_index
                                        and timeline_state.get_track_index(clip.track_id))
                                if ti and ti >= idx_min and ti <= idx_max then
                                    table.insert(new_selection, clip)
                                end
                            end
                        end
                    end
                end

                timeline_state.clear_edge_selection()
                timeline_state.set_selection(new_selection)
                return { success = true, selected_count = #new_selection }
            end
        end

        -- Get current selection from timeline state
        local current_clips = timeline_state.get_selected_clips()
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
                        local clip = timeline_state.get_tab_strip():clip_by_id(id)
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
                    local clip = timeline_state.get_tab_strip():clip_by_id(id)
                    if clip then
                        table.insert(new_selection, clip)
                    end
                end
            end
        end

        -- Update anchor on non-Shift clicks (requires position data for range select)
        if not modifiers.shift and target_clip
            and type(target_clip.sequence_start) == "number"
            and type(target_clip.duration) == "number" then
            local track = timeline_state.get_track_by_id
                and timeline_state.get_track_by_id(target_clip.track_id)
            if track then
                selection_anchor = {
                    sequence_start = target_clip.sequence_start,
                    sequence_end = target_clip.sequence_start + target_clip.duration,
                    track_index = track.track_index
                        or (timeline_state.get_track_index
                            and timeline_state.get_track_index(target_clip.track_id)),
                    track_type = track.track_type,
                }
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
