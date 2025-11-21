-- Magnetic snapping: Find snap points for clip edges and playhead
-- Provides snap detection logic for drag operations in the timeline

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
    table.insert(snap_points, {
        time = state.get_playhead_value(),
        type = "playhead",
        description = "Playhead"
    })

    -- Add all clip edges as snap points (excluding dragged clips/edges)
    for _, clip in ipairs(state.get_clips()) do
        if not excluded_clips_lookup[clip.id] then
            -- In-point (left edge)
            local in_key = clip.id .. "_in"
            if not excluded_edges_lookup[in_key] then
                table.insert(snap_points, {
                    time = clip.start_value,
                    type = "clip_edge",
                    edge = "in",
                    clip_id = clip.id,
                    description = string.format("Clip %s in-point", clip.id:sub(1, 8))
                })
            end

            -- Out-point (right edge)
            local out_key = clip.id .. "_out"
            if not excluded_edges_lookup[out_key] then
                table.insert(snap_points, {
                    time = clip.start_value + clip.duration,
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
    tolerance_ms = tolerance_ms or DEFAULT_SNAP_TOLERANCE_MS

    local snap_points = M.find_snap_points(state, excluded_clip_ids, excluded_edge_specs)

    local closest_snap = nil
    local closest_distance = math.huge

    for _, snap_point in ipairs(snap_points) do
        local distance = math.abs(snap_point.time - target_time)
        if distance <= tolerance_ms and distance < closest_distance then
            closest_snap = snap_point
            closest_distance = distance
        end
    end

    return closest_snap, closest_distance
end

-- Apply snapping to a time value if enabled
-- Returns adjusted time and snap info {snapped: boolean, snap_point: {...} or nil}
function M.apply_snap(state, target_time, is_snapping_enabled, excluded_clip_ids, excluded_edge_specs, tolerance_ms)
    if not is_snapping_enabled then
        return target_time, {snapped = false, snap_point = nil}
    end

    local snap_point, distance = M.find_closest_snap(state, target_time, excluded_clip_ids, excluded_edge_specs, tolerance_ms)

    if snap_point then
        print(string.format("SNAP: target=%dms → snapped to %dms (%s) [distance=%dms, tolerance=%dms]",
            target_time, snap_point.time, snap_point.description, distance, tolerance_ms))
        return snap_point.time, {snapped = true, snap_point = snap_point, distance = distance}
    else
        -- Debug: Show why no snap occurred
        -- print(string.format("NO SNAP: target=%dms [tolerance=%dms, no points within range]", target_time, tolerance_ms))
        return target_time, {snapped = false, snap_point = nil}
    end
end

-- Calculate snap tolerance based on zoom level
-- More zoomed in = larger pixel tolerance = smaller time tolerance
function M.calculate_tolerance(viewport_duration_ms, viewport_width_px)
    local SNAP_TOLERANCE_PX = 12  -- Pixels within which to snap
    local ms_per_pixel = viewport_duration_ms / viewport_width_px
    local tolerance = SNAP_TOLERANCE_PX * ms_per_pixel
    return tolerance  -- No caps - pure pixel-based tolerance
end

return M
