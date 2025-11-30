-- Magnetic snapping: Find snap points for clip edges and playhead
-- Provides snap detection logic for drag operations in the timeline

local time_utils = require("core.time_utils")
local Rational = require("core.rational")

local M = {}

-- Snap tolerance in milliseconds (typical NLE default: ~6-10 pixels at default zoom)
-- This is adjustable based on zoom level
local DEFAULT_SNAP_TOLERANCE_MS = 100

-- Find all potential snap points in the timeline
-- Returns array of {time, type, description} where type is "clip_edge" or "playhead"
function M.find_snap_points(state, excluded_clip_ids, excluded_edge_specs)
    local snap_points = {}
    excluded_clip_ids = excluded_clip_ids or {}
    excluded_edge_specs = excluded_edge_specs or {}

    -- Create exclusion lookup tables for O(1) checking
    local excluded_clips_lookup = {}
    for _, clip_id in ipairs(excluded_clip_ids) do
        excluded_clips_lookup[clip_id] = true
    end

    local excluded_edges_lookup = {}
    for _, edge_spec in ipairs(excluded_edge_specs) do
        -- edge_type is always "in" or "out" - no normalization needed
        local key = edge_spec.clip_id .. "_" .. edge_spec.edge_type
        excluded_edges_lookup[key] = true
    end

    -- Add playhead position as snap point
    local playhead_time = state.get_playhead_position()
    
    if getmetatable(playhead_time) ~= Rational.metatable then
        error("magnetic_snapping: Playhead value must be a Rational object", 2)
    end
    table.insert(snap_points, {
        time = playhead_time,
        type = "playhead",
        description = "Playhead"
    })

    -- Add all clip edges as snap points (excluding dragged clips/edges)
    for _, clip in ipairs(state.get_clips()) do
        if not excluded_clips_lookup[clip.id] then
            -- In-point (left edge)
            local in_key = clip.id .. "_in"
            if not excluded_edges_lookup[in_key] then
                if getmetatable(clip.timeline_start_frame) ~= Rational.metatable then
                    error("magnetic_snapping: Clip timeline_start_frame must be a Rational object", 2)
                end

                table.insert(snap_points, {
                    time = clip.timeline_start_frame,
                    type = "clip_edge",
                    edge = "in",
                    clip_id = clip.id,
                    description = string.format("Clip %s in-point", clip.id:sub(1, 8))
                })
            end

            -- Out-point (right edge)
            local out_key = clip.id .. "_out"
            if not excluded_edges_lookup[out_key] then
                if getmetatable(clip.timeline_start_frame) ~= Rational.metatable or getmetatable(clip.duration_frames) ~= Rational.metatable then
                    error("magnetic_snapping: Clip time values must be Rational objects", 2)
                end
                local clip_out_time = clip.timeline_start_frame + clip.duration_frames

                table.insert(snap_points, {
                    time = clip_out_time,
                    type = "clip_edge",
                    edge = "out",
                    clip_id = clip.id,
                    description = string.format("Clip %s out-point", clip.id:sub(1, 8))
                })
            end
        end
    end

    return snap_points
end

-- Find the closest snap point to a given time within tolerance
-- Returns {time, type, description} or nil if no snap point within tolerance
function M.find_closest_snap(state, target_time, excluded_clip_ids, excluded_edge_specs, tolerance_ms)
    local sequence_fps_num = state.get_sequence_fps_numerator()
    local sequence_fps_den = state.get_sequence_fps_denominator()

    -- Convert tolerance_ms to a Rational object at the sequence's rate
    local tolerance_rational = time_utils.from_milliseconds(tolerance_ms or DEFAULT_SNAP_TOLERANCE_MS, sequence_fps_num, sequence_fps_den)

    local snap_points = M.find_snap_points(state, excluded_clip_ids, excluded_edge_specs)

    local closest_snap = nil
    local closest_distance_rational = nil -- Initialize to nil instead of math.huge Rational

    for _, snap_point in ipairs(snap_points) do
        -- Ensure snap_point.time is also a Rational object
        if getmetatable(snap_point.time) ~= Rational.metatable then
            error("magnetic_snapping: Snap point time must be a Rational object", 2)
        end
        
        -- Calculate absolute difference using Rational arithmetic
        local difference = time_utils.sub(snap_point.time, target_time)
        -- Rational.new expects integer frames. math.abs on frames is fine.
        local distance_rational = Rational.new(math.abs(difference.frames), difference.fps_numerator, difference.fps_denominator)

        if closest_distance_rational == nil or distance_rational < closest_distance_rational then
            -- Also ensure distance is within tolerance after finding the closest
            if distance_rational <= tolerance_rational then
                closest_snap = snap_point
                closest_distance_rational = distance_rational
            end
        end
    end


    return closest_snap, closest_distance_rational
end

-- Apply snapping to a time value if enabled
-- Returns adjusted time and snap info {snapped: boolean, snap_point: {...} or nil}
function M.apply_snap(state, target_time, is_snapping_enabled, excluded_clip_ids, excluded_edge_specs, tolerance_ms)
    if not is_snapping_enabled then
        return target_time, {snapped = false, snap_point = nil}
    end

    local snap_point, distance_rational = M.find_closest_snap(state, target_time, excluded_clip_ids, excluded_edge_specs, tolerance_ms)

    if snap_point then

        -- Convert Rational times to milliseconds for printing
        local target_ms = time_utils.to_milliseconds(target_time)
        local snap_ms = time_utils.to_milliseconds(snap_point.time)
        local distance_ms = time_utils.to_milliseconds(distance_rational)
        local tolerance_ms_print = tolerance_ms or DEFAULT_SNAP_TOLERANCE_MS

        print(string.format("SNAP: target=%.2fms → snapped to %.2fms (%s) [distance=%.2fms, tolerance=%.2fms]",
            target_ms, snap_ms, snap_point.description, distance_ms, tolerance_ms_print))
        return snap_point.time, {snapped = true, snap_point = snap_point, distance = distance_rational}
    else
        -- Debug: Show why no snap occurred
        -- local target_ms = time_utils.to_milliseconds(target_time)
        -- local tolerance_ms_print = tolerance_ms or DEFAULT_SNAP_TOLERANCE_MS
        -- print(string.format("NO SNAP: target=%.2fms [tolerance=%.2fms, no points within range]", target_time, tolerance_ms_print))
        return target_time, {snapped = false, snap_point = nil}
    end
end

-- Calculate snap tolerance based on zoom level
-- More zoomed in = larger pixel tolerance = smaller time tolerance
function M.calculate_tolerance(state, viewport_duration_rational, viewport_width_px)
    local SNAP_TOLERANCE_PX = 12  -- Pixels within which to snap
    
    local viewport_duration_ms = time_utils.to_milliseconds(viewport_duration_rational)
    local ms_per_pixel = viewport_duration_ms / viewport_width_px
    local tolerance_ms = SNAP_TOLERANCE_PX * ms_per_pixel
    
    local sequence_fps_num = state.get_sequence_fps_numerator()
    local sequence_fps_den = state.get_sequence_fps_denominator()
    return time_utils.from_milliseconds(tolerance_ms, sequence_fps_num, sequence_fps_den)
end

return M
