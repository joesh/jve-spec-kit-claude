local M = {}
local Clip = require('models.clip')
local command_helper = require("core.command_helper")
local clip_mutator = require("core.clip_mutator")
local frame_utils = require("core.frame_utils")
local timeline_state = require('ui.timeline.timeline_state')

local SPEC = {
    args = {
        dry_run = { kind = "boolean" },
        fps_denominator = { kind = "number" },
        fps_numerator = { kind = "number" },
        nudge_amount = { kind = "number", required = true },
        nudge_axis = {},
        nudge_type = {},  -- Set by executor ("clip" or "edge")
        project_id = { required = true },
        selected_clip_ids = {},
        selected_edges = {},
        sequence_id = {},
    },
    persisted = {
        executed_mutations = {},
    },

}

function M.register(command_executors, command_undoers, db, set_last_error)
    -- Note: record_occlusion_actions removed - occlusion system is disabled

    command_executors["Nudge"] = function(command)
        local args = command:get_all_parameters()

        if not args.dry_run then
            print("Executing Nudge command")
        end

        -- Nudge amount must be integer frames
        local nudge_frames = args.nudge_amount
        assert(type(nudge_frames) == "number", "Nudge: nudge_amount must be integer frames")

        local nudge_type
        local updates_by_clip = {}
        local mutated_clip_ids = {}
        
        local active_sequence_id = command_helper.resolve_active_sequence_id(args.sequence_id, timeline_state)
        if active_sequence_id and active_sequence_id ~= args.sequence_id then
            command:set_parameter("sequence_id", active_sequence_id)
        end

        local function register_update(clip)
            if not clip or not clip.id then
                return
            end
            mutated_clip_ids[clip.id] = true
            -- Use canonical *_value payload shape that clip_state.apply_mutations
            -- consumes — the raw clip-field shape was a schema mismatch that
            -- silently no-op'd in-memory cache updates while DB writes landed.
            updates_by_clip[clip.id] = command_helper.clip_update_payload(
                clip, active_sequence_id)
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
                return true  -- Nothing to capture is success (not error)
            end
            local fallback_updates = {}
            local sequence_id = default_sequence_id
            for clip_id in pairs(mutated_clip_ids) do
                local clip = Clip.load_optional(clip_id)
                -- NSF: If we mutated a clip, it should still exist
                assert(clip, string.format("Nudge.capture_updates_via_reload: mutated clip %s no longer exists", clip_id))
                local update_payload = command_helper.clip_update_payload(clip, sequence_id)
                assert(update_payload, string.format("Nudge.capture_updates_via_reload: clip_update_payload failed for clip %s", clip_id))
                sequence_id = sequence_id or update_payload.track_sequence_id
                table.insert(fallback_updates, update_payload)
            end
            assert(#fallback_updates > 0, "Nudge.capture_updates_via_reload: no updates captured but mutated_clip_ids was non-empty")
            sequence_id = sequence_id or fallback_updates[1].track_sequence_id
            assert(sequence_id, "Nudge.capture_updates_via_reload: could not resolve sequence_id from any update")
            command_helper.add_update_mutation(command, sequence_id, fallback_updates)
            return true
        end

        local function capture_updates_from_selection(default_sequence_id)
            local collected_ids = {}
            if type(args.selected_clip_ids) == "table" then
                for _, clip_id in ipairs(args.selected_clip_ids) do
                    if clip_id then
                        collected_ids[clip_id] = true
                    end
                end
            end
            if type(args.selected_edges) == "table" then
                for _, edge_info in ipairs(args.selected_edges) do
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
                local clip = Clip.load_optional(clip_id)
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

        local planned_mutations = {}
        local original_states_map = {}

        local function register_original_state(clip)
            if not clip or not clip.id then return end
            if not original_states_map[clip.id] then
                original_states_map[clip.id] = command_helper.capture_clip_state(clip)
            end
        end

        if args.selected_edges and #args.selected_edges > 0 then
            nudge_type = "edges"
            local preview_clips = {}

            -- Get sequence rate for source unit conversion.
            -- Query from DB (not timeline_state) so tests without UI init work.
            local seq_fps_num, seq_fps_den
            local seq_id = active_sequence_id or args.sequence_id
            if seq_id then
                local Sequence = require("models.sequence")
                local seq = Sequence.load(seq_id)
                if seq and seq.frame_rate then
                    seq_fps_num = seq.frame_rate.fps_numerator
                    seq_fps_den = seq.frame_rate.fps_denominator
                end
            end
            assert(seq_fps_num and seq_fps_num > 0 and seq_fps_den and seq_fps_den > 0,
                string.format("Nudge: sequence frame rate required (seq_id=%s)", tostring(seq_id)))

            for _, edge_info in ipairs(args.selected_edges) do
                local clip = Clip.load(edge_info.clip_id)
                -- NSF: If user selected an edge, the clip MUST exist
                assert(clip, string.format("Nudge: selected edge clip %s not found - selection is stale", edge_info.clip_id))

                register_original_state(clip)

                local clip_fps_num = clip.fps_numerator or (clip.rate and clip.rate.fps_numerator)
                local clip_fps_den = clip.fps_denominator or (clip.rate and clip.rate.fps_denominator)
                assert(clip_fps_num and clip_fps_den,
                    string.format("Nudge: clip %s missing fps", tostring(clip.id)))

                if edge_info.edge_type == "in" then
                    -- Nudge 'in' edge: source_in moves, source_out stays
                    local new_timeline_start = clip.timeline_start + nudge_frames
                    local new_duration = clip.duration - nudge_frames
                    local source_delta = frame_utils.timeline_to_source(
                        nudge_frames, clip_fps_num, clip_fps_den, seq_fps_num, seq_fps_den)

                    -- Clamp duration to minimum 1 frame
                    if new_duration < 1 then new_duration = 1 end

                    clip.timeline_start = new_timeline_start
                    clip.duration = new_duration
                    clip.source_in = clip.source_in + source_delta
                    -- source_out unchanged

                elseif edge_info.edge_type == "out" then
                    -- Nudge 'out' edge: source_out moves, source_in stays
                    local new_duration = clip.duration + nudge_frames
                    local source_delta = frame_utils.timeline_to_source(
                        nudge_frames, clip_fps_num, clip_fps_den, seq_fps_num, seq_fps_den)

                    -- Clamp duration to minimum 1 frame
                    if new_duration < 1 then new_duration = 1 end

                    clip.duration = new_duration
                    clip.source_out = clip.source_out + source_delta
                    -- source_in unchanged
                end

                -- Clamp timeline_start to 0 or greater
                if clip.timeline_start < 0 then
                    clip.timeline_start = 0
                end

                if args.dry_run then
                    table.insert(preview_clips, {
                        clip_id = clip.id,
                        new_start_value = clip.timeline_start,
                        new_duration = clip.duration,
                        edge_type = edge_info.edge_type
                    })
                else
                    mutated_clip_ids[clip.id] = true
                    table.insert(planned_mutations, clip_mutator.plan_update(clip, original_states_map[clip.id]))
                    register_update(clip)
                end
            end

            if args.dry_run then
                return true, {
                    nudge_type = "edges",
                    affected_clips = preview_clips
                }
            end

            print(string.format("✅ Nudged %d edge(s) by %d frames", #args.selected_edges, nudge_frames))
        elseif args.selected_clip_ids and #args.selected_clip_ids > 0 then
            nudge_type = "clips"
            local clips_to_move = {}

            -- Only move explicitly selected clips (link is a selection hint, not command behavior)
            for _, clip_id in ipairs(args.selected_clip_ids) do
                clips_to_move[clip_id] = true
            end

            local move_targets = {}
            local track_groups = {}
            local any_change = false
            local preview_clips = {}

            for clip_id, _ in pairs(clips_to_move) do
                local clip = Clip.load(clip_id)
                -- NSF: If user selected a clip, it MUST exist
                assert(clip, string.format("Nudge: selected clip %s not found - selection is stale", clip_id))

                -- V13: every `clips` row IS a timeline clip; the V8
                -- clip_kind discriminator is gone (master rows live in
                -- media_refs, not clips). No filter needed.


                register_original_state(clip)
                
                -- Nudge clip
                local new_start = clip.timeline_start + nudge_frames

                -- Clamp to 0
                if new_start < 0 then
                    new_start = 0
                end

                if new_start ~= clip.timeline_start then
                    any_change = true
                end
                clip.__new_start = new_start
                mutated_clip_ids[clip.id] = true
                table.insert(move_targets, clip)
                table.insert(preview_clips, {
                    clip_id = clip.id,
                    new_start_value = new_start,
                    new_duration = clip.duration
                })

                -- NSF: track_id is required for timeline clips - owner_sequence_id is NOT a valid fallback
                local track_id = clip.track_id
                assert(track_id, string.format("Nudge: clip %s missing track_id - invalid timeline clip state", clip.id))
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

                if not group.before_min or clip.timeline_start < group.before_min then group.before_min = clip.timeline_start end
                if not group.before_max or clip_end > group.before_max then group.before_max = clip_end end

                if not group.after_min or new_start < group.after_min then group.after_min = new_start end
                if not group.after_max or new_end > group.after_max then group.after_max = new_end end

                group.pending[clip.id] = {
                    timeline_start = new_start,
                    duration = clip.duration
                }

                table.insert(group.clips, clip)
            end

            if args.dry_run then
                return true, {
                    nudge_type = "clips",
                    affected_clips = preview_clips
                }
            end

            if any_change then
                -- Collect mutations for occlusions
                for track_id, group in pairs(track_groups) do
                    if group.after_max and group.after_min then
                        local block_duration = group.after_max - group.after_min
                        if group.before_max and group.before_min then
                            block_duration = math.max(block_duration, group.before_max - group.before_min)
                        end
                        
                        local ok, err, actions = clip_mutator.resolve_occlusions(db, {
                            track_id = track_id,
                            timeline_start = group.after_min,
                            duration = block_duration,
                            pending_clips = group.pending
                        })
                        if not ok then
                            print(string.format("ERROR: Nudge: Failed to resolve occlusions on track %s: %s", tostring(track_id), tostring(err)))
                            return false
                        end
                        
                        -- Process occlusion actions
                        if actions then
                            for _, action in ipairs(actions) do
                                table.insert(planned_mutations, action)
                            end
                        end
                    end
                end

                -- Apply moved clips in an order that avoids transient overlaps.
                table.sort(move_targets, function(a, b)
                    if nudge_frames >= 0 then
                        return a.timeline_start > b.timeline_start -- move right: update rightmost first
                    else
                        return a.timeline_start < b.timeline_start -- move left: update leftmost first
                    end
                end)

                -- Collect updates for nudged clips
                for _, clip in ipairs(move_targets) do
                    clip.timeline_start = clip.__new_start or clip.timeline_start
                    table.insert(planned_mutations, clip_mutator.plan_update(clip, original_states_map[clip.id]))
                    register_update(clip)
                end
            end

            print(string.format("✅ Nudged %d clip(s) by %d frames", #args.selected_clip_ids, nudge_frames))
        else
            set_last_error("Nudge: Nothing selected")
            return false
        end

        command:set_parameters({
            ["nudge_type"] = nudge_type,
            ["executed_mutations"] = planned_mutations,
        })
        -- Execute all mutations
        local ok_apply, apply_err = command_helper.apply_mutations(db, planned_mutations)
        if not ok_apply then
            return false, "Failed to apply mutations: " .. tostring(apply_err)
        end

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
        local args = command:get_all_parameters()
        print("Executing UndoNudge command")



        -- Best-effort state resync before applying undo to avoid stale in-memory clips causing overlap side-effects.
        local ts_ok, ts_mod = pcall(require, 'ui.timeline.timeline_state')
        if ts_ok and ts_mod and ts_mod.reload_clips and args.sequence_id and args.sequence_id ~= "" then
            ts_mod.reload_clips(args.sequence_id)
        end
        
        if not args.executed_mutations then
             set_last_error("UndoNudge: No executed mutations found (legacy command?)")
             return { success = false, error_message = "UndoNudge: No executed mutations found (legacy command?)" }
        end

        -- No transaction here — command_manager provides one

        local ok, err = command_helper.revert_mutations(db, args.executed_mutations, command, args.sequence_id)
        if not ok then
            -- Ensure UI state is consistent with DB after failure
            if ts_ok and ts_mod and ts_mod.reload_clips and args.sequence_id and args.sequence_id ~= "" then
                ts_mod.reload_clips(args.sequence_id)
            end
            return { success = false, error_message = "UndoNudge: Failed to revert mutations: " .. tostring(err) }
        end
        return { success = true }
    end

    command_executors["UndoNudge"] = command_undoers["UndoNudge"]
    -- Ensure undoer is registered under the base command type so command_manager can find it.
    command_undoers["Nudge"] = command_undoers["UndoNudge"]

    return {
        executor = command_executors["Nudge"],
        undoer = command_undoers["UndoNudge"],
        spec = SPEC,
    }
end

return M
