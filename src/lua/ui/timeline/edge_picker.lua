local edge_utils = require("ui.timeline.edge_utils")
local ui_constants = require("core.ui_constants")

local M = {}

-- Build boundary map for a single track. Each boundary holds the left/right edge
-- that meet at that time (clip edge or gap edge).
function M.build_boundaries(track_clips, time_to_pixel, viewport_width)
    if not time_to_pixel or not viewport_width then return {} end

    table.sort(track_clips, function(a, b)
        local af = (a.timeline_start and a.timeline_start.frames) or 0
        local bf = (b.timeline_start and b.timeline_start.frames) or 0
        if af == bf then return (a.id or "") < (b.id or "") end
        return af < bf
    end)

    local boundaries = {}
    for idx, clip in ipairs(track_clips) do
        local prev = track_clips[idx - 1]
        local next_clip = track_clips[idx + 1]

        local start_time = clip.timeline_start
        local end_time = clip.timeline_start + clip.duration
        local start_frames = start_time.frames
        local end_frames = end_time.frames

        local start_px = time_to_pixel(start_time, viewport_width)
        local end_px = time_to_pixel(end_time, viewport_width)

        local start_boundary = boundaries[start_frames] or {time = start_time, px = start_px}
        if prev and (prev.timeline_start.frames + prev.duration.frames) == start_frames then
            start_boundary.left = {clip = prev, clip_id = prev.id, edge_type = "out"}
        else
            start_boundary.left = start_boundary.left or {clip = clip, clip_id = clip.id, edge_type = "gap_before"}
        end
        start_boundary.right = {clip = clip, clip_id = clip.id, edge_type = "in"}
        boundaries[start_frames] = start_boundary

        local end_boundary = boundaries[end_frames] or {time = end_time, px = end_px}
        end_boundary.left = {clip = clip, clip_id = clip.id, edge_type = "out"}
        if next_clip and (clip.timeline_start.frames + clip.duration.frames) == next_clip.timeline_start.frames then
            end_boundary.right = {clip = next_clip, clip_id = next_clip.id, edge_type = "in"}
        else
            end_boundary.right = end_boundary.right or {clip = clip, clip_id = clip.id, edge_type = "gap_after"}
        end
        boundaries[end_frames] = end_boundary
    end

    local list = {}
    for _, b in pairs(boundaries) do table.insert(list, b) end
    return list
end

local function find_nearest_boundary(boundaries, cursor_x, edge_zone)
    local best = nil
    for _, b in ipairs(boundaries) do
        if b.px then
            local dist = math.abs(cursor_x - b.px)
            if dist <= edge_zone and (not best or dist < best.dist) then
                best = {boundary = b, dist = dist}
            end
        end
    end
    return best
end

-- Decide which edges should be selected at the given cursor position.
-- Returns a table:
-- { selection = {edges...}, roll_used = bool, candidates = { ... }, boundary = hit_boundary }
function M.pick_edges(track_clips, cursor_x, viewport_width, opts)
    opts = opts or {}
    local edge_zone = opts.edge_zone or ui_constants.TIMELINE.EDGE_ZONE_PX
    if not edge_zone then
        error("edge_picker: EDGE_ZONE_PX constant missing from ui_constants.TIMELINE")
    end
    local roll_zone = opts.roll_zone or ui_constants.TIMELINE.ROLL_ZONE_PX
    if not roll_zone then
        error("edge_picker: ROLL_ZONE_PX constant missing from ui_constants.TIMELINE")
    end
    local time_to_pixel = opts.time_to_pixel
    if not time_to_pixel or not viewport_width or not track_clips then
        return {selection = {}, roll_used = false, candidates = {}}
    end

    local boundaries = M.build_boundaries(track_clips, time_to_pixel, viewport_width)
    local hit = find_nearest_boundary(boundaries, cursor_x, edge_zone)
    if not hit then
        return {selection = {}, roll_used = false, candidates = {}, boundaries = boundaries}
    end

    local b = hit.boundary
    local center_half = math.max(1, math.floor(roll_zone / 2))
    local left = b.left
    local right = b.right
    local function edge_is_gap(entry)
        if not entry then return false end
        return entry.edge_type == "gap_before" or entry.edge_type == "gap_after"
    end

    local candidates = {}
    if left then table.insert(candidates, {clip = left.clip, clip_id = left.clip_id, edge = left.edge_type, distance = hit.dist}) end
    if right then table.insert(candidates, {clip = right.clip, clip_id = right.clip_id, edge = right.edge_type, distance = hit.dist}) end

    local selection = {}
    local roll_used = false
    local zone = "none"
    local offset_px = cursor_x - (b.px or cursor_x)
    local in_center_zone = math.abs(offset_px) <= center_half
    -- Explicit nil checks prevent Lua truthiness issues (false vs nil)
    local can_roll = (left ~= nil) and (right ~= nil)
        and (left.clip_id ~= nil) and (right.clip_id ~= nil)
    if can_roll then
        if left.clip_id == right.clip_id and not (edge_is_gap(left) or edge_is_gap(right)) then
            can_roll = false
        end
    end
    local dragged_candidate = nil

    if can_roll and in_center_zone then
        roll_used = true
        zone = "center"
        if offset_px < 0 and left then
            dragged_candidate = left
        elseif offset_px > 0 and right then
            dragged_candidate = right
        else
            dragged_candidate = right or left
        end
        table.insert(selection, {clip_id = left.clip_id, edge_type = left.edge_type, trim_type = "roll"})
        table.insert(selection, {clip_id = right.clip_id, edge_type = right.edge_type, trim_type = "roll"})
    else
        local pick = nil
        if in_center_zone then
            zone = "center"
            pick = right or left
        elseif cursor_x < b.px then
            zone = "left"
            pick = left or right
        elseif cursor_x > b.px then
            zone = "right"
            pick = right or left
        else
            zone = "center"
            if left and not right then
                pick = left
            elseif right and not left then
                pick = right
            else
                pick = right or left
            end
        end
        if pick then
            dragged_candidate = pick
            table.insert(selection, {clip_id = pick.clip_id, edge_type = pick.edge_type, trim_type = "ripple"})
        end
    end

    local dragged_edge = nil
    if dragged_candidate then
        dragged_edge = {
            clip_id = dragged_candidate.clip_id,
            edge_type = dragged_candidate.edge_type or dragged_candidate.edge,
            trim_type = roll_used and "roll" or "ripple",
            track_id = dragged_candidate.clip and dragged_candidate.clip.track_id or nil
        }
    end

    return {
        selection = selection,
        roll_used = roll_used,
        candidates = candidates,
        boundary = b,
        boundaries = boundaries,
        distance = hit.dist,
        zone = zone,
        dragged_edge = dragged_edge
    }
end

return M
