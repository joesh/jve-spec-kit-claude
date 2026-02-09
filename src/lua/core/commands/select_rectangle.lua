--- SelectRectangle Command - Select clips within a time/track range
--
-- Takes a time range and list of track IDs, finds intersecting clips,
-- applies selection with modifier semantics:
-- - Command modifier: toggle (add unselected, remove selected)
-- - No modifier: replace selection
--
-- @file select_rectangle.lua
local M = {}

local timeline_state = require("ui.timeline.timeline_state")

local SPEC = {
    undoable = false,
    args = {
        project_id = { required = true },
        sequence_id = { required = true },
        time_start = { required = true, kind = "number" },
        time_end = { required = true, kind = "number" },
        track_ids = { required = true, kind = "table" },
        modifiers = { required = false, kind = "table" },
    },
}

--- Find all clips that overlap the given time range in the specified tracks
local function find_clips_in_range(time_start, time_end, track_ids)
    local track_set = {}
    for _, tid in ipairs(track_ids) do
        track_set[tid] = true
    end

    local matching = {}
    for _, clip in ipairs(timeline_state.get_clips() or {}) do
        if track_set[clip.track_id] then
            local clip_end = clip.timeline_start + clip.duration
            -- Check time overlap: NOT (clip ends before range OR clip starts after range)
            local overlaps = not (clip_end <= time_start or clip.timeline_start >= time_end)
            if overlaps then
                table.insert(matching, clip)
            end
        end
    end

    return matching
end

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["SelectRectangle"] = function(command)
        local args = command:get_all_parameters()
        local modifiers = args.modifiers or {}
        local time_start = args.time_start
        local time_end = args.time_end
        local track_ids = args.track_ids

        -- Find clips in the rectangle
        local rect_clips = find_clips_in_range(time_start, time_end, track_ids)

        -- Build set of rect clip IDs
        local rect_set = {}
        for _, clip in ipairs(rect_clips) do
            rect_set[clip.id] = clip
        end

        -- Get current selection
        local current_clips = timeline_state.get_selected_clips() or {}

        local new_selection = {}

        if modifiers.command then
            -- Toggle: for each rect clip, add if not selected, remove if selected
            local current_set = {}
            for _, clip in ipairs(current_clips) do
                current_set[clip.id] = clip
            end

            -- Start with current selection, excluding rect clips that are selected
            for _, clip in ipairs(current_clips) do
                if not rect_set[clip.id] then
                    -- Not in rect, keep it
                    table.insert(new_selection, clip)
                end
                -- If in rect AND selected, don't add (toggle off)
            end

            -- Add rect clips that weren't in current selection
            for _, clip in ipairs(rect_clips) do
                if not current_set[clip.id] then
                    table.insert(new_selection, clip)
                end
            end
        else
            -- Replace: selection = rect clips
            new_selection = rect_clips
        end

        -- Apply selection (clears edges and gaps)
        timeline_state.set_selection(new_selection)

        return {
            success = true,
            selected_count = #new_selection,
            rect_clip_count = #rect_clips,
        }
    end

    return {
        ["SelectRectangle"] = {
            executor = command_executors["SelectRectangle"],
            spec = SPEC,
        },
    }
end

return M
