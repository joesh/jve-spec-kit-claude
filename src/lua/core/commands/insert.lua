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

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["Insert"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing Insert command")
        end

        local media_id = command:get_parameter("media_id")
        local track_id = command:get_parameter("track_id")
        
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
        if master_clip then
            if (not media_id or media_id == "") and master_clip.media_id then
                media_id = master_clip.media_id
            end
            if duration_raw == nil or (type(duration_raw) == "table" and duration_raw.frames <= 0) or (type(duration_raw) == "number" and duration_raw <= 0) then
                duration_raw = master_clip.duration or (master_clip.source_out - master_clip.source_in)
            end
            if source_out_raw == nil or (type(source_out_raw) == "table" and source_out_raw <= source_in_raw) or (type(source_out_raw) == "number" and source_out_raw <= source_in_raw) then
                source_in_raw = master_clip.source_in or source_in_raw
                source_out_raw = master_clip.source_out or (source_in_raw + duration_raw)
            end
            copied_properties = command_helper.ensure_copied_properties(command, master_clip_id)
        end

        if not media_id or media_id == "" or not track_id or track_id == "" then
            print("WARNING: Insert: Missing media_id or track_id")
            return false
        end

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

        local function to_rational_with_seq_fps(val)
            if type(val) == "table" and val.frames then return val end
            if type(val) == "number" then
                return Rational.new(val, seq_fps_num, seq_fps_den)
            end
            return Rational.new(0, seq_fps_num, seq_fps_den) -- Default to zero Rational
        end
        
        local insert_time_rat = to_rational_with_seq_fps(insert_time_raw)
        local duration_rat = to_rational_with_seq_fps(duration_raw)
        local source_in_rat = to_rational_with_seq_fps(source_in_raw)
        local source_out_rat = to_rational_with_seq_fps(source_out_raw)

        if not insert_time_rat or not duration_rat or duration_rat.frames <= 0 or not source_out_rat then
            print("WARNING: Insert: Missing or invalid insert_time, duration, or source_out")
            return false
        end

        local overlap_query = db:prepare([[
            SELECT id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator
            FROM clips
            WHERE track_id = ?
            ORDER BY timeline_start_frame ASC
        ]])

        if not overlap_query then
            print("WARNING: Insert: Failed to prepare query")
            return false
        end

        overlap_query:bind_value(1, track_id)

        local clips_to_ripple = {}
        local clips_to_split = {}
        local pending_moves = {}
        
        local pending_tolerance = Rational.new(1, seq_fps_num, seq_fps_den)
        
        if overlap_query:exec() then
            while overlap_query:next() do
                local clip_id = overlap_query:value(0)
                local clip_start_frame = overlap_query:value(1)
                local clip_duration_frame = overlap_query:value(2)
                local clip_source_in_frame = overlap_query:value(3)
                local clip_source_out_frame = overlap_query:value(4)
                local clip_fps_num = overlap_query:value(5)
                local clip_fps_den = overlap_query:value(6)

                local current_clip_start_rat = Rational.new(clip_start_frame, clip_fps_num, clip_fps_den)
                local current_clip_duration_rat = Rational.new(clip_duration_frame, clip_fps_num, clip_fps_den)
                local current_clip_end_rat = current_clip_start_rat + current_clip_duration_rat

                if current_clip_start_rat >= insert_time_rat then
                    -- Clip starts after or at insert point, needs to be rippled
                    local new_start = current_clip_start_rat + duration_rat
                    table.insert(clips_to_ripple, {
                        id = clip_id,
                        old_start = current_clip_start_rat,
                        new_start = new_start,
                        duration = current_clip_duration_rat,
                        source_in = Rational.new(clip_source_in_frame, clip_fps_num, clip_fps_den),
                        source_out = Rational.new(clip_source_out_frame, clip_fps_num, clip_fps_den)
                    })
                    pending_moves[clip_id] = {
                        timeline_start = new_start,
                        duration = current_clip_duration_rat,
                        tolerance = pending_tolerance
                    }
                elseif current_clip_start_rat < insert_time_rat and current_clip_end_rat > insert_time_rat then
                    -- Clip straddles insert point, needs to be split
                    local left_part_duration = insert_time_rat - current_clip_start_rat
                    local right_part_duration = current_clip_end_rat - insert_time_rat
                    
                    table.insert(clips_to_split, {
                        original_id = clip_id,
                        original_start = current_clip_start_rat,
                        original_duration = current_clip_duration_rat,
                        original_source_in = Rational.new(clip_source_in_frame, clip_fps_num, clip_fps_den),
                        original_source_out = Rational.new(clip_source_out_frame, clip_fps_num, clip_fps_den),
                        left_part_duration = left_part_duration,
                        right_part_duration = right_part_duration,
                        clip_fps_num = clip_fps_num,
                        clip_fps_den = clip_fps_den
                    })
                end
            end
        end

        if dry_run then
            local preview_rippled_clips = {}
            for _, clip_info in ipairs(clips_to_ripple) do
                table.insert(preview_rippled_clips, {
                    clip_id = clip_info.id,
                    new_start_value = clip_info.new_start
                })
            end

            local existing_clip_id = command:get_parameter("clip_id")
            local new_clip_id = existing_clip_id or Clip.generate_id()

            return true, {
                new_clip = {
                    clip_id = new_clip_id,
                    track_id = track_id,
                    timeline_start = insert_time_rat,
                    duration = duration_rat,
                    source_in = source_in_rat,
                    source_out = source_out_rat
                },
                rippled_clips = preview_rippled_clips
            }
        end

        -- Handle Splits first
        local executed_splits = {}
        for _, split_info in ipairs(clips_to_split) do
            local original_clip = Clip.load_optional(split_info.original_id, db)
            if not original_clip then goto continue_split end

            -- Trim original clip to be the "left part"
            original_clip.duration = split_info.left_part_duration
            original_clip.source_out = original_clip.source_in + split_info.left_part_duration
            assert(original_clip:save(db, {skip_occlusion = true}), "Failed to trim left part of split clip")
            command_helper.add_update_mutation(command, sequence_id, command_helper.clip_update_payload(original_clip, sequence_id))

            -- Create new clip for the "right part"
            local right_part_id = uuid.generate()
            local right_part_clip = Clip.create(original_clip.name .. " (2)", original_clip.media_id, {
                id = right_part_id,
                project_id = original_clip.project_id,
                track_id = original_clip.track_id,
                owner_sequence_id = original_clip.owner_sequence_id,
                parent_clip_id = original_clip.parent_clip_id,
                source_sequence_id = original_clip.source_sequence_id,
                timeline_start = insert_time_rat + duration_rat, -- Starts after the new inserted clip
                duration = split_info.right_part_duration,
                source_in = original_clip.source_in + split_info.left_part_duration,
                source_out = original_clip.source_out,
                enabled = original_clip.enabled,
                offline = original_clip.offline,
                rate_num = split_info.clip_fps_num,
                rate_den = split_info.clip_fps_den,
            })
            assert(right_part_clip:save(db, {skip_occlusion = true}), "Failed to save right part of split clip")
            command_helper.add_insert_mutation(command, sequence_id, command_helper.clip_insert_payload(right_part_clip, sequence_id))
            
            -- This new right part needs to be rippled too!
            table.insert(clips_to_ripple, {
                id = right_part_id,
                old_start = right_part_clip.timeline_start,
                new_start = right_part_clip.timeline_start + duration_rat,
                duration = right_part_clip.duration,
                source_in = right_part_clip.source_in,
                source_out = right_part_clip.source_out
            })

            table.insert(executed_splits, {
                original_id = original_clip.id,
                right_id = right_part_id,
                original_duration = split_info.original_duration,
                original_source_out = split_info.original_source_out
            })
            ::continue_split::
        end

        -- Execute Ripples
        for _, clip_info in ipairs(clips_to_ripple) do
            local clip = Clip.load_optional(clip_info.id, db)
            if not clip then
                print(string.format("WARNING: Insert: Skipping missing clip %s during ripple", clip_info.id))
                pending_moves[clip_info.id] = nil
                goto continue_ripple
            end

            clip.timeline_start = clip_info.new_start

            local save_opts = {skip_occlusion = true}
            local saved, occlusion_actions = clip:save(db, save_opts)
            if not saved then
                print(string.format("WARNING: Insert: Failed to ripple clip %s", clip_info.id))
                return false
            end
            pending_moves[clip.id] = nil
            
            local update_payload = command_helper.clip_update_payload(clip, sequence_id)
            if update_payload then
                command_helper.add_update_mutation(command, update_payload.track_sequence_id, update_payload)
            end

            ::continue_ripple::
        end

        command:set_parameter("rippled_clips", clips_to_ripple)
        command:set_parameter("split_clips", executed_splits) -- Store split info

        local existing_clip_id = command:get_parameter("clip_id")
        local clip_name = (master_clip and master_clip.name) or "Inserted Clip"
        
        local clip_opts = {
            id = existing_clip_id,
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

        local saved, clip_occlusion_actions = clip:save(db, {skip_occlusion = true}) -- Inserted clip is new, safe to skip occlusion
        if saved then
            if #copied_properties > 0 then
                command_helper.delete_properties_for_clip(clip.id)
                if not command_helper.insert_properties_for_clip(clip.id, copied_properties) then
                    print(string.format("WARNING: Insert: Failed to copy properties from master clip %s", tostring(master_clip_id)))
                end
            end
            local advance_playhead = command:get_parameter("advance_playhead")
            if advance_playhead and timeline_state then
                timeline_state.set_playhead_position(insert_time_rat + duration_rat)
            end

            local insert_payload = command_helper.clip_insert_payload(clip, sequence_id)
            if insert_payload then
                command_helper.add_insert_mutation(command, insert_payload.track_sequence_id, insert_payload)
            end

            print(string.format("✅ Inserted clip at %s, rippled %d clips forward by %s",
                tostring(insert_time_rat), #clips_to_ripple, tostring(duration_rat)))
            return true
        else
            print("WARNING: Insert: Failed to save clip")
            return false
        end
    end

    command_undoers["Insert"] = function(command)
        print("Undoing Insert command")

        local clip_id = command:get_parameter("clip_id")
        local rippled_clips = command:get_parameter("rippled_clips")
        local split_clips_info = command:get_parameter("split_clips") -- Added for undo
        local sequence_id = command:get_parameter("sequence_id")
        
        -- Hydrate duration_rat from command parameter directly
        local duration_rat = command:get_parameter("duration")
        if type(duration_rat) == "table" and duration_rat.frames and (not getmetatable(duration_rat) or not getmetatable(duration_rat).__lt) then
            duration_rat = Rational.new(duration_rat.frames, duration_rat.fps_numerator, duration_rat.fps_denominator)
        end

        if not clip_id then
            print("WARNING: UndoInsert: Missing clip_id")
            return false
        end

        -- Delete the inserted clip
        command_helper.delete_clips_by_id(command, sequence_id, {clip_id})
        
        -- Undo Splits
        if split_clips_info then
            for _, split_info in ipairs(split_clips_info) do
                -- Delete right part
                command_helper.delete_clips_by_id(command, sequence_id, {split_info.right_id})
                
                -- Restore original clip (left part) duration and source out
                local original_clip = Clip.load_optional(split_info.original_id, db)
                if original_clip then
                    original_clip.duration = split_info.original_duration
                    original_clip.source_out = split_info.original_source_out
                    if not original_clip:save(db, {skip_occlusion = true}) then
                        print(string.format("WARNING: UndoInsert: Failed to restore original clip %s duration", split_info.original_id))
                    else
                        command_helper.add_update_mutation(command, sequence_id, command_helper.clip_update_payload(original_clip, sequence_id))
                    end
                end
            end
        end

        -- Ripple clips back
        if rippled_clips then
            for _, clip_info in ipairs(rippled_clips) do
                -- Hydrate old_start and new_start
                if type(clip_info.old_start) == "table" and clip_info.old_start.frames and (not getmetatable(clip_info.old_start) or not getmetatable(clip_info.old_start).__lt) then
                    clip_info.old_start = Rational.new(clip_info.old_start.frames, clip_info.old_start.fps_numerator, clip_info.old_start.fps_denominator)
                end
                if type(clip_info.new_start) == "table" and clip_info.new_start.frames and (not getmetatable(clip_info.new_start) or not getmetatable(clip_info.new_start).__lt) then
                    clip_info.new_start = Rational.new(clip_info.new_start.frames, clip_info.new_start.fps_numerator, clip_info.new_start.fps_denominator)
                end

                local clip = Clip.load_optional(clip_info.id, db)
                if clip then
                    clip.timeline_start = clip_info.old_start -- Move back to old start
                    if not clip:save(db, {skip_occlusion = true}) then
                        print(string.format("WARNING: UndoInsert: Failed to un-ripple clip %s", clip_info.id))
                    else
                        command_helper.add_update_mutation(command, sequence_id, command_helper.clip_update_payload(clip, sequence_id))
                    end
                end
            end
        end

        print("✅ Undo Insert: Removed inserted clip and un-rippled clips")
        return true
    end

    command_executors["UndoInsert"] = command_undoers["Insert"]

    return {
        executor = command_executors["Insert"],
        undoer = command_undoers["Insert"]
    }
end

return M