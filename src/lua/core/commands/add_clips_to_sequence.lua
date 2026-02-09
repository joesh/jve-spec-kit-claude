--- AddClipsToSequence command - THE algorithm for placing clips on timeline
--
-- Responsibilities:
-- - Insert or overwrite clips at a position in a sequence
-- - Handle serial (back-to-back) or stacked (same position, different tracks) arrangement
-- - Cross-track carving: insert ripples ALL tracks, overwrite occludes target tracks only
-- - Link clips within each group
-- - Single undo/redo for entire operation
--
-- Non-goals:
-- - Does not gather UI context (caller uses gather_context_for_command.lua)
-- - Does not resolve track indices (caller provides target_track_id per clip)
--
-- Invariants:
-- - All clips in a group must have valid target_track_id
-- - Position must be an integer frame
-- - Edit type must be "insert" or "overwrite"
-- - Arrangement must be "serial" or "stacked"
--
-- @file add_clips_to_sequence.lua

local M = {}

local Clip = require('models.clip')
local uuid = require('uuid')
local command_helper = require('core.command_helper')
local clip_mutator = require('core.clip_mutator')
local clip_link = require('models.clip_link')
local logger = require('core.logger')

--- Populate __timeline_mutations from clip_mutator mutations for UI cache updates
-- @param command The command to set mutations on
-- @param sequence_id The sequence being modified
-- @param mutations Array of {type, clip_id, ...} from clip_mutator
local function populate_timeline_mutations(command, sequence_id, mutations)
    if not mutations or #mutations == 0 then
        return
    end

    for _, mut in ipairs(mutations) do
        if mut.type == "insert" then
            command_helper.add_insert_mutation(command, sequence_id, {
                id = mut.clip_id,
                track_id = mut.track_id,
                start_value = mut.timeline_start_frame,
                duration_value = mut.duration_frames,
                source_in_value = mut.source_in_frame,
                source_out_value = mut.source_out_frame,
                name = mut.name,
                media_id = mut.media_id,
                enabled = mut.enabled ~= false,
                clip_kind = mut.clip_kind,
                fps_numerator = mut.fps_numerator,
                fps_denominator = mut.fps_denominator,
            })
        elseif mut.type == "update" then
            command_helper.add_update_mutation(command, sequence_id, {
                clip_id = mut.clip_id,
                track_id = mut.track_id,
                start_value = mut.timeline_start_frame,
                duration_value = mut.duration_frames,
                source_in_value = mut.source_in_frame,
                source_out_value = mut.source_out_frame,
            })
        elseif mut.type == "delete" then
            command_helper.add_delete_mutation(command, sequence_id, mut.clip_id)
        end
    end
end

local SPEC = {
    args = {
        advance_playhead = { kind = "boolean" },  -- Advance playhead to end of clips
        arrangement = {},           -- "serial" or "stacked"
        edit_type = { required = true }, -- "insert" or "overwrite"
        groups = { required = true },     -- array of {clips = [...], duration = integer}
        position = { required = true },   -- Integer timeline frame
        project_id = { required = true },
        sequence_id = { required = true },
    },
    persisted = {
        executed_mutations = {},
        created_clip_ids = {},
        created_link_group_ids = {},
    },
}

--- Phase 1: Compute space requirements (all coordinates are integers)
-- @param groups array of clip groups
-- @param arrangement "serial" or "stacked"
-- @param position integer frame position
-- @return total_duration integer, track_map table mapping track_id -> list of {start, ["end"], clip_desc}
local function compute_space_needs(groups, arrangement, position)
    local total_duration = 0
    local track_map = {}  -- track_id -> list of intervals

    if arrangement == "serial" then
        -- Groups placed back-to-back
        local current_frame = position
        for _, group in ipairs(groups) do
            local group_frames = group.duration
            assert(type(group_frames) == "number" and group_frames > 0, "AddClipsToSequence: group.duration must be positive integer")

            local start_pos = current_frame
            local end_pos = current_frame + group_frames

            for _, clip_desc in ipairs(group.clips) do
                local track_id = assert(clip_desc.target_track_id, "AddClipsToSequence: clip missing target_track_id")
                track_map[track_id] = track_map[track_id] or {}
                table.insert(track_map[track_id], {
                    start = start_pos,
                    ["end"] = end_pos,
                    clip_desc = clip_desc,
                    group = group,
                })
            end

            current_frame = current_frame + group_frames
            total_duration = current_frame - position
        end
    else
        -- Stacked: all groups at same position, different tracks
        local max_frames = 0
        for _, group in ipairs(groups) do
            local group_frames = group.duration
            assert(type(group_frames) == "number" and group_frames > 0, "AddClipsToSequence: group.duration must be positive integer")

            if group_frames > max_frames then
                max_frames = group_frames
            end

            local end_pos = position + group_frames
            for _, clip_desc in ipairs(group.clips) do
                local track_id = assert(clip_desc.target_track_id, "AddClipsToSequence: clip missing target_track_id")
                track_map[track_id] = track_map[track_id] or {}
                table.insert(track_map[track_id], {
                    start = position,
                    ["end"] = end_pos,
                    clip_desc = clip_desc,
                    group = group,
                })
            end
        end
        total_duration = max_frames
    end

    return total_duration, track_map
end

--- Phase 2: Carve space for clips
-- @param db database connection
-- @param edit_type "insert" or "overwrite"
-- @param sequence_id string
-- @param position integer frame
-- @param total_duration integer frames
-- @param track_map table from compute_space_needs
-- @return mutations array, error string|nil
local function carve_space(db, edit_type, sequence_id, position, total_duration, track_map)
    local all_mutations = {}

    if edit_type == "insert" then
        -- Insert: ripple ALL tracks in sequence at position
        local Track = require('models.track')
        local all_tracks = Track.find_by_sequence(sequence_id)

        for _, track in ipairs(all_tracks) do
            local ok, err, mutations = clip_mutator.resolve_ripple(db, {
                track_id = track.id,
                insert_time = position,
                shift_amount = total_duration,
            })
            if not ok then
                return nil, string.format("AddClipsToSequence: ripple failed on track %s: %s", tostring(track.id), tostring(err))
            end
            for _, mut in ipairs(mutations or {}) do
                table.insert(all_mutations, mut)
            end
        end
    else
        -- Overwrite: occlude target tracks only in [position, position+total_duration]
        for track_id, intervals in pairs(track_map) do
            -- Merge intervals on this track to get total span
            local min_start = intervals[1].start
            local max_end = intervals[1]["end"]
            for i = 2, #intervals do
                if intervals[i].start < min_start then
                    min_start = intervals[i].start
                end
                if intervals[i]["end"] > max_end then
                    max_end = intervals[i]["end"]
                end
            end

            local span_duration = max_end - min_start
            if span_duration > 0 then
                local ok, err, mutations = clip_mutator.resolve_occlusions(db, {
                    track_id = track_id,
                    timeline_start = min_start,
                    duration = span_duration,
                })
                if not ok then
                    return nil, string.format("AddClipsToSequence: occlusion failed on track %s: %s", tostring(track_id), tostring(err))
                end
                for _, mut in ipairs(mutations or {}) do
                    table.insert(all_mutations, mut)
                end
            end
        end
    end

    return all_mutations, nil
end

--- Phase 3: Create and place clips
-- @param db database connection
-- @param track_map table from compute_space_needs
-- @param project_id string
-- @param sequence_id string
-- @param redo_clip_ids array of clip IDs from previous execution (for redo)
-- @return created_clips array of {clip_id, group_index}, mutations array, error string|nil
local function place_clips(db, track_map, project_id, sequence_id, redo_clip_ids)
    local created_clips = {}
    local mutations = {}
    local redo_idx = 1

    -- Flatten track_map to list for deterministic ordering
    local all_placements = {}
    for track_id, intervals in pairs(track_map) do
        for _, interval in ipairs(intervals) do
            table.insert(all_placements, {
                track_id = track_id,
                interval = interval,
            })
        end
    end

    -- Sort by track_id then start time for deterministic order
    table.sort(all_placements, function(a, b)
        if a.track_id ~= b.track_id then
            return a.track_id < b.track_id
        end
        return a.interval.start < b.interval.start
    end)

    for _, placement in ipairs(all_placements) do
        local interval = placement.interval
        local clip_desc = interval.clip_desc

        -- Determine clip_id: prefer explicit from clip_desc, then redo, then generate
        local clip_id
        if clip_desc.clip_id and clip_desc.clip_id ~= "" then
            clip_id = clip_desc.clip_id
            if redo_clip_ids and redo_idx <= #redo_clip_ids then
                redo_idx = redo_idx + 1
            end
        elseif redo_clip_ids and redo_idx <= #redo_clip_ids then
            clip_id = redo_clip_ids[redo_idx]
            redo_idx = redo_idx + 1
        else
            clip_id = uuid.generate()
        end

        -- Create clip (all coordinates must be integers)
        assert(type(clip_desc.duration) == "number", "AddClipsToSequence: clip_desc.duration must be integer")
        assert(type(clip_desc.source_in) == "number", "AddClipsToSequence: clip_desc.source_in must be integer")
        assert(type(clip_desc.source_out) == "number", "AddClipsToSequence: clip_desc.source_out must be integer")

        local clip = Clip.create(clip_desc.name or "Timeline Clip", clip_desc.media_id, {
            id = clip_id,
            project_id = project_id,
            track_id = placement.track_id,
            owner_sequence_id = sequence_id,
            parent_clip_id = clip_desc.master_clip_id,
            timeline_start = interval.start,
            duration = clip_desc.duration,
            source_in = clip_desc.source_in,
            source_out = clip_desc.source_out,
            enabled = true,
            fps_numerator = clip_desc.fps_numerator,
            fps_denominator = clip_desc.fps_denominator,
        })

        table.insert(mutations, clip_mutator.plan_insert(clip))
        table.insert(created_clips, {
            clip_id = clip_id,
            clip = clip,
            group = interval.group,
            role = clip_desc.role,
            master_clip_id = clip_desc.master_clip_id,
        })
    end

    return created_clips, mutations, nil
end

--- Phase 4: Link clips within each group
-- @param db database connection
-- @param created_clips array from place_clips
-- @param groups original groups array
-- @return link_group_ids array
local function link_groups(db, created_clips, groups)
    local link_group_ids = {}

    -- Group clips by their source group
    local clips_by_group = {}
    for _, created in ipairs(created_clips) do
        local group = created.group
        clips_by_group[group] = clips_by_group[group] or {}
        table.insert(clips_by_group[group], {
            clip_id = created.clip_id,
            role = created.role,
            time_offset = 0,
        })
    end

    -- Create link groups for groups with 2+ clips
    for _, group_clips in pairs(clips_by_group) do
        if #group_clips >= 2 then
            local link_id, err = clip_link.create_link_group(group_clips, db)
            if link_id then
                table.insert(link_group_ids, link_id)
            else
                logger.warn("add_clips_to_sequence", string.format("Failed to create link group: %s", tostring(err)))
            end
        end
    end

    return link_group_ids
end

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["AddClipsToSequence"] = function(command)
        local args = command:get_all_parameters()
        local this_func_label = "AddClipsToSequence"

        -- Validate inputs
        local groups = assert(args.groups, this_func_label .. ": groups required")
        assert(#groups > 0, this_func_label .. ": groups must not be empty")

        -- Validate all coordinate fields are integers
        for _, group in ipairs(groups) do
            assert(type(group.duration) == "number", this_func_label .. ": group.duration must be integer")
            for _, clip_desc in ipairs(group.clips or {}) do
                assert(type(clip_desc.source_in) == "number", this_func_label .. ": clip_desc.source_in must be integer")
                assert(type(clip_desc.source_out) == "number", this_func_label .. ": clip_desc.source_out must be integer")
                assert(type(clip_desc.duration) == "number", this_func_label .. ": clip_desc.duration must be integer")
            end
        end

        local position = args.position
        assert(type(position) == "number", this_func_label .. ": position must be integer frames")

        local sequence_id = assert(args.sequence_id, this_func_label .. ": sequence_id required")
        local project_id = assert(args.project_id or command.project_id, this_func_label .. ": project_id required")
        local edit_type = assert(args.edit_type, this_func_label .. ": edit_type required")
        assert(edit_type == "insert" or edit_type == "overwrite", this_func_label .. ": edit_type must be insert or overwrite")

        local arrangement = args.arrangement or "serial"
        assert(arrangement == "serial" or arrangement == "stacked", this_func_label .. ": arrangement must be serial or stacked")

        command:set_parameter("project_id", project_id)
        command.project_id = project_id

        -- Reuse clip IDs from previous execution (for redo)
        local redo_clip_ids = args.created_clip_ids

        -- Phase 1: Compute space needs
        local total_duration, track_map = compute_space_needs(groups, arrangement, position)

        -- Phase 2: Carve space
        local carve_mutations, carve_err = carve_space(db, edit_type, sequence_id, position, total_duration, track_map)
        if not carve_mutations then
            set_last_error(carve_err)
            return false, carve_err
        end

        -- Phase 3: Place clips
        local created_clips, place_mutations, place_err = place_clips(db, track_map, project_id, sequence_id, redo_clip_ids)
        if place_err then
            set_last_error(place_err)
            return false, place_err
        end

        -- Combine all mutations
        local all_mutations = {}
        for _, mut in ipairs(carve_mutations) do
            table.insert(all_mutations, mut)
        end
        for _, mut in ipairs(place_mutations) do
            table.insert(all_mutations, mut)
        end

        -- Apply all mutations
        local ok_apply, apply_err = command_helper.apply_mutations(db, all_mutations)
        if not ok_apply then
            local msg = this_func_label .. ": failed to apply mutations: " .. tostring(apply_err)
            set_last_error(msg)
            return false, msg
        end

        -- Populate __timeline_mutations for UI cache updates
        populate_timeline_mutations(command, sequence_id, all_mutations)

        -- Phase 4: Link groups
        local link_group_ids = link_groups(db, created_clips, groups)

        -- Phase 5: Copy properties from master clips
        for _, created in ipairs(created_clips) do
            if created.master_clip_id and created.master_clip_id ~= "" then
                local copied_props = command_helper.ensure_copied_properties(command, created.master_clip_id)
                if #copied_props > 0 then
                    command_helper.delete_properties_for_clip(created.clip_id)
                    local props_ok = command_helper.insert_properties_for_clip(created.clip_id, copied_props)
                    if not props_ok then
                        logger.warn("add_clips_to_sequence", string.format(
                            "Failed to copy properties from master_clip_id=%s to clip_id=%s",
                            tostring(created.master_clip_id), tostring(created.clip_id)
                        ))
                    end
                end
            end
        end

        -- Store for undo
        command:set_parameter("executed_mutations", all_mutations)
        local clip_ids = {}
        for _, created in ipairs(created_clips) do
            table.insert(clip_ids, created.clip_id)
        end
        command:set_parameter("created_clip_ids", clip_ids)
        command:set_parameter("created_link_group_ids", link_group_ids)

        -- Advance playhead to end of clips if requested
        if args.advance_playhead then
            local ok_ts, timeline_state = pcall(require, 'ui.timeline.timeline_state')
            if ok_ts and timeline_state and timeline_state.set_playhead_position then
                local new_playhead = position + total_duration
                timeline_state.set_playhead_position(new_playhead)
                command.playhead_value_post = new_playhead
            end
        end

        logger.debug("add_clips_to_sequence", string.format(
            "Added %d clips at frame %d (%s, %s)",
            #created_clips, position, edit_type, arrangement
        ))

        return true
    end

    command_undoers["AddClipsToSequence"] = function(command)
        local args = command:get_all_parameters()
        local this_func_label = "UndoAddClipsToSequence"

        local executed_mutations = args.executed_mutations or {}
        local link_group_ids = args.created_link_group_ids or {}
        local sequence_id = args.sequence_id

        if #executed_mutations == 0 and #link_group_ids == 0 then
            return true  -- Nothing to undo
        end

        -- Delete link groups first
        for _, link_id in ipairs(link_group_ids) do
            local query = db:prepare("DELETE FROM clip_links WHERE link_group_id = ?")
            if query then
                query:bind_value(1, link_id)
                query:exec()
                query:finalize()
            end
        end

        -- Revert mutations
        local ok, err = command_helper.revert_mutations(db, executed_mutations, command, sequence_id)
        assert(ok, this_func_label .. ": failed to revert mutations: " .. tostring(err))

        logger.debug("add_clips_to_sequence", "Undo: reverted all changes")
        return true
    end

    command_executors["UndoAddClipsToSequence"] = command_undoers["AddClipsToSequence"]

    return {
        executor = command_executors["AddClipsToSequence"],
        undoer = command_undoers["AddClipsToSequence"],
        spec = SPEC,
    }
end

return M
