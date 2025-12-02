local M = {}
local Clip = require('models.clip')
local command_helper = require("core.command_helper")
local Rational = require("core.rational")
local uuid = require("uuid")
local timeline_state
do
    local status, mod = pcall(require, 'ui.timeline.timeline_state')
    if status then timeline_state = mod end
end
local clip_mutator = require('core.clip_mutator') -- New dependency

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["Insert"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing Insert command")
        end

        local media_id = command:get_parameter("media_id")
        local track_id = command:get_parameter("track_id")
        
        -- Early resolution of sequence FPS for hydration
        local sequence_id = command_helper.resolve_sequence_for_track(command:get_parameter("sequence_id"), track_id) or "default_sequence"
        if sequence_id and sequence_id ~= "" then
            command:set_parameter("sequence_id", sequence_id)
        end

        local seq_fps_num = 30
        local seq_fps_den = 1
        local seq_stmt = db:prepare("SELECT fps_numerator, fps_denominator FROM sequences WHERE id = ?")
        if seq_stmt then
            seq_stmt:bind_value(1, sequence_id)
            if seq_stmt:exec() and seq_stmt:next() then
                seq_fps_num = seq_stmt:value(0)
                seq_fps_den = seq_stmt:value(1)
            end
            seq_stmt:finalize()
        end

        local insert_time_raw = command:get_parameter("insert_time")
        local duration_raw = command:get_parameter("duration_value") or command:get_parameter("duration")
        local source_in_raw = command:get_parameter("source_in_value") or command:get_parameter("source_in")
        local source_out_raw = command:get_parameter("source_out_value") or command:get_parameter("source_out")
        
        local master_clip_id = command:get_parameter("master_clip_id")
        local project_id_param = command:get_parameter("project_id")

        local master_clip = nil
        if master_clip_id and master_clip_id ~= "" then
            master_clip = Clip.load_optional(master_clip_id, db)
            if not master_clip then
                print(string.format("WARNING: Insert: Master clip %s not found; falling back to media only", tostring(master_clip_id)))
                master_clip_id = nil
            end
        end

        local copied_properties = {}
        
        -- Hydrate initial command parameters
        local insert_time_rat = Rational.hydrate(insert_time_raw, seq_fps_num, seq_fps_den) or Rational.new(0, seq_fps_num, seq_fps_den)
        local duration_rat = Rational.hydrate(duration_raw, seq_fps_num, seq_fps_den)
        local source_in_rat = Rational.hydrate(source_in_raw, seq_fps_num, seq_fps_den) or Rational.new(0, seq_fps_num, seq_fps_den)
        local source_out_rat = Rational.hydrate(source_out_raw, seq_fps_num, seq_fps_den)
        -- Rescale any hydrated values to the sequence rate so math stays consistent with viewport/rendering
        if duration_rat then duration_rat = duration_rat:rescale(seq_fps_num, seq_fps_den) end
        if source_in_rat then source_in_rat = source_in_rat:rescale(seq_fps_num, seq_fps_den) end
        if source_out_rat then source_out_rat = source_out_rat:rescale(seq_fps_num, seq_fps_den) end

        if master_clip then
            if (not media_id or media_id == "") and master_clip.media_id then
                media_id = master_clip.media_id
            end
            
            -- Apply master clip defaults if duration not provided
            if not duration_rat or duration_rat.frames <= 0 then
                if master_clip.duration then
                    duration_rat = master_clip.duration
                else
                    local start = master_clip.source_in or Rational.new(0, seq_fps_num, seq_fps_den)
                    local end_t = master_clip.source_out or start
                    duration_rat = end_t - start
                end
            end
            
            -- Apply master clip defaults for source range if not provided or invalid
            if not source_out_rat or (source_in_rat and source_out_rat <= source_in_rat) then
                source_in_rat = master_clip.source_in or source_in_rat
                source_out_rat = master_clip.source_out or (source_in_rat + duration_rat)
            end
            if duration_rat then duration_rat = duration_rat:rescale(seq_fps_num, seq_fps_den) end
            if source_in_rat then source_in_rat = source_in_rat:rescale(seq_fps_num, seq_fps_den) end
            if source_out_rat then source_out_rat = source_out_rat:rescale(seq_fps_num, seq_fps_den) end
            copied_properties = command_helper.ensure_copied_properties(command, master_clip_id)
        end

        if not media_id or media_id == "" or not track_id or track_id == "" then
            print("WARNING: Insert: Missing media_id or track_id")
            return false
        end

        if not insert_time_rat or not duration_rat or duration_rat.frames <= 0 or not source_out_rat then
            print(string.format("WARNING: Insert: Invalid params. time=%s dur=%s out=%s", 
                tostring(insert_time_rat), tostring(duration_rat), tostring(source_out_rat)))
            print("WARNING: Insert: Missing or invalid insert_time, duration, or source_out")
            return false
        end

        -- Resolve occlusions (splits and ripples existing clips)
        -- `clip_mutator.resolve_ripple` handles shifting/splitting
        local ok_occ, err_occ, planned_mutations = clip_mutator.resolve_ripple(db, {
            track_id = track_id,
            insert_time = insert_time_rat,
            shift_amount = duration_rat
        })
        
        if not ok_occ then
            print(string.format("ERROR: Insert: Failed to resolve ripple: %s", tostring(err_occ)))
            return false
        end

        local existing_clip_id = command:get_parameter("clip_id")
        local clip_name = (master_clip and master_clip.name) or "Inserted Clip"
        
        local clip_opts = {
            id = existing_clip_id or uuid.generate(),
            project_id = project_id_param or (master_clip and master_clip.project_id),
            track_id = track_id,
            owner_sequence_id = sequence_id,
            parent_clip_id = master_clip_id,
            source_sequence_id = master_clip and master_clip.source_sequence_id,
            timeline_start = insert_time_rat,
            duration = duration_rat,
            source_in = source_in_rat,
            source_out = source_out_rat,
            enabled = true,
            offline = master_clip and master_clip.offline,
            rate_num = seq_fps_num,
            rate_den = seq_fps_den,
        }
        local clip_to_insert = Clip.create(clip_name, media_id, clip_opts)
        -- Persist clip id on the command for replay/undo bookkeeping
        command:set_parameter("clip_id", clip_to_insert.id)
        -- Add the new clip to the planned mutations
        table.insert(planned_mutations, clip_mutator.plan_insert(clip_to_insert))

        -- Apply all planned mutations within the transaction
        local ok_apply, apply_err = command_helper.apply_mutations(db, planned_mutations)
        if not ok_apply then
            return false, "Failed to apply clip_mutator actions: " .. tostring(apply_err)
        end
        
        -- Record mutations for undo AFTER successful commit
        command:set_parameter("executed_mutations", planned_mutations)

        if #copied_properties > 0 then
            command_helper.delete_properties_for_clip(clip_to_insert.id)
            if not command_helper.insert_properties_for_clip(clip_to_insert.id, copied_properties) then
                print(string.format("WARNING: Insert: Failed to copy properties from master clip %s", tostring(master_clip_id)))
            end
        end
        local advance_playhead = command:get_parameter("advance_playhead")
        if advance_playhead and timeline_state then
            timeline_state.set_playhead_position(insert_time_rat + duration_rat)
        end

        print(string.format("✅ Inserted clip at %s (id: %s)",
            tostring(insert_time_rat), tostring(clip_to_insert.id)))
        return true
    end

    command_undoers["Insert"] = function(command)
        print("Undoing Insert command")

        local executed_mutations = command:get_parameter("executed_mutations")
        local sequence_id = command:get_parameter("sequence_id")
        
        if not executed_mutations or #executed_mutations == 0 then
            print("WARNING: UndoInsert: No executed mutations to undo.")
            return false
        end

        local started, begin_err = db:begin_transaction()
        if not started then
            print("ERROR: UndoInsert: Failed to begin transaction: " .. tostring(begin_err))
            return false
        end

        local ok, err = command_helper.revert_mutations(db, executed_mutations, command, sequence_id)
        if not ok then
            db:rollback_transaction(started)
            print("ERROR: UndoInsert: Failed to revert mutations: " .. tostring(err))
            return false
        end

        local ok_commit, commit_err = db:commit_transaction(started)
        if not ok_commit then
            db:rollback_transaction(started)
            return false, "Failed to commit undo transaction: " .. tostring(commit_err)
        end

        print("✅ Undo Insert: Reverted all changes")
        return true
    end

    command_executors["UndoInsert"] = command_undoers["Insert"]

    return {
        executor = command_executors["Insert"],
        undoer = command_undoers["Insert"]
    }
end

return M
