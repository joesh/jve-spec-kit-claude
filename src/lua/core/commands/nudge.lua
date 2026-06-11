local M = {}
local log = require("core.logger").for_area("commands")
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
            log.event("Executing Nudge")
        end

        -- Nudge amount must be integer frames
        local nudge_frames = args.nudge_amount
        assert(type(nudge_frames) == "number", "Nudge: nudge_amount must be integer frames")

        local nudge_type

        local active_sequence_id = command_helper.resolve_active_sequence_id(args.sequence_id, timeline_state)
        if active_sequence_id and active_sequence_id ~= args.sequence_id then
            command:set_parameter("sequence_id", active_sequence_id)
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

                local clip_fps_num = clip.frame_rate.fps_numerator
                local clip_fps_den = clip.frame_rate.fps_denominator
                assert(clip_fps_num and clip_fps_den,
                    string.format("Nudge: clip %s missing fps", tostring(clip.id)))

                if edge_info.edge_type == "in" then
                    -- Nudge 'in' edge: source_in moves, source_out stays
                    local new_sequence_start = clip.sequence_start + nudge_frames
                    local new_duration = clip.duration - nudge_frames
                    local source_delta = frame_utils.timeline_to_source(
                        nudge_frames, clip_fps_num, clip_fps_den, seq_fps_num, seq_fps_den)

                    -- Clamp duration to minimum 1 frame
                    if new_duration < 1 then new_duration = 1 end

                    clip.sequence_start = new_sequence_start
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

                -- Clamp sequence_start to 0 or greater
                if clip.sequence_start < 0 then
                    clip.sequence_start = 0
                end

                if args.dry_run then
                    table.insert(preview_clips, {
                        clip_id = clip.id,
                        new_start_value = clip.sequence_start,
                        new_duration = clip.duration,
                        edge_type = edge_info.edge_type
                    })
                else
                    table.insert(planned_mutations, clip_mutator.plan_update(clip, original_states_map[clip.id]))
                end
            end

            if args.dry_run then
                return true, {
                    nudge_type = "edges",
                    affected_clips = preview_clips
                }
            end

            log.event("Nudged %d edge(s) by %d frames",
                #args.selected_edges, nudge_frames)
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

                -- Clip-move primitive owns the lower-bound clamp
                -- (sequence.start_timecode_frame, NOT 0). Per-command
                -- clamps would leak the floor knowledge and let a
                -- missing one corrupt the model — sister to the
                -- core.playhead.set primitive.
                local new_start = clip_mutator.compute_safe_position(
                    clip, clip.sequence_start + nudge_frames)

                if new_start ~= clip.sequence_start then
                    any_change = true
                end
                clip.__new_start = new_start
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

                local clip_end = clip.sequence_start + clip.duration
                local new_end = new_start + clip.duration

                if not group.before_min or clip.sequence_start < group.before_min then group.before_min = clip.sequence_start end
                if not group.before_max or clip_end > group.before_max then group.before_max = clip_end end

                if not group.after_min or new_start < group.after_min then group.after_min = new_start end
                if not group.after_max or new_end > group.after_max then group.after_max = new_end end

                group.pending[clip.id] = {
                    sequence_start = new_start,
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
                            sequence_start = group.after_min,
                            duration = block_duration,
                            pending_clips = group.pending
                        })
                        if not ok then
                            log.error("Nudge: failed to resolve occlusions on track %s: %s",
                                tostring(track_id), tostring(err))
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
                        return a.sequence_start > b.sequence_start -- move right: update rightmost first
                    else
                        return a.sequence_start < b.sequence_start -- move left: update leftmost first
                    end
                end)

                -- Collect updates for nudged clips
                for _, clip in ipairs(move_targets) do
                    clip.sequence_start = clip.__new_start or clip.sequence_start
                    table.insert(planned_mutations, clip_mutator.plan_update(clip, original_states_map[clip.id]))
                end
            end

            log.event("Nudged %d clip(s) by %d frames",
                #args.selected_clip_ids, nudge_frames)
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

        -- Report EVERY applied planner mutation to the timeline cache —
        -- moved clips AND occlusion results (head/tail trims, full-cover
        -- deletes, straddle-split inserts). The previous bespoke capture
        -- chain registered only the nudged clips, so occluded neighbours
        -- kept their stale pre-trim geometry in the UI until a reload.
        local report_seq_id = active_sequence_id or args.sequence_id
        assert(report_seq_id and report_seq_id ~= "", string.format(
            "Nudge: cannot report timeline mutations without a sequence_id "
            .. "(nudge_type=%s)", tostring(nudge_type)))
        command_helper.report_planner_mutations(command, report_seq_id, planned_mutations)

        return true
    end

    command_undoers["Nudge"] = function(command)
        local args = command:get_all_parameters()
        log.event("Executing UndoNudge")



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

    -- Explicit "UndoNudge" command (Command:create_undo() builds one with
    -- this type; tests + redo-of-undone exercise the flow). Same body as
    -- the regular undoer.
    command_executors["UndoNudge"] = command_undoers["Nudge"]

    return {
        executor = command_executors["Nudge"],
        undoer   = command_undoers["Nudge"],
        spec     = SPEC,
    }
end

return M
