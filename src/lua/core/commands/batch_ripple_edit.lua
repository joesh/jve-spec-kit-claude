local M = {}
local Clip = require('models.clip')
local database = require('core.database')
local frame_utils = require('core.frame_utils')
local command_helper = require("core.command_helper")
local Rational = require("core.rational")
local timeline_state
do
    local status, mod = pcall(require, 'ui.timeline.timeline_state')
    if status then timeline_state = mod end
end
local clip_mutator = require('core.clip_mutator') -- New dependency

local function compute_neighbor_bounds(all_clips, original_state, clip_id)
    if not original_state or not original_state.track_id then
        return nil, nil
    end
    local track_id = original_state.track_id
    local start_value = original_state.timeline_start
    local duration_value = original_state.duration
    if not start_value or not duration_value then
        return nil, nil
    end
    local clip_end = start_value + duration_value
    local prev_end = nil
    local next_start = nil
    for _, other in ipairs(all_clips or {}) do
        if other.id ~= clip_id and other.track_id == track_id then
            local other_start = other.timeline_start
            local other_end = other.timeline_start + other.duration
            if other_end <= start_value then
                if not prev_end or other_end > prev_end then
                    prev_end = other_end
                end
            end
            if other_start >= clip_end then
                if not next_start or other_start < next_start then
                    next_start = other_start
                end
            end
        end
    end
    return prev_end, next_start
end

function M.register(command_executors, command_undoers, db, set_last_error)
    local function apply_edge_ripple(clip, edge_type, delta_rat)
        -- Strict V5: Expect Rational
        if type(clip.duration) ~= "table" or not clip.duration.frames then
            error("apply_edge_ripple: Clip missing Rational duration.")
        end
        
        local new_duration_timeline = clip.duration
        local new_source_in = clip.source_in
        
        print(string.format("DEBUG: apply_edge_ripple: clip.duration=%s (type %s), delta_rat=%s (type %s), clip.source_in=%s (type %s)",
            tostring(clip.duration), type(clip.duration),
            tostring(delta_rat), type(delta_rat),
            tostring(clip.source_in), type(clip.source_in)))

        if edge_type == "in" then
            -- Ripple in: shorten duration, advance source_in, advance start
            new_duration_timeline = clip.duration - delta_rat
            new_source_in = clip.source_in + delta_rat
            clip.timeline_start = clip.timeline_start + delta_rat
        elseif edge_type == "out" then
            -- Ripple out: change duration
            new_duration_timeline = clip.duration + delta_rat
        elseif edge_type == "gap_before" then
            -- Ripple gap before clip: shifts the clip start time (and thus shifts the clip)
            clip.timeline_start = clip.timeline_start + delta_rat
        else
            error(string.format("apply_edge_ripple: Unsupported edge_type '%s'", edge_type))
        end

        if new_duration_timeline.frames < 1 then 
            return nil, false, true -- Too short/deleted
        end
        
        clip.duration = new_duration_timeline
        clip.source_in = new_source_in
        clip.source_out = clip.source_in + clip.duration -- Re-calculate source_out
        
        return clip.timeline_start, true, false
    end

    command_executors["BatchRippleEdit"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing BatchRippleEdit command")
        end

        local edge_infos_raw = command:get_parameter("edge_infos")
        local edge_infos = {}
        if edge_infos_raw then
            for _, edge in ipairs(edge_infos_raw) do
                local cleaned_id = edge.clip_id
                if type(cleaned_id) == "string" and cleaned_id:find("^temp_gap_") then
                    cleaned_id = cleaned_id:gsub("^temp_gap_", "")
                end
                edge_infos[#edge_infos + 1] = {
                    clip_id = cleaned_id,
                    edge_type = edge.edge_type,
                    track_id = edge.track_id,
                    trim_type = edge.trim_type,
                    type = edge.type
                }
            end
        end
        
        local delta_frames = command:get_parameter("delta_frames")
        local delta_ms = command:get_parameter("delta_ms")
        
        local primary_edge = edge_infos and edge_infos[1] or nil
        local sequence_id = command_helper.resolve_sequence_id_for_edges(command, primary_edge, edge_infos)

        if not edge_infos or #edge_infos == 0 or (not delta_frames and not delta_ms) then
            print("ERROR: BatchRippleEdit missing parameters")
            return false
        end

        -- Resolve Sequence Rate
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
        
        local delta_rat
        if delta_frames then
            delta_rat = Rational.new(delta_frames, seq_fps_num, seq_fps_den)
        elseif delta_ms then
            if type(delta_ms) == "number" then
                error("BatchRippleEdit: delta_ms must be Rational, not number")
            end
            if getmetatable(delta_ms) == Rational.metatable then
                delta_rat = delta_ms:rescale(seq_fps_num, seq_fps_den)
            elseif type(delta_ms) == "table" and delta_ms.frames then
                delta_rat = Rational.new(delta_ms.frames, delta_ms.fps_numerator or seq_fps_num, delta_ms.fps_denominator or seq_fps_den)
            else
                error("BatchRippleEdit: delta_ms must be Rational-like")
            end
        end
        if not delta_rat or not delta_rat.frames then
            return false
        end

        command:set_parameter("edge_infos", edge_infos)

        local original_states_map = {} -- Stores original clip states before modification
        local planned_mutations = {} -- Collect all mutations here
        local preview_affected_clips = {}
        local preview_shifted_clips = {}
        local neighbor_bounds_cache = {}
        local preloaded_clips = {}
        local global_min_frames = -math.huge
        local global_max_frames = math.huge
        
        -- Load all clips on sequence for downstream calculation
        local all_clips = database.load_clips(sequence_id)
        local clamped_delta_rat = delta_rat

        if delta_rat < Rational.new(0, seq_fps_num, seq_fps_den) then
            local min_gap = nil
            for _, edge_info in ipairs(edge_infos) do
                if edge_info.edge_type == "gap_before" then
                    local clip = Clip.load_optional(edge_info.clip_id, db)
                    if clip then
                        local closest_end = nil
                        for _, other in ipairs(all_clips) do
                            if other.track_id == clip.track_id and other.id ~= clip.id then
                                local other_end = other.timeline_start + other.duration
                                if other_end <= clip.timeline_start and (not closest_end or other_end > closest_end) then
                                    closest_end = other_end
                                end
                            end
                        end
                        local gap = clip.timeline_start
                        if closest_end then
                            gap = clip.timeline_start - closest_end
                        end
                        if not min_gap or gap < min_gap then
                            min_gap = gap
                        end
                    end
                end
            end

            if min_gap then
                local max_close = Rational.new(-min_gap.frames, min_gap.fps_numerator, min_gap.fps_denominator)
                if delta_rat < max_close then
                    clamped_delta_rat = max_close
                end
            end
        end
        -- Prepopulate original states and neighbor bounds to constrain delta frames
        for _, edge_info in ipairs(edge_infos) do
            local clip_id = edge_info.clip_id
            local clip = preloaded_clips[clip_id]
            if not clip then
                clip = Clip.load_optional(clip_id, db)
                preloaded_clips[clip_id] = clip
            end
            if clip then
                if not original_states_map[clip_id] then
                    original_states_map[clip_id] = command_helper.capture_clip_state(clip)
                end
                if not neighbor_bounds_cache[clip_id] then
                    local prev_bound, next_bound = compute_neighbor_bounds(all_clips, original_states_map[clip_id], clip_id)
                    neighbor_bounds_cache[clip_id] = {prev = prev_bound, next = next_bound}
                end
                local original = original_states_map[clip_id]
                local treat_start = (edge_info.edge_type == "in" or edge_info.edge_type == "gap_before")
                local treat_end = (edge_info.edge_type == "out" or edge_info.edge_type == "gap_after")
                if treat_start and neighbor_bounds_cache[clip_id].prev then
                    local delta_min = (neighbor_bounds_cache[clip_id].prev - original.timeline_start).frames
                    if delta_min > global_min_frames then
                        global_min_frames = delta_min
                    end
                end
                if treat_end and neighbor_bounds_cache[clip_id].next then
                    local delta_max = (neighbor_bounds_cache[clip_id].next - (original.timeline_start + original.duration)).frames
                    if delta_max < global_max_frames then
                        global_max_frames = delta_max
                    end
                end
            end
        end

        -- Determine earliest ripple point from original states
        local earliest_ripple_hint = nil
        for _, edge_info in ipairs(edge_infos) do
            local original = original_states_map[edge_info.clip_id]
            if original then
                local point = original.timeline_start
                if edge_info.edge_type == "out" then
                    point = original.timeline_start + original.duration
                end
                if not earliest_ripple_hint or point < earliest_ripple_hint then
                    earliest_ripple_hint = point
                end
            end
        end

        -- Clamp delta further so downstream shift cannot overlap other tracks
        if earliest_ripple_hint then
            for _, clip in ipairs(all_clips or {}) do
                if clip.id and clip.timeline_start and clip.timeline_start >= earliest_ripple_hint then
                    local original = command_helper.capture_clip_state(clip)
                    local prev_bound, next_bound = compute_neighbor_bounds(all_clips, original, clip.id)
                    if prev_bound then
                        local delta_min = (prev_bound - clip.timeline_start).frames
                        if delta_min > global_min_frames then
                            global_min_frames = delta_min
                        end
                    end
                    if next_bound then
                        local delta_max = (next_bound - (clip.timeline_start + clip.duration)).frames
                        if delta_max < global_max_frames then
                            global_max_frames = delta_max
                        end
                    end
                end
            end
        end

        local delta_frames = clamped_delta_rat.frames
        if global_min_frames ~= -math.huge and global_max_frames ~= math.huge and global_min_frames > global_max_frames then
            delta_frames = 0
        else
            if global_min_frames ~= -math.huge and delta_frames < global_min_frames then
                delta_frames = global_min_frames
            end
            if global_max_frames ~= math.huge and delta_frames > global_max_frames then
                delta_frames = global_max_frames
            end
        end
        clamped_delta_rat = Rational.new(delta_frames, seq_fps_num, seq_fps_den)
        local clamped_delta_ms = (delta_frames * 1000) / (seq_fps_num / seq_fps_den)
        command:set_parameter("clamped_delta_ms", clamped_delta_ms)
        local earliest_ripple_time = nil -- Rational
        
        -- Tracking for net ripple amount (downstream shift)
        local max_original_end_time = Rational.new(-1, seq_fps_num, seq_fps_den)
        local max_new_end_time = Rational.new(-1, seq_fps_num, seq_fps_den)
        local downstream_shift_rat = Rational.new(0, seq_fps_num, seq_fps_den)
        local found_valid_end_shift = false
        
        local modified_clips = {} -- Map id -> clip object (modified)
        local clips_marked_delete = {} -- Set of ids

        -- Step 1: Process Edges (Trim/Extend)
        for _, edge_info in ipairs(edge_infos) do
            local clip_id = edge_info.clip_id
            
            -- Get or load clip
            local clip = modified_clips[clip_id]
            if not clip then
                clip = preloaded_clips[clip_id]
            end
            if not clip then
                clip = Clip.load_optional(clip_id, db)
                if not clip then
                    print(string.format("WARNING: BatchRippleEdit: Clip %s not found. Skipping.", clip_id:sub(1,8)))
                    goto continue_edge
                end
                -- First time seeing this clip, capture original
                if not original_states_map[clip_id] then
                    original_states_map[clip_id] = command_helper.capture_clip_state(clip)
                end
                modified_clips[clip_id] = clip
            end
            
            if clips_marked_delete[clip_id] then
                goto continue_edge
            end

            local original = original_states_map[clip_id]
            local original_end = original.timeline_start + original.duration

            local ripple_start, success, deleted_clip = apply_edge_ripple(clip, edge_info.edge_type, clamped_delta_rat)
            if not success then
                print(string.format("ERROR: Ripple failed for clip %s", clip.id:sub(1,8)))
                return false
            end

            if dry_run then
                local preview_clip_id = clip.id
                if type(preview_clip_id) == "string" and preview_clip_id:find("^temp_gap_") then
                    preview_clip_id = edge_info.clip_id
                end
                table.insert(preview_affected_clips, {
                    clip_id = preview_clip_id,
                    new_start_value = clip.timeline_start,
                    new_duration = clip.duration,
                    edge_type = edge_info.edge_type
                })
            end

            if deleted_clip then
                clips_marked_delete[clip_id] = true
            end
            
            -- Determine earliest ripple time (start of the edited range)
            local ripple_point = clip.timeline_start
            if edge_info.edge_type == "out" then
                -- For Out trim, ripple point is original end
                ripple_point = original.timeline_start + original.duration 
            end
            if edge_info.edge_type == "in" then
                ripple_point = original.timeline_start
            end

            if not earliest_ripple_time or ripple_point < earliest_ripple_time then
                earliest_ripple_time = ripple_point
            end
            
            -- Track the rightmost edited boundary
            local new_end = clip.timeline_start + clip.duration
            if original_end > max_original_end_time then
                max_original_end_time = original_end
                max_new_end_time = new_end
                found_valid_end_shift = true
            elseif original_end == max_original_end_time then
                if new_end > max_new_end_time then
                    max_new_end_time = new_end
                end
            end

            if dry_run then
                local preview_clip_id = clip.id
                if type(preview_clip_id) == "string" and preview_clip_id:find("^temp_gap_") then
                    preview_clip_id = edge_info.clip_id
                end
                table.insert(preview_affected_clips, {
                    clip_id = preview_clip_id,
                    new_start_value = clip.timeline_start,
                    new_duration = clip.duration,
                    edge_type = edge_info.edge_type
                })
            end

            ::continue_edge::
        end

        if not earliest_ripple_time then
            earliest_ripple_time = Rational.new(0, seq_fps_num, seq_fps_den)
        end
        
        if found_valid_end_shift then
             downstream_shift_rat = max_new_end_time - max_original_end_time
        else
             downstream_shift_rat = Rational.new(0, seq_fps_num, seq_fps_den)
        end
        
        -- Step 2: Identify Downstream Clips and Plan Shifts
        local edited_lookup = {}
        for id, _ in pairs(modified_clips) do edited_lookup[id] = true end

        local clips_to_shift = {}
        
        for _, other_clip in ipairs(all_clips) do
            if not edited_lookup[other_clip.id] and other_clip.timeline_start >= earliest_ripple_time then
                table.insert(clips_to_shift, other_clip)
            end
        end

        -- Sort clips to shift by timeline_start to maintain order
        table.sort(clips_to_shift, function(a, b) return a.timeline_start < b.timeline_start end)

        for _, shift_clip_data in ipairs(clips_to_shift) do
            local shift_clip = Clip.load_optional(shift_clip_data.id, db)
            if not shift_clip then
                print(string.format("WARNING: BatchRippleEdit: Downstream clip %s not found. Skipping shift.", shift_clip_data.id:sub(1,8)))
                goto continue_shift_plan
            end
            
            if not original_states_map[shift_clip.id] then
                original_states_map[shift_clip.id] = command_helper.capture_clip_state(shift_clip)
            end
            
            shift_clip.timeline_start = shift_clip.timeline_start + downstream_shift_rat
            modified_clips[shift_clip.id] = shift_clip

            ::continue_shift_plan::
        end

        local function compute_shift_bounds()
            local min_frames = -math.huge
            local max_frames = math.huge
            for _, shift_clip_data in ipairs(clips_to_shift) do
                local original = {
                    timeline_start = shift_clip_data.timeline_start,
                    duration = shift_clip_data.duration,
                    track_id = shift_clip_data.track_id
                }
                local prev_bound, next_bound = compute_neighbor_bounds(all_clips, original, shift_clip_data.id)
                if prev_bound then
                    local bound = (prev_bound - original.timeline_start).frames
                    if bound > min_frames then min_frames = bound end
                end
                if next_bound then
                    local bound = (next_bound - (original.timeline_start + original.duration)).frames
                    if bound < max_frames then max_frames = bound end
                end
            end
            return min_frames, max_frames
        end

        local min_shift_frames, max_shift_frames = compute_shift_bounds()
        local desired_shift_frames = downstream_shift_rat.frames
        local adjusted_frames = desired_shift_frames
        if min_shift_frames ~= -math.huge and desired_shift_frames < min_shift_frames then
            adjusted_frames = min_shift_frames
        end
        if max_shift_frames ~= math.huge and desired_shift_frames > max_shift_frames then
            adjusted_frames = max_shift_frames
        end
        if adjusted_frames ~= desired_shift_frames then
            local retry_count = command:get_parameter("__retry_delta_count") or 0
            if retry_count > 5 then
                return false, "Failed to clamp ripple delta without overlap (retry limit)"
            end
            command:set_parameter("__retry_delta_count", retry_count + 1)
            command:set_parameter("delta_frames", adjusted_frames)
            command:set_parameter("delta_ms", nil)
            command:set_parameter("clamped_delta_ms", (adjusted_frames * 1000) / (seq_fps_num / seq_fps_den))
            return command_executors["BatchRippleEdit"](command)
        end

        -- Generate Planned Mutations
        for id, clip in pairs(modified_clips) do
            local original = original_states_map[id]
            if clips_marked_delete[id] then
                table.insert(planned_mutations, clip_mutator.plan_delete(original))
            else
                table.insert(planned_mutations, clip_mutator.plan_update(clip, original))
            end
        end

        -- Sort mutations to prevent transient overlaps during updates
        local is_positive_delta = clamped_delta_rat.frames > 0
        
        table.sort(planned_mutations, function(a, b)
            if a.type == "delete" and b.type ~= "delete" then return true end
            if b.type == "delete" and a.type ~= "delete" then return false end
            
            local t_a = a.timeline_start_frame or 0
            local t_b = b.timeline_start_frame or 0
            
            if is_positive_delta then
                return t_a > t_b
            else
                return t_a < t_b
            end
        end)

        if dry_run then
            preview_shifted_clips = {}
            for _, shift_clip in ipairs(clips_to_shift or {}) do
                local new_start = shift_clip.timeline_start + downstream_shift_rat
                table.insert(preview_shifted_clips, {
                    clip_id = shift_clip.id,
                    new_start_value = new_start
                })
            end
        end

        command:set_parameter("original_states", original_states_map)
        command:set_parameter("executed_mutations", planned_mutations)

        if dry_run then
            return true, {
                planned_mutations = planned_mutations,
                affected_clips = preview_affected_clips,
                shifted_clips = preview_shifted_clips,
                clamped_delta_ms = clamped_delta_ms
            }
        end

        -- Step 3: Execute all Planned Mutations (Transaction handled by CommandManager)
        local ok_apply, apply_err = command_helper.apply_mutations(db, planned_mutations)
        if not ok_apply then
            return false, "Failed to apply mutations: " .. tostring(apply_err)
        end
        
        print(string.format("✅ Batch ripple: processed %d edges, shifted %d downstream clips by %s",
            #edge_infos, #clips_to_shift, tostring(downstream_shift_rat)))

        return true
    end

    command_undoers["BatchRippleEdit"] = function(command)
        print("Undoing BatchRippleEdit command")

        local executed_mutations = command:get_parameter("executed_mutations") or {}
        local sequence_id = command:get_parameter("sequence_id")
        
        if not executed_mutations or #executed_mutations == 0 then
            print("WARNING: UndoBatchRippleEdit: No executed mutations to undo.")
            return false
        end

        local started, begin_err = db:begin_transaction()
        if not started then
            print("ERROR: UndoBatchRippleEdit: Failed to begin transaction: " .. tostring(begin_err))
            return false
        end

        local ok, err = command_helper.revert_mutations(db, executed_mutations, command, sequence_id)
        if not ok then
            db:rollback_transaction(started)
            print("ERROR: UndoBatchRippleEdit: Failed to revert mutations: " .. tostring(err))
            return false
        end
        
        local ok_commit, commit_err = db:commit_transaction(started)
        if not ok_commit then
            db:rollback_transaction(started)
            return false, "Failed to commit undo transaction: " .. tostring(commit_err)
        end

        print("✅ Undo Batch ripple: Reverted all changes")
        return true
    end

    command_executors["UndoBatchRippleEdit"] = command_undoers["BatchRippleEdit"]

    return {
        executor = command_executors["BatchRippleEdit"],
        undoer = command_undoers["BatchRippleEdit"]
    }
end

return M
