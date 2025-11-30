local M = {}
local Clip = require('models.clip')
local command_helper = require("core.command_helper")
local clip_links = require('core.clip_links')
local clip_mutator = require("core.clip_mutator")
local timeline_state = require('ui.timeline.timeline_state')
local frame_utils = require('core.frame_utils')

function M.register(command_executors, command_undoers, db, set_last_error)
    local Rational = require("core.rational") -- Ensure Rational is available
    local TIMELINE_CLIP_KIND = "timeline"

    local function record_occlusion_actions(command, sequence_id, actions)
        if not actions or #actions == 0 then
            return
        end
        for _, action in ipairs(actions) do
            if action.type == "delete" and action.clip and action.clip.id then
                command_helper.add_delete_mutation(command, sequence_id, action.clip.id)
            elseif action.type == "trim" and action.after then
                local update = command_helper.clip_update_payload(action.after, sequence_id)
                if update then
                    command_helper.add_update_mutation(command, update.track_sequence_id or sequence_id, update)
                end
            elseif action.type == "insert" and action.clip then
                local insert_payload = command_helper.clip_insert_payload(action.clip, sequence_id)
                if insert_payload then
                    command_helper.add_insert_mutation(command, insert_payload.track_sequence_id or sequence_id, insert_payload)
                end
            end
        end
    end

    command_executors["Nudge"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing Nudge command")
        end

        local nudge_amount_rat = command:get_parameter("nudge_amount_rat")
        local selected_clip_ids = command:get_parameter("selected_clip_ids")
        local selected_edges = command:get_parameter("selected_edges")
        
        -- Strict Rational validation
        if type(nudge_amount_rat) == "number" then
            error("Nudge: nudge_amount_rat must be a Rational object, not a number.")
        end
        if type(nudge_amount_rat) == "table" and nudge_amount_rat.frames and not getmetatable(nudge_amount_rat) then
            nudge_amount_rat = Rational.new(nudge_amount_rat.frames, nudge_amount_rat.fps_numerator, nudge_amount_rat.fps_denominator)
        end
        if not nudge_amount_rat or not nudge_amount_rat.frames then
            error("Nudge: Invalid nudge_amount_rat (missing frames)")
        end

        local nudge_type = "none"
        local updates_by_clip = {}
        local mutated_clip_ids = {}
        
        local active_sequence_id = command:get_parameter("sequence_id")
        if (not active_sequence_id or active_sequence_id == "") and timeline_state and timeline_state.get_sequence_id then
            active_sequence_id = timeline_state.get_sequence_id()
            if active_sequence_id and active_sequence_id ~= "" then
                command:set_parameter("sequence_id", active_sequence_id)
            end
        end

        local function register_update(clip)
            if not clip or not clip.id then
                return
            end
            mutated_clip_ids[clip.id] = true
            updates_by_clip[clip.id] = {
                clip_id = clip.id,
                track_id = clip.track_id,
                track_sequence_id = clip.owner_sequence_id or clip.track_sequence_id,
                timeline_start = clip.timeline_start,
                duration = clip.duration,
                source_in = clip.source_in,
                source_out = clip.source_out
            }
        end

        local function apply_updates_if_needed(default_sequence_id)
            if next(updates_by_clip) == nil then
                return false
            end

            local updates = {}
            local sequence_id = default_sequence_id
            for _, update in pairs(updates_by_clip) do
                table.insert(updates, update)
                sequence_id = sequence_id or update.track_sequence_id
            end

            command_helper.add_update_mutation(command, sequence_id, updates)
            return true
        end

        local function capture_updates_via_reload(default_sequence_id)
            if next(mutated_clip_ids) == nil then
                return false
            end
            local fallback_updates = {}
            local sequence_id = default_sequence_id
            local mutated_count = 0
            for clip_id in pairs(mutated_clip_ids) do
                mutated_count = mutated_count + 1
                local clip = Clip.load_optional(clip_id, db)
                if clip then
                    local update_payload = command_helper.clip_update_payload(clip, sequence_id)
                    if update_payload then
                        sequence_id = sequence_id or update_payload.track_sequence_id
                        table.insert(fallback_updates, update_payload)
                    end
                end
            end
            if mutated_count == 0 then
                return false
            end
            if #fallback_updates == 0 then
                return false
            end
            sequence_id = sequence_id or fallback_updates[1].track_sequence_id
            if not sequence_id then
                return false
            end
            command_helper.add_update_mutation(command, sequence_id, fallback_updates)
            return true
        end

        local function capture_updates_from_selection(default_sequence_id)
            local collected_ids = {}
            if type(selected_clip_ids) == "table" then
                for _, clip_id in ipairs(selected_clip_ids) do
                    if clip_id then
                        collected_ids[clip_id] = true
                    end
                end
            end
            if type(selected_edges) == "table" then
                for _, edge_info in ipairs(selected_edges) do
                    if edge_info and edge_info.clip_id then
                        collected_ids[edge_info.clip_id] = true
                    end
                end
            end
            if next(collected_ids) == nil then
                return false
            end
            local updates = {}
            local sequence_id = default_sequence_id
            for clip_id in pairs(collected_ids) do
                local clip = Clip.load_optional(clip_id, db)
                if clip then
                    local update_payload = command_helper.clip_update_payload(clip, sequence_id)
                    if update_payload then
                        sequence_id = sequence_id or update_payload.track_sequence_id
                        table.insert(updates, update_payload)
                    end
                end
            end
            if #updates == 0 then
                return false
            end
            sequence_id = sequence_id or updates[1].track_sequence_id
            if not sequence_id then
                return false
            end
            command_helper.add_update_mutation(command, sequence_id, updates)
            return true
        end

        if selected_edges and #selected_edges > 0 then
            nudge_type = "edges"
            local preview_clips = {}

            for _, edge_info in ipairs(selected_edges) do
                local clip = Clip.load(edge_info.clip_id, db)

                if not clip then
                    print(string.format("WARNING: Nudge: Clip %s not found", edge_info.clip_id:sub(1,8)))
                    goto continue
                end
                
                -- Ensure the clip's rate is valid for Rational calculations
                local clip_rate_num = clip.rate.fps_numerator
                local clip_rate_den = clip.rate.fps_denominator
                if not clip_rate_num or clip_rate_num <= 0 then
                    print(string.format("ERROR: Nudge: Clip %s has invalid rate for Rational math", clip.id:sub(1,8)))
                    return false
                end

                if edge_info.edge_type == "in" or edge_info.edge_type == "gap_before" then
                    -- Nudge 'in' edge means moving it right (shortening) or left (lengthening)
                    local new_timeline_start = clip.timeline_start + nudge_amount_rat
                    local new_duration = clip.duration - nudge_amount_rat
                    local new_source_in = clip.source_in + nudge_amount_rat

                    -- Clamp duration to minimum 1 frame
                    if new_duration.frames < 1 then new_duration = Rational.new(1, clip_rate_num, clip_rate_den) end
                    
                    clip.timeline_start = new_timeline_start
                    clip.duration = new_duration
                    clip.source_in = new_source_in

                elseif edge_info.edge_type == "out" or edge_info.edge_type == "gap_after" then
                    -- Nudge 'out' edge means moving it right (lengthening) or left (shortening)
                    local new_duration = clip.duration + nudge_amount_rat
                    
                    -- Clamp duration to minimum 1 frame
                    if new_duration.frames < 1 then new_duration = Rational.new(1, clip_rate_num, clip_rate_den) end

                    clip.duration = new_duration
                    clip.source_out = clip.source_in + new_duration
                end
                
                -- Clamp timeline_start to 0 or greater (Rational(0))
                if clip.timeline_start.frames < 0 then
                    clip.timeline_start = Rational.new(0, clip_rate_num, clip_rate_den)
                end

                if dry_run then
                    table.insert(preview_clips, {
                        clip_id = clip.id,
                        new_start_value = clip.timeline_start,
                        new_duration = clip.duration,
                        edge_type = edge_info.edge_type
                    })
                else
                    mutated_clip_ids[clip.id] = true
                    if not clip:save(db) then
                        print(string.format("ERROR: Nudge: Failed to save clip %s", edge_info.clip_id:sub(1,8)))
                        return false
                    end
                    register_update(clip)
                end

                ::continue::
            end

            if dry_run then
                return true, {
                    nudge_type = "edges",
                    affected_clips = preview_clips
                }
            end

            print(string.format("✅ Nudged %d edge(s) by %s", #selected_edges, tostring(nudge_amount_rat)))
        elseif selected_clip_ids and #selected_clip_ids > 0 then
            nudge_type = "clips"
            local clips_to_move = {}
            local processed_groups = {}

            for _, clip_id in ipairs(selected_clip_ids) do
                clips_to_move[clip_id] = true
                local link_group = clip_links.get_link_group(clip_id, db)
                if link_group then
                    local link_group_id = clip_links.get_link_group_id(clip_id, db)
                    if link_group_id and not processed_groups[link_group_id] then
                        processed_groups[link_group_id] = true
                        for _, link_info in ipairs(link_group) do
                            if link_info.enabled then
                                clips_to_move[link_info.clip_id] = true
                            end
                        end
                    end
                end
            end

            local move_targets = {}
            local neighbor_clip_ids = {}
            local track_groups = {}
            local any_change = false
            local preview_clips = {}

            for clip_id, _ in pairs(clips_to_move) do
                local clip = Clip.load(clip_id, db)
                if not clip then
                    print(string.format("WARNING: Nudge: Clip %s not found", clip_id:sub(1,8)))
                    clips_to_move[clip_id] = nil
                    goto continue_collect_block
                end

                if clip.clip_kind and clip.clip_kind ~= TIMELINE_CLIP_KIND then
                    clips_to_move[clip_id] = nil
                    goto continue_collect_block
                end
                
                -- Nudge clip
                local new_start = clip.timeline_start + nudge_amount_rat
                
                -- Clamp to 0
                if new_start.frames < 0 then
                    new_start = Rational.new(0, new_start.fps_numerator, new_start.fps_denominator)
                end

                if not (new_start == clip.timeline_start) then
                    any_change = true
                end
                clip.__new_start = new_start -- Store Rational
                mutated_clip_ids[clip.id] = true
                neighbor_clip_ids[#neighbor_clip_ids + 1] = clip.id
                table.insert(move_targets, clip)
                table.insert(preview_clips, {
                    clip_id = clip.id,
                    new_start_value = new_start,
                    new_duration = clip.duration
                })

                local track_id = clip.track_id or clip.owner_sequence_id -- Assuming owner_sequence_id for track fallback
                if not track_id then
                    print(string.format("WARNING: Nudge: Clip %s missing track_id", clip.id or "unknown"))
                    goto continue_collect_block
                end
                local group = track_groups[track_id]
                if not group then
                    group = {
                        clips = {},
                        pending = {},
                        before_min = nil,
                        before_max = nil,
                        after_min = nil,
                        after_max = nil,
                        sequence_id = clip.owner_sequence_id or clip.track_sequence_id or active_sequence_id
                    }
                    track_groups[track_id] = group
                end

                local clip_end = clip.timeline_start + clip.duration
                local new_end = new_start + clip.duration

                -- Use Rational comparisons
                if not group.before_min or clip.timeline_start < group.before_min then group.before_min = clip.timeline_start end
                if not group.before_max or clip_end > group.before_max then group.before_max = clip_end end

                if not group.after_min or new_start < group.after_min then group.after_min = new_start end
                if not group.after_max or new_end > group.after_max then group.after_max = new_end end

                group.pending[clip.id] = {
                    timeline_start = new_start,
                    duration = clip.duration
                }

                table.insert(group.clips, clip)

                ::continue_collect_block::
            end

            if dry_run then
                return true, {
                    nudge_type = "clips",
                    affected_clips = preview_clips
                }
            end

            if any_change then
                -- This part heavily uses clip_mutator and timeline_state.
                -- These modules need to be Rational-aware.
                -- For now, pass Rational and assume they will handle.
                local neighbor_windows = nil
                if timeline_state and timeline_state.describe_track_neighbors and #neighbor_clip_ids > 0 then
                    -- Expects Rational in V5
                    neighbor_windows = timeline_state.describe_track_neighbors(active_sequence_id, neighbor_clip_ids)
                end

                for track_id, group in pairs(track_groups) do
                    if group.after_max and group.after_min then
                        local block_duration = group.after_max - group.after_min
                        if group.before_max and group.before_min then
                            block_duration = Rational.max(block_duration, group.before_max - group.before_min)
                        end
                        
                        -- Passing Rational directly to clip_mutator.resolve_occlusions
                        local ok, err, actions = clip_mutator.resolve_occlusions(db, {
                            track_id = track_id,
                            timeline_start = group.after_min,
                            duration = block_duration,
                            pending_clips = group.pending -- These are now Rational
                        })
                        if not ok then
                            print(string.format("ERROR: Nudge: Failed to resolve occlusions on track %s: %s", tostring(track_id), tostring(err)))
                            return false
                        end
                        record_occlusion_actions(command, group.sequence_id, actions)
                    end
                end

                for _, clip in ipairs(move_targets) do
                    clip.timeline_start = clip.__new_start or clip.timeline_start
                    if not clip:save(db, {skip_occlusion = true}) then
                        print(string.format("ERROR: Nudge: Failed to save clip %s", clip.id:sub(1,8)))
                        return false
                    end
                    register_update(clip)
                end
            end

            local total_moved = 0
            for _ in pairs(clips_to_move) do
                total_moved = total_moved + 1
            end

            local linked_count = total_moved - #selected_clip_ids
            if linked_count > 0 then
                print(string.format("✅ Nudged %d clip(s) + %d linked clip(s) by %s",
                    #selected_clip_ids, linked_count, tostring(nudge_amount_rat)))
            else
                print(string.format("✅ Nudged %d clip(s) by %s", #selected_clip_ids, tostring(nudge_amount_rat)))
            end
        else
            print("WARNING: Nudge: Nothing selected")
            return false
        end

        command:set_parameter("nudge_type", nudge_type)

        local captured_mutations = apply_updates_if_needed(active_sequence_id)
        if not captured_mutations then
            local recovered = capture_updates_via_reload(active_sequence_id)
            if not recovered then
                recovered = capture_updates_from_selection(active_sequence_id)
            end
            if not recovered then
                print(string.format(
                    "WARNING: Nudge: Failed to capture timeline mutations for timeline cache (sequence=%s)",
                    tostring(active_sequence_id or "nil")))
            end
        end

        return true
    end

    command_undoers["UndoNudge"] = function(command)
        print("Executing UndoNudge command")

        local nudge_amount_rat = command:get_parameter("nudge_amount_rat")
        
        -- Hydrate Rational if needed (from JSON)
        if type(nudge_amount_rat) == "table" and nudge_amount_rat.frames and (not getmetatable(nudge_amount_rat) or not getmetatable(nudge_amount_rat).__lt) then
             nudge_amount_rat = Rational.new(nudge_amount_rat.frames, nudge_amount_rat.fps_numerator, nudge_amount_rat.fps_denominator)
        end
        
        -- Apply negative nudge amount for undo
        command:set_parameter("nudge_amount_rat", -nudge_amount_rat)

        local result = command_executors["Nudge"](command)

        -- Restore original nudge amount for re-undoing
        command:set_parameter("nudge_amount_rat", nudge_amount_rat) -- Restore original for consistent undo/redo stack

        return result
    end

    command_executors["UndoNudge"] = command_undoers["UndoNudge"]

    return {
        executor = command_executors["Nudge"],
        undoer = command_undoers["UndoNudge"]
    }
end

return M
