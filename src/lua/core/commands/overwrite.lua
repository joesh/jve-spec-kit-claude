local M = {}
local Clip = require('models.clip')
local command_helper = require("core.command_helper")
local Rational = require("core.rational")
local rational_helpers = require("core.command_rational_helpers")
local clip_mutator = require("core.clip_mutator")
local uuid = require("uuid")
local timeline_state
do
    local status, mod = pcall(require, 'ui.timeline.timeline_state')
    if status then timeline_state = mod end
end

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["Overwrite"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing Overwrite command")
        end

        local media_id = command:get_parameter("media_id")
        local track_id = command:get_parameter("track_id")
        
        local overwrite_time_raw = command:get_parameter("overwrite_time")
        local duration_raw = command:get_parameter("duration_value") or command:get_parameter("duration")
        local source_in_raw = command:get_parameter("source_in_value") or command:get_parameter("source_in")
        local source_out_raw = command:get_parameter("source_out_value") or command:get_parameter("source_out")
        local master_clip_id = command:get_parameter("master_clip_id")
        local project_id_param = command:get_parameter("project_id")
        
        local sequence_id = command_helper.resolve_sequence_for_track(command:get_parameter("sequence_id"), track_id) or "default_sequence"
        assert(sequence_id and sequence_id ~= "", "Overwrite: missing sequence_id after resolution")
        command:set_parameter("sequence_id", sequence_id)
        if not command:get_parameter("__snapshot_sequence_ids") then
            command:set_parameter("__snapshot_sequence_ids", {sequence_id})
        end

        local master_clip = nil
        local copied_properties = {}
        if master_clip_id and master_clip_id ~= "" then
            master_clip = Clip.load_optional(master_clip_id, db)
            if not master_clip then
                print(string.format("WARNING: Overwrite: Master clip %s not found; falling back to media only", tostring(master_clip_id)))
                master_clip_id = nil
            end
        end

        local seq_fps_num, seq_fps_den = rational_helpers.require_sequence_rate(db, sequence_id)

        local overwrite_time_rat = rational_helpers.require_rational_in_rate(overwrite_time_raw or 0, seq_fps_num, seq_fps_den, "overwrite_time")
        local duration_rat = rational_helpers.optional_rational_in_rate(duration_raw, seq_fps_num, seq_fps_den)

        if master_clip and (not media_id or media_id == "") then
            media_id = master_clip.media_id
        end

        if not media_id or media_id == "" or not track_id or track_id == "" then
            print("WARNING: Overwrite: Missing media_id or track_id")
            return false
        end

        local media_fps_num, media_fps_den
        if master_clip then
            media_fps_num, media_fps_den = rational_helpers.require_master_clip_rate(master_clip)
        else
            media_fps_num, media_fps_den = rational_helpers.require_media_rate(db, media_id)
        end

        local source_in_rat = rational_helpers.optional_rational_in_rate(source_in_raw, media_fps_num, media_fps_den)
        local source_out_rat = rational_helpers.optional_rational_in_rate(source_out_raw, media_fps_num, media_fps_den)

        if master_clip then
            if not source_in_rat then
                source_in_rat = master_clip.source_in or Rational.new(0, media_fps_num, media_fps_den)
            end
            if not source_out_rat then
                local effective_source_duration = duration_rat or master_clip.duration or Rational.new(0, media_fps_num, media_fps_den)
                source_out_rat = source_in_rat + effective_source_duration
            end

            if not duration_rat or duration_rat.frames <= 0 then
                local source_frame_count = source_out_rat.frames - source_in_rat.frames
                duration_rat = Rational.new(source_frame_count, seq_fps_num, seq_fps_den)
            end
            copied_properties = command_helper.ensure_copied_properties(command, master_clip_id)
        end

        overwrite_time_rat = Rational.hydrate(overwrite_time_rat, seq_fps_num, seq_fps_den)
        duration_rat = Rational.hydrate(duration_rat, seq_fps_num, seq_fps_den)
        source_in_rat = Rational.hydrate(source_in_rat, media_fps_num, media_fps_den)
        source_out_rat = Rational.hydrate(source_out_rat, media_fps_num, media_fps_den)

        if not overwrite_time_rat or not duration_rat or duration_rat.frames <= 0 or not source_out_rat then
            print("WARNING: Overwrite: Missing or invalid overwrite_time, duration, or source range")
            return false
        end

        -- Resolve Occlusions (Trim/Delete existing clips)
        local ok_occ, err_occ, planned_mutations = clip_mutator.resolve_occlusions(db, {
            track_id = track_id,
            timeline_start = overwrite_time_rat,
            duration = duration_rat,
            exclude_clip_id = nil -- Overwrite replaces everything under it
        })
        
        if not ok_occ then
            print(string.format("ERROR: Overwrite: Failed to resolve occlusions: %s", tostring(err_occ)))
            return false
        end
        
        local existing_clip_id = command:get_parameter("clip_id")
        local clip_opts = {
            id = existing_clip_id or uuid.generate(),
            project_id = project_id_param or (master_clip and master_clip.project_id),
            track_id = track_id,
            owner_sequence_id = sequence_id,
            parent_clip_id = master_clip_id,
            source_sequence_id = master_clip and master_clip.source_sequence_id,
            timeline_start = overwrite_time_rat,
            duration = duration_rat,
            source_in = source_in_rat,
            source_out = source_out_rat,
            enabled = true,
            offline = master_clip and master_clip.offline,
            rate_num = media_fps_num,
            rate_den = media_fps_den,
        }
        local clip_name = command:get_parameter("clip_name") or (master_clip and master_clip.name) or "Overwrite Clip"
        local clip_to_insert = Clip.create(clip_name, media_id, clip_opts)

        command:set_parameter("clip_id", clip_to_insert.id)
        if master_clip_id and master_clip_id ~= "" then
            command:set_parameter("master_clip_id", master_clip_id)
        end
        if project_id_param then
            command:set_parameter("project_id", project_id_param)
        elseif master_clip and master_clip.project_id then
            command:set_parameter("project_id", master_clip.project_id)
        end

        -- Add the new clip to the planned mutations
        table.insert(planned_mutations, clip_mutator.plan_insert(clip_to_insert))

        -- Apply all planned mutations within the transaction
        local ok_apply, apply_err = command_helper.apply_mutations(db, planned_mutations)
        if not ok_apply then
            return false, "Failed to apply clip_mutator actions: " .. tostring(apply_err)
        end

        -- Populate timeline mutation bucket for UI without falling back to reloads
        for _, mut in ipairs(planned_mutations) do
            if mut.type == "delete" then
                command_helper.add_delete_mutation(command, sequence_id, mut.clip_id)
            elseif mut.type == "update" then
                local updated = Clip.load_optional(mut.clip_id, db)
                if updated then
                    local payload = {
                        clip_id = updated.id,
                        track_id = updated.track_id,
                        track_sequence_id = updated.owner_sequence_id or sequence_id,
                        start_value = updated.timeline_start and updated.timeline_start.frames,
                        duration_value = updated.duration and updated.duration.frames,
                        source_in_value = updated.source_in and updated.source_in.frames,
                        source_out_value = updated.source_out and updated.source_out.frames,
                        enabled = updated.enabled
                    }
                    command_helper.add_update_mutation(command, payload.track_sequence_id or sequence_id, payload)
                end
            elseif mut.type == "insert" then
                local payload = command_helper.clip_insert_payload(clip_to_insert, sequence_id)
                if payload then
                    command_helper.add_insert_mutation(command, payload.track_sequence_id or sequence_id, payload)
                end
            end
        end
        
        -- Record mutations for undo AFTER successful commit
        command:set_parameter("executed_mutations", planned_mutations)
        
        if #copied_properties > 0 then
            command_helper.delete_properties_for_clip(clip_to_insert.id)
            if not command_helper.insert_properties_for_clip(clip_to_insert.id, copied_properties) then
                print(string.format("WARNING: Overwrite: Failed to copy properties from master clip %s", tostring(master_clip_id)))
            end
        end
        
        local advance_playhead = command:get_parameter("advance_playhead")
        if advance_playhead and timeline_state then
            timeline_state.set_playhead_position(overwrite_time_rat + duration_rat)
        end

        print(string.format("✅ Overwrote at %s (id: %s)",
            tostring(overwrite_time_rat), tostring(clip_to_insert.id)))
        return true
    end

    command_undoers["Overwrite"] = function(command)
        print("Undoing Overwrite command")
        local executed_mutations = command:get_parameter("executed_mutations") or {}
        local sequence_id = command:get_parameter("sequence_id")
        
        if not executed_mutations or #executed_mutations == 0 then
            print("WARNING: UndoOverwrite: No executed mutations to undo.")
            return false
        end

                local started, begin_err = db:begin_transaction()
                if not started then
                    print("ERROR: UndoOverwrite: Failed to begin transaction: " .. tostring(begin_err))
                    return false
                end
        
                local ok, err = command_helper.revert_mutations(db, executed_mutations, command, sequence_id)
                if not ok then
                    db:rollback_transaction(started)
                    print("ERROR: UndoOverwrite: Failed to revert mutations: " .. tostring(err))
                    return false
                end
        
                local ok_commit, commit_err = db:commit_transaction(started)
                if not ok_commit then
                    db:rollback_transaction(started)
                    return false, "Failed to commit undo transaction: " .. tostring(commit_err)
                end
        
                print("✅ Undo Overwrite: Reverted all changes")
                return true
            end
    command_executors["UndoOverwrite"] = command_undoers["Overwrite"]

    return {
        executor = command_executors["Overwrite"],
        undoer = command_undoers["Overwrite"]
    }
end

return M
