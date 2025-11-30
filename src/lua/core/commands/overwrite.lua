local M = {}
local Clip = require('models.clip')
local command_helper = require("core.command_helper")
local Rational = require("core.rational")
local clip_mutator = require("core.clip_mutator")
local timeline_state
do
    local status, mod = pcall(require, 'ui.timeline.timeline_state')
    if status then timeline_state = mod end
end

function M.register(command_executors, command_undoers, db, set_last_error)
    local function append_actions(target, actions)
        if not actions or target == nil then
            return
        end
        for _, action in ipairs(actions) do
            target[#target + 1] = action
        end
    end

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

    local function revert_occlusion_actions(actions, command, sequence_id)
        if not actions or #actions == 0 then
            return
        end
        -- Revert in reverse order
        for i = #actions, 1, -1 do
            local action = actions[i]
            if action.type == 'trim' then
                local restored = command_helper.restore_clip_state(action.before)
                if restored and command then
                    restored:save(db, {skip_occlusion = true})
                    local payload = command_helper.clip_update_payload(restored, sequence_id or restored.owner_sequence_id or restored.track_sequence_id)
                    if payload then
                        command_helper.add_update_mutation(command, payload.track_sequence_id or sequence_id, payload)
                    end
                end
            elseif action.type == 'delete' then
                local restored = command_helper.restore_clip_state(action.clip or action.before)
                if restored and command then
                    restored:save(db, {skip_occlusion = true})
                    local payload = command_helper.clip_insert_payload(restored, sequence_id or restored.owner_sequence_id or restored.track_sequence_id)
                    if payload then
                        command_helper.add_insert_mutation(command, payload.track_sequence_id or sequence_id, payload)
                    end
                end
            elseif action.type == 'insert' then
                local state = action.clip
                if state then
                    local clip = Clip.load_optional(state.id, db)
                    if clip and clip:delete(db) and command then
                        command_helper.add_delete_mutation(command, sequence_id or state.owner_sequence_id or state.track_sequence_id, state.id)
                    end
                end
            end
        end
    end

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
        
        local sequence_id = command_helper.resolve_sequence_for_track(command:get_parameter("sequence_id"), track_id)
        if sequence_id and sequence_id ~= "" then
            command:set_parameter("sequence_id", sequence_id)
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

        local function hydrate(val)
            if type(val) == "table" and val.frames then
                return Rational.new(val.frames, val.fps_numerator or seq_fps_num, val.fps_denominator or seq_fps_den)
            elseif type(val) == "number" then
                return Rational.new(val, seq_fps_num, seq_fps_den)
            end
            return nil
        end
        
        local overwrite_time_rat = hydrate(overwrite_time_raw)
        local duration_rat = hydrate(duration_raw)
        local source_in_rat = hydrate(source_in_raw)
        local source_out_rat = hydrate(source_out_raw)

        if master_clip and (not media_id or media_id == "") then
            media_id = master_clip.media_id
        end

        if not media_id or media_id == "" or not track_id or track_id == "" then
            print("WARNING: Overwrite: Missing media_id or track_id")
            return false
        end

        if master_clip then
            if not duration_rat or duration_rat.frames <= 0 then
                if master_clip.duration then
                    duration_rat = master_clip.duration
                else
                    local start = master_clip.source_in or Rational.new(0, seq_fps_num, seq_fps_den)
                    local end_t = master_clip.source_out or start
                    duration_rat = end_t - start
                end
            end
            if not source_out_rat or (source_in_rat and source_out_rat <= source_in_rat) then
                source_in_rat = master_clip.source_in or (source_in_rat or Rational.new(0, seq_fps_num, seq_fps_den))
                source_out_rat = master_clip.source_out or (source_in_rat + duration_rat)
            end
            copied_properties = command_helper.ensure_copied_properties(command, master_clip_id)
        end

        if not overwrite_time_rat or not duration_rat or duration_rat.frames <= 0 or not source_out_rat then
            print("WARNING: Overwrite: Missing or invalid overwrite_time, duration, or source range")
            return false
        end

        -- Resolve Occlusions (Trim/Delete existing clips)
        local ok_occ, err_occ, actions = clip_mutator.resolve_occlusions(db, {
            track_id = track_id,
            timeline_start = overwrite_time_rat,
            duration = duration_rat,
            exclude_clip_id = nil -- Overwrite replaces everything under it
        })
        
        if not ok_occ then
            print(string.format("ERROR: Overwrite: Failed to resolve occlusions: %s", tostring(err_occ)))
            return false
        end
        
        if actions and #actions > 0 then
            record_occlusion_actions(command, sequence_id, actions)
            command:set_parameter("occlusion_actions", actions)
        end

        -- Reuse existing clip ID if we completely overwrote exactly one clip?
        -- The legacy logic tried to be smart. V5 simplifies: insert new clip.
        -- clip_mutator deleted what was under.
        
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
            rate_num = seq_fps_num,
            rate_den = seq_fps_den,
        }
        local clip_name = command:get_parameter("clip_name") or (master_clip and master_clip.name) or "Overwrite Clip"
        local clip = Clip.create(clip_name, media_id, clip_opts)

        command:set_parameter("clip_id", clip.id)
        if master_clip_id and master_clip_id ~= "" then
            command:set_parameter("master_clip_id", master_clip_id)
        end
        if project_id_param then
            command:set_parameter("project_id", project_id_param)
        elseif master_clip and master_clip.project_id then
            command:set_parameter("project_id", master_clip.project_id)
        end

        -- Save with skip_occlusion=true because we already resolved it
        local saved, save_actions = clip:save(db, {skip_occlusion = true})
        if saved then
            if #copied_properties > 0 then
                command_helper.delete_properties_for_clip(clip.id)
                if not command_helper.insert_properties_for_clip(clip.id, copied_properties) then
                    print(string.format("WARNING: Overwrite: Failed to copy properties from master clip %s", tostring(master_clip_id)))
                end
            end
            
            local advance_playhead = command:get_parameter("advance_playhead")
            if advance_playhead and timeline_state then
                timeline_state.set_playhead_position(overwrite_time_rat + duration_rat)
            end

            local insert_payload = command_helper.clip_insert_payload(clip, sequence_id)
            if insert_payload then
                command_helper.add_insert_mutation(command, insert_payload.track_sequence_id, insert_payload)
            end

            command:set_parameter("__skip_sequence_replay_on_undo", true)

            print(string.format("✅ Overwrote at %s", tostring(overwrite_time_rat)))
            return true
        else
            print("WARNING: Overwrite: Failed to save clip")
            return false
        end
    end

    command_undoers["Overwrite"] = function(command)
        print("Undoing Overwrite command")
        local sequence_id = command:get_parameter("sequence_id")
        local occlusion_actions = command:get_parameter("occlusion_actions") or {}
        local clip_id = command:get_parameter("clip_id")

        -- Delete the inserted clip
        if clip_id and clip_id ~= "" then
            command_helper.delete_clips_by_id(command, sequence_id, {clip_id})
        end

        -- Restore occluded clips
        if occlusion_actions and #occlusion_actions > 0 then
            revert_occlusion_actions(occlusion_actions, command, sequence_id)
        end

        print("✅ Undo Overwrite: Restored overlapped clips and selection state")
        return true
    end

    command_executors["UndoOverwrite"] = command_undoers["Overwrite"]

    return {
        executor = command_executors["Overwrite"],
        undoer = command_undoers["Overwrite"]
    }
end

return M