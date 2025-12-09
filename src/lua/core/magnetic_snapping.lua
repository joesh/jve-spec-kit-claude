-- Magnetic snapping: Find snap points for clip edges and playhead
-- Provides snap detection logic for drag operations in the timeline

local time_utils = require("core.time_utils")
local Rational = require("core.rational")

local M = {}

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
                if getmetatable(clip.timeline_start) ~= Rational.metatable then
                    error("magnetic_snapping: Clip timeline_start must be a Rational object", 2)
                end

                table.insert(snap_points, {
                    time = clip.timeline_start,
                    type = "clip_edge",
                    edge = "in",
                    clip_id = clip.id,
                    description = string.format("Clip %s in-point", clip.id:sub(1, 8))
                })
            end

            -- Out-point (right edge)
            local out_key = clip.id .. "_out"
            if not excluded_edges_lookup[out_key] then
                if getmetatable(clip.timeline_start) ~= Rational.metatable or getmetatable(clip.duration) ~= Rational.metatable then
                    error("magnetic_snapping: Clip time values must be Rational objects", 2)
                end
                local clip_out_time = clip.timeline_start + clip.duration

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

-- Find the closest snap point to a given pixel position within pixel tolerance
-- Returns {time, type, description} or nil if no snap point within tolerance
function M.find_closest_snap(state, target_time, excluded_clip_ids, excluded_edge_specs, viewport_width_px)
    local SNAP_TOLERANCE_PX = 12  -- Pixels within which to snap

    local snap_points = M.find_snap_points(state, excluded_clip_ids, excluded_edge_specs)

    local target_px = state.time_to_pixel(target_time, viewport_width_px)

    local closest_snap = nil
    local closest_distance_px = math.huge

    for _, snap_point in ipairs(snap_points) do
        -- Ensure snap_point.time is also a Rational object
        if getmetatable(snap_point.time) ~= Rational.metatable then
            error("magnetic_snapping: Snap point time must be a Rational object", 2)
        end

        -- Calculate pixel distance
        local snap_point_px = state.time_to_pixel(snap_point.time, viewport_width_px)
        local distance_px = math.abs(snap_point_px - target_px)

        if distance_px < closest_distance_px and distance_px <= SNAP_TOLERANCE_PX then
            closest_snap = snap_point
            closest_distance_px = distance_px
        end
    end

    return closest_snap, closest_distance_px
end

-- Apply snapping to a time value if enabled
-- Returns adjusted time and snap info {snapped: boolean, snap_point: {...} or nil}
function M.apply_snap(state, target_time, is_snapping_enabled, excluded_clip_ids, excluded_edge_specs, viewport_width_px)
    if not is_snapping_enabled then
        return target_time, {snapped = false, snap_point = nil}
    end

    local snap_point, distance_px = M.find_closest_snap(state, target_time, excluded_clip_ids, excluded_edge_specs, viewport_width_px)

    if snap_point then
        -- Convert Rational times to milliseconds for printing only
        local target_ms = time_utils.to_milliseconds(target_time)
        local snap_ms = time_utils.to_milliseconds(snap_point.time)

        print(string.format("SNAP: target=%.2fms → snapped to %.2fms (%s) [distance=%.1fpx]",
            target_ms, snap_ms, snap_point.description, distance_px))
        return snap_point.time, {snapped = true, snap_point = snap_point, distance_px = distance_px}
    else
        return target_time, {snapped = false, snap_point = nil}
    end
end

return M
