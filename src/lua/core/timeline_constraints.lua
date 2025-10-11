-- Timeline Constraints: Collision detection and range calculation for timeline operations
-- Provides constraint checking for moves, trims, and other timeline operations

local M = {}

-- Calculate the valid range for moving a clip
-- Returns: {min_time, max_time, blocking_clips_left, blocking_clips_right}
function M.calculate_move_range(clip_id, track_id, all_clips)
    local clip = nil
    for _, c in ipairs(all_clips) do
        if c.id == clip_id then
            clip = c
            break
        end
    end

    if not clip then
        return nil, "Clip not found"
    end

    -- Find adjacent clips on the target track
    local left_boundary = 0  -- Earliest allowed start time
    local right_boundary = math.huge  -- Latest allowed start time
    local blocking_left = nil
    local blocking_right = nil

    for _, other in ipairs(all_clips) do
        if other.id ~= clip_id and other.track_id == track_id then
            local other_end = other.start_time + other.duration

            -- Clip to our left
            if other_end <= clip.start_time then
                if other_end > left_boundary then
                    left_boundary = other_end
                    blocking_left = other
                end
            end

            -- Clip to our right
            if other.start_time >= clip.start_time + clip.duration then
                if other.start_time < right_boundary then
                    right_boundary = other.start_time
                    blocking_right = other
                end
            end
        end
    end

    -- Convert track boundary to time boundary (considering clip duration)
    local min_time = left_boundary
    local max_time = right_boundary - clip.duration

    return {
        min_time = min_time,
        max_time = max_time,
        blocking_left = blocking_left,
        blocking_right = blocking_right
    }
end

-- Calculate the valid range for trimming an edge
-- edge_type: "in" or "out"
-- check_all_tracks: if true, check collisions on all tracks (for ripple edits)
-- Returns: {min_delta, max_delta, limit_reason}
function M.calculate_trim_range(clip, edge_type, all_clips, check_all_tracks)
    local min_delta = -math.huge
    local max_delta = math.huge
    local limit_left = nil  -- What's limiting us on the left
    local limit_right = nil  -- What's limiting us on the right

    -- CONSTRAINT 1: Minimum clip duration (must be at least 1ms)
    if edge_type == "in" then
        -- Trimming in-point: can't make duration < 1
        max_delta = clip.duration - 1  -- Drag right max
        min_delta = -math.huge  -- Drag left limited by media/adjacent clip
    else  -- edge_type == "out"
        -- Trimming out-point: can't make duration < 1
        min_delta = -(clip.duration - 1)  -- Drag left max
        max_delta = math.huge  -- Drag right limited by media/adjacent clip
    end

    -- CONSTRAINT 2: Media boundaries (can't trim beyond available media)
    if clip.source_in ~= nil then  -- Real clip with media
        if edge_type == "in" then
            -- Can't drag left beyond source_in = 0
            local media_min = -clip.source_in
            if media_min > min_delta then
                min_delta = media_min
                limit_left = "media_start"
            end
            -- Can't drag right beyond source media end
            -- (This would require knowing media duration - TODO)
        else  -- edge_type == "out"
            -- Can't drag left to reveal media before source_in
            -- (Already constrained by duration minimum)
            -- Can't drag right beyond source media end
            -- (This would require knowing media duration - TODO)
        end
    end

    -- CONSTRAINT 3: Adjacent clips (can't trim into another clip)
    for _, other in ipairs(all_clips) do
        -- For ripple edits: check all tracks. For regular trims: only same track
        local should_check = (check_all_tracks or other.track_id == clip.track_id)
        if other.id ~= clip.id and should_check then
            if edge_type == "in" then
                -- Trimming in-point: check for clip to the left
                local other_end = other.start_time + other.duration
                if other_end <= clip.start_time then
                    -- Clip is to our left
                    local max_drag_left = clip.start_time - other_end
                    if -max_drag_left > min_delta then
                        min_delta = -max_drag_left
                        limit_left = other
                    end
                end
            else  -- edge_type == "out"
                -- Trimming out-point: check for clip to the right
                local clip_end = clip.start_time + clip.duration
                if other.start_time >= clip_end then
                    -- Clip is to our right
                    local max_drag_right = other.start_time - clip_end
                    if max_drag_right < max_delta then
                        max_delta = max_drag_right
                        limit_right = other
                    end
                end
            end
        end
    end

    -- CONSTRAINT 4: Timeline start (can't move clip start before t=0)
    if edge_type == "in" then
        local max_drag_left = clip.start_time  -- Can't go before 0
        if -max_drag_left > min_delta then
            min_delta = -max_drag_left
            limit_left = "timeline_start"
        end
    end

    return {
        min_delta = min_delta,
        max_delta = max_delta,
        limit_left = limit_left,
        limit_right = limit_right
    }
end

-- Check if a clip move would cause a collision
-- Returns: collision_info or nil
function M.check_move_collision(clip, new_start_time, new_track_id, all_clips)
    local new_end = new_start_time + clip.duration

    -- Check timeline boundaries
    if new_start_time < 0 then
        return {
            type = "timeline_start",
            message = "Cannot move clip before timeline start"
        }
    end

    -- Check for overlaps with other clips
    for _, other in ipairs(all_clips) do
        if other.id ~= clip.id and other.track_id == new_track_id then
            local other_end = other.start_time + other.duration

            -- Check for overlap
            if new_start_time < other_end and new_end > other.start_time then
                return {
                    type = "clip_overlap",
                    other_clip = other,
                    message = string.format("Overlaps with clip at %dms", other.start_time)
                }
            end
        end
    end

    return nil  -- No collision
end

-- Check if a trim operation would cause a collision or violate constraints
-- Returns: collision_info or nil
function M.check_trim_collision(clip, edge_type, delta_ms, all_clips)
    local constraints = M.calculate_trim_range(clip, edge_type, all_clips)

    if delta_ms < constraints.min_delta then
        return {
            type = "constraint_violation",
            limit = constraints.limit_left,
            message = string.format("Cannot trim %dms (max %dms)",
                delta_ms, constraints.min_delta)
        }
    end

    if delta_ms > constraints.max_delta then
        return {
            type = "constraint_violation",
            limit = constraints.limit_right,
            message = string.format("Cannot trim %dms (max %dms)",
                delta_ms, constraints.max_delta)
        }
    end

    return nil  -- No collision
end

-- Clamp a drag delta to valid range and snap to frame boundaries
function M.clamp_trim_delta(clip, edge_type, delta_ms, all_clips, frame_rate, check_all_tracks)
    local constraints = M.calculate_trim_range(clip, edge_type, all_clips, check_all_tracks)
    local clamped = math.max(constraints.min_delta, math.min(constraints.max_delta, delta_ms))

    -- Snap to frame boundaries if frame_rate is provided
    if frame_rate then
        local frame_utils = require('core.frame_utils')
        clamped = frame_utils.snap_delta_to_frame(clamped, frame_rate)

        -- Ensure snapped delta is still within constraints
        -- If snapping pushed us out of bounds, try snapping the other direction
        if clamped > constraints.max_delta then
            clamped = math.floor(clamped - frame_utils.frame_duration_ms(frame_rate))
        elseif clamped < constraints.min_delta then
            clamped = math.ceil(clamped + frame_utils.frame_duration_ms(frame_rate))
        end
    end

    return clamped
end

-- Clamp a move position to valid range
function M.clamp_move_position(clip_id, track_id, target_time, all_clips)
    local range = M.calculate_move_range(clip_id, track_id, all_clips)
    if not range then
        return target_time
    end
    return math.max(range.min_time, math.min(range.max_time, target_time))
end

-- Handle collision during insert operation
-- mode: "error" | "trim_target" | "delete_target" | "push_forward"
function M.handle_insert_collision(clip, target_start, target_track, mode, all_clips)
    local collision = M.check_move_collision(clip, target_start, target_track, all_clips)

    if not collision then
        return {success = true}
    end

    if mode == "error" then
        return {success = false, error = collision.message}
    end

    -- TODO: Implement trim_target, delete_target, push_forward modes
    return {success = false, error = "Collision handling mode not implemented"}
end

return M
