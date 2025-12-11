local M = {}
local Clip = require('models.clip')
local command_helper = require("core.command_helper")
local frame_utils = require('core.frame_utils')
local database = require('core.database')
local Rational = require('core.rational') -- Added dependency
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

    local function apply_edge_ripple(clip, edge_type, delta_rat)
        -- Ensure we are dealing with Rational objects
        if not clip.duration or not clip.duration.frames then
             error("apply_edge_ripple: clip duration is not Rational")
        end
        
        if edge_type == "in" then
            -- Ripple in: shorten duration, advance source_in
            local new_dur = clip.duration - delta_rat
            if new_dur.frames < 1 then return nil, false, true end -- Too short
            
            clip.duration = new_dur
            -- clip.timeline_start UNCHANGED
            
            if clip.media_id then
                clip.source_in = clip.source_in + delta_rat
            end
        elseif edge_type == "out" then
            -- Ripple out: change duration
            local new_dur = clip.duration + delta_rat
            if new_dur.frames < 1 then return nil, false, true end
            
            clip.duration = new_dur
            if clip.media_id then
                clip.source_out = clip.source_in + new_dur
            end
        end
        
        return clip.timeline_start, true, false
    end

    local function collect_downstream_clips(all_clips, excluded_ids, ripple_time)
        local clips = {}
        for _, other in ipairs(all_clips) do
            if other.timeline_start >= ripple_time then
                if not excluded_ids or not excluded_ids[other.id] then
                    clips[#clips + 1] = other
                end
            end
        end
        return clips
    end

    command_executors["RippleEdit"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing RippleEdit command")
        end

        local raw_edge_info = command:get_parameter("edge_info")
        local delta_frames = command:get_parameter("delta_frames")
        local delta_ms = command:get_parameter("delta_ms") 
        
        if not raw_edge_info or (not delta_frames and not delta_ms) then
             print("ERROR: RippleEdit missing parameters")
             return {success = false, error_message = "RippleEdit missing parameters"}
        end
        
        local edge_info = raw_edge_info
        if type(raw_edge_info.clip_id) == "string" and raw_edge_info.clip_id:find("^temp_gap_") then
            edge_info = {}
            for k, v in pairs(raw_edge_info) do edge_info[k] = v end
            edge_info.clip_id = edge_info.clip_id:gsub("^temp_gap_", "")
            command:set_parameter("edge_info", edge_info)
        end

        local sequence_id = command_helper.resolve_sequence_for_track(nil, edge_info.track_id)
        if not sequence_id or sequence_id == "" then sequence_id = "default_sequence" end
        
        local all_clips = database.load_clips(sequence_id)
        
        local occlusion_actions = {}
        local post_states = {}
        local deleted_clip_ids = {}
        
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
        
        -- Strict input: delta must be Rational via delta_ms (Rational/table) or integer frames
        local delta_rat
        if delta_frames then
            delta_rat = Rational.new(delta_frames, seq_fps_num, seq_fps_den)
        elseif delta_ms then
            if type(delta_ms) == "number" then
                error("RippleEdit: delta_ms must be Rational, not number")
            end
            if getmetatable(delta_ms) == Rational.metatable then
                delta_rat = delta_ms:rescale(seq_fps_num, seq_fps_den)
            elseif type(delta_ms) == "table" and delta_ms.frames then
                delta_rat = Rational.new(delta_ms.frames, delta_ms.fps_numerator or seq_fps_num, delta_ms.fps_denominator or seq_fps_den)
            else
                error("RippleEdit: delta_ms must be Rational-like")
            end
        end
        if not delta_rat or not delta_rat.frames then
            return {success = false, error_message = "RippleEdit missing valid delta"}
        end

        local clip = Clip.load(edge_info.clip_id, db)
        if not clip then
             print("ERROR: RippleEdit: Clip not found")
             return {success = false, error_message = "Clip not found"}
        end
        
        local original_start_rat = clip.timeline_start
        local original_duration_rat = clip.duration
        local original_end_rat = original_start_rat + original_duration_rat

        local requested_delta_frames = delta_rat.frames
        local clamped_delta = delta_rat
        local is_gap_clip = false -- Simplified
        
        -- MEDIA BOUNDARY CLAMPING
        if not is_gap_clip and clip.media_id then
             local media_stmt = db:prepare("SELECT duration_frames, fps_numerator, fps_denominator FROM media WHERE id = ?")
             if media_stmt then
                 media_stmt:bind_value(1, clip.media_id)
                 if media_stmt:exec() and media_stmt:next() then
                     local m_dur = media_stmt:value(0)
                     local m_num = media_stmt:value(1)
                     local m_den = media_stmt:value(2)
                     if m_dur and m_num and m_den then
                         -- Media duration in its own timebase
                         local media_duration = Rational.new(m_dur, m_num, m_den)
                         
                         -- Current source out
                         local current_out = clip.source_out
                         
                         if edge_info.edge_type == "out" then
                             -- Extending tail: New Out = Current Out + Delta
                             -- Limit: New Out <= Media Duration
                             -- Current Out + Delta <= Media Duration
                             -- Delta <= Media Duration - Current Out
                             local max_delta = media_duration - current_out
                             if clamped_delta > max_delta then
                                 clamped_delta = max_delta
                             end
                         elseif edge_info.edge_type == "in" then
                             -- Extending head (moving In left): New In = Current In + Delta (Delta is negative)
                             -- Limit: New In >= 0
                             -- Current In + Delta >= 0
                             -- Delta >= -Current In
                             local min_delta = -clip.source_in
                             if clamped_delta < min_delta then
                                 clamped_delta = min_delta
                             end
                         end
                     end
                 end
                 media_stmt:finalize()
             end
        end

        if edge_info.edge_type == "gap_before" and clamped_delta < Rational.new(0, seq_fps_num, seq_fps_den) then
            local closest_end = nil
            for _, other in ipairs(all_clips) do
                if other.track_id == clip.track_id and other.id ~= clip.id then
                    local other_end = other.timeline_start + other.duration
                    if other_end <= original_start_rat and (not closest_end or other_end > closest_end) then
                        closest_end = other_end
                    end
                end
            end

            if closest_end then
                local gap = original_start_rat - closest_end
                local max_close = Rational.new(-gap.frames, gap.fps_numerator, gap.fps_denominator)
                if clamped_delta < max_close then
                    clamped_delta = max_close
                end
            end
        end

        if edge_info.edge_type == "gap_after" and clamped_delta > Rational.new(0, seq_fps_num, seq_fps_den) then
            local next_start = nil
            for _, other in ipairs(all_clips) do
                if other.track_id == clip.track_id and other.id ~= clip.id then
                    if other.timeline_start >= original_end_rat then
                        if not next_start or other.timeline_start < next_start then
                            next_start = other.timeline_start
                        end
                    end
                end
            end
            if next_start then
                local gap = next_start - original_end_rat
                if clamped_delta > gap then
                    clamped_delta = gap
                end
            end
        end

        delta_rat = clamped_delta
        local clamped_delta_ms = (delta_rat.frames * 1000) / (seq_fps_num / seq_fps_den)
        command:set_parameter("clamped_delta_ms", clamped_delta_ms)

        local original_clip_state = nil
        if not dry_run and not is_gap_clip then
            original_clip_state = command_helper.capture_clip_state(clip)
        end

        local ripple_time = original_end_rat
        local shift_rat
        local deleted_clip = nil
        local success = true

        if edge_info.edge_type == "gap_before" then
            -- Gap closure/expansion: slide the entire clip (and downstream clips) by delta
            local new_start = clip.timeline_start + delta_rat
            if new_start < Rational.new(0, seq_fps_num, seq_fps_den) then
                local new_end = new_start + clip.duration
                if new_end <= Rational.new(0, seq_fps_num, seq_fps_den) then
                    deleted_clip = true
                    shift_rat = -clip.duration
                else
                    new_start = Rational.new(0, seq_fps_num, seq_fps_den)
                    shift_rat = new_start - original_start_rat
                    clip.timeline_start = new_start
                end
            else
                shift_rat = new_start - original_start_rat
                clip.timeline_start = new_start
            end
            ripple_time = original_start_rat -- shift co-timed clips on other tracks as well
        elseif edge_info.edge_type == "gap_after" then
            -- Shift downstream clips relative to the trailing gap after this clip
            shift_rat = delta_rat * -1
            ripple_time = original_end_rat
        else
            local _, apply_ok, apply_deleted = apply_edge_ripple(clip, edge_info.edge_type, delta_rat)
            success = apply_ok
            deleted_clip = apply_deleted
            if not success then
                 return {success = false, error_message = "Ripple operation failed"}
            end
            local new_end_rat = clip.timeline_start + clip.duration
            shift_rat = new_end_rat - original_end_rat
            ripple_time = original_end_rat
        end
        
        if shift_rat.frames == 0 and not deleted_clip
            and clip.timeline_start == original_start_rat
            and clip.duration == original_duration_rat then
            command:set_parameter("__suppress_if_unchanged", true)
            command:set_parameter("__skip_selection_snapshot", true)
            return {success = true}
        end

        if not dry_run then
            print(string.format("RippleEdit: edge=%s, delta=%s, shift=%s",
                edge_info.edge_type, tostring(delta_rat), tostring(shift_rat)))
        end

        if deleted_clip and not is_gap_clip then
            table.insert(deleted_clip_ids, clip.id)
        end

        local excluded_ids = {[clip.id] = true}
        local clips_to_shift = collect_downstream_clips(all_clips, excluded_ids, ripple_time)

        if shift_rat.frames < 0 and clips_to_shift and #clips_to_shift > 0 and edge_info.edge_type == "gap_before" then
            local max_allowed = shift_rat.frames
            local trimmed_end = clip.timeline_start + clip.duration
            for _, target in ipairs(clips_to_shift) do
                local prev_end = nil
                for _, other in ipairs(all_clips) do
                    if other.track_id == target.track_id and other.id ~= target.id then
                        local other_end = other.timeline_start + other.duration
                        if other_end <= target.timeline_start and (not prev_end or other_end > prev_end) then
                            prev_end = other_end
                        end
                    end
                end
                local baseline = prev_end or Rational.new(0, seq_fps_num, seq_fps_den)
                local available = target.timeline_start - baseline
                local allowed = -(available.frames or 0)
                if allowed > max_allowed then
                    max_allowed = allowed
                end
            end
            if max_allowed > shift_rat.frames then
                shift_rat = Rational.new(max_allowed, seq_fps_num, seq_fps_den)
            end
        end

        if dry_run then
            local clamped_edges = {}
            if clamped_delta and clamped_delta.frames and requested_delta_frames and clamped_delta.frames ~= requested_delta_frames then
                local key = string.format("%s:%s", tostring(edge_info.clip_id or ""), tostring(edge_info.edge_type or ""))
                clamped_edges[key] = true
            end
            local preview_shifts = {}
            for _, downstream_clip in ipairs(clips_to_shift or {}) do
                local start_val = downstream_clip.timeline_start or downstream_clip.start_time
                local new_start = start_val + shift_rat
                table.insert(preview_shifts, {
                    clip_id = downstream_clip.id,
                    new_start_value = new_start,
                    new_start_time = new_start
                })
            end
            return true, {
                clamped_delta_ms = delta_rat.frames * 1000 / (seq_fps_num/seq_fps_den),
                affected_clip = {
                    clip_id = clip.id,
                    new_start_value = clip.timeline_start,
                    new_start_time = clip.timeline_start,
                    new_duration = clip.duration,
                    edge_type = edge_info.edge_type,
                    raw_edge_type = edge_info.edge_type,
                    is_gap = (edge_info.edge_type == "gap_before" or edge_info.edge_type == "gap_after")
                },
                shifted_clips = preview_shifts,
                clamped_edges = clamped_edges
            }
        end

        local function save_trimmed_clip()
            if not is_gap_clip then
                if deleted_clip then
                    if not clip:delete(db) then
                        print(string.format("ERROR: RippleEdit: Failed to delete clip %s", edge_info.clip_id:sub(1,8)))
                        return false
                    end
                    command_helper.add_delete_mutation(command, sequence_id, clip.id)
                else
                    local save_opts = nil
                    local ok, actions = clip:save(db, save_opts)
                    if not ok then
                        print(string.format("ERROR: RippleEdit: Failed to save clip %s", edge_info.clip_id:sub(1,8)))
                        return false
                    end
                    append_actions(occlusion_actions, actions)
                    local update_payload = command_helper.clip_update_payload(clip, sequence_id)
                    if update_payload then
                        command_helper.add_update_mutation(command, update_payload.track_sequence_id or sequence_id, update_payload)
                    end
                    post_states[#post_states + 1] = command_helper.capture_clip_state(clip)
                end
            end
            return true
        end

        local function shift_downstream()
            for _, downstream_clip in ipairs(clips_to_shift) do
                local shift_clip = Clip.load(downstream_clip.id, db)
                if shift_clip then
                    shift_clip.timeline_start = shift_clip.timeline_start + shift_rat
                    local save_opts = nil 
                    local ok, actions = shift_clip:save(db, save_opts)
                    if ok then
                        append_actions(occlusion_actions, actions)
                        local update_payload = command_helper.clip_update_payload(shift_clip, sequence_id)
                        if update_payload then
                            command_helper.add_update_mutation(command, update_payload.track_sequence_id or sequence_id, update_payload)
                        end
                        post_states[#post_states + 1] = command_helper.capture_clip_state(shift_clip)
                    else
                        print(string.format("ERROR: RippleEdit: Failed to shift clip %s", shift_clip.id:sub(1,8)))
                        return false
                    end
                end
            end
            return true
        end

        local success_op = true
        if shift_rat > Rational.new(0, 1, 1) then
            if not shift_downstream() then return {success = false} end
            if not save_trimmed_clip() then return {success = false} end
        else
            if not save_trimmed_clip() then return {success = false} end
            if not shift_downstream() then return {success = false} end
        end

        if occlusion_actions and #occlusion_actions > 0 then
            record_occlusion_actions(command, sequence_id, occlusion_actions)
        end
        
        command:set_parameter("ripple_shift_amount_rat", shift_rat)
        command:set_parameter("ripple_post_states", post_states)
        command:set_parameter("ripple_deleted_clips", deleted_clip_ids)
        if original_clip_state then
            command:set_parameter("ripple_original_clip_state", original_clip_state)
        end

        print(string.format("✅ Ripple edit complete: delta=%s, shifted=%d", tostring(shift_rat), #clips_to_shift))
        return true
    end

    command_undoers["RippleEdit"] = function(command)
        print("Undoing RippleEdit command")
        local sequence_id = command:get_parameter("sequence_id") or command_helper.resolve_sequence_for_track(nil, command:get_parameter("edge_info").track_id)
        
        local post_states = command:get_parameter("ripple_post_states")
        local original_clip_state = command:get_parameter("ripple_original_clip_state")
        local shift_rat = command:get_parameter("ripple_shift_amount_rat")
        
        if type(shift_rat) == "table" and shift_rat.frames and (not getmetatable(shift_rat) or not getmetatable(shift_rat).__lt) then
             shift_rat = Rational.new(shift_rat.frames, shift_rat.fps_numerator, shift_rat.fps_denominator)
        end
        
        local function restore_target()
            if original_clip_state then
                local restored = command_helper.restore_clip_state(original_clip_state)
                if restored then
                    local ok, err = restored:save(db, {skip_occlusion = true}) 
                    if not ok then
                         print("ERROR: UndoRippleEdit: restore_target failed: " .. (err or "unknown"))
                    end
                    
                    local payload = command_helper.clip_update_payload(restored, sequence_id)
                    if payload then
                        command_helper.add_update_mutation(command, payload.track_sequence_id or sequence_id, payload)
                    end
                end
            end
        end
        
        local function reverse_shift()
            if post_states then
                for _, state in ipairs(post_states) do
                    if not original_clip_state or state.id ~= original_clip_state.id then
                        local clip = Clip.load_optional(state.id, db)
                        if clip then
                            clip.timeline_start = clip.timeline_start - shift_rat
                            
                            clip:save(db, {skip_occlusion = true})
                            local payload = command_helper.clip_update_payload(clip, sequence_id)
                            if payload then
                                command_helper.add_update_mutation(command, payload.track_sequence_id or sequence_id, payload)
                            end
                        end
                    end
                end
            end
        end
        
        if shift_rat > Rational.new(0, 1, 1) then
            restore_target()
            reverse_shift()
        else
            reverse_shift()
            restore_target()
        end

        print("✅ Undo RippleEdit: Reverted timeline shift")
        return true
    end
    
    command_executors["UndoRippleEdit"] = command_undoers["RippleEdit"]

    return {
        executor = command_executors["RippleEdit"],
        undoer = command_undoers["RippleEdit"]
    }
end

return M
