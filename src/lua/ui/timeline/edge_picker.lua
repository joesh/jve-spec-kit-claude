--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~175 LOC
-- Volatility: unknown
--
-- @file edge_picker.lua
-- All coordinates are now integer frames
local ui_constants = require("core.ui_constants")

local M = {}

--- Select edges at a clip's boundary.
--- This is the core function for edge selection - used by both mouse picking and expansion.
---
--- @param track_clips table Array of clips on the track (will be sorted)
--- @param target_clip table The clip whose boundary we're selecting
--- @param side string "downstream" (out edge) or "upstream" (in edge)
--- @param click_type string "single" (one edge) or "roll" (both edges at boundary)
--- @return table {edges = [...], boundary_time = number}
function M.select_boundary_edges(track_clips, target_clip, side, click_type)
    assert(track_clips, "select_boundary_edges: track_clips required")
    assert(target_clip, "select_boundary_edges: target_clip required")
    assert(target_clip.id, "select_boundary_edges: target_clip.id required")
    assert(side == "downstream" or side == "upstream",
        "select_boundary_edges: side must be 'downstream' or 'upstream'")
    assert(click_type == "single" or click_type == "roll",
        "select_boundary_edges: click_type must be 'single' or 'roll'")

    -- Build sorted list of valid clips
    local valid_clips = {}
    local target_idx = nil
    for _, clip in ipairs(track_clips) do
        local start_val = clip.timeline_start or clip.start_value
        local dur_val = clip.duration or clip.duration_value
        if type(start_val) == "number" and type(dur_val) == "number" and dur_val > 0 then
            local entry = {
                id = clip.id,
                track_id = clip.track_id,
                timeline_start = start_val,
                duration = dur_val
            }
            table.insert(valid_clips, entry)
        end
    end

    table.sort(valid_clips, function(a, b)
        if a.timeline_start == b.timeline_start then
            return (a.id or "") < (b.id or "")
        end
        return a.timeline_start < b.timeline_start
    end)

    -- Find target clip in sorted list
    for i, clip in ipairs(valid_clips) do
        if clip.id == target_clip.id then
            target_idx = i
            break
        end
    end

    if not target_idx then
        return {edges = {}, boundary_time = nil}
    end

    local clip = valid_clips[target_idx]
    local prev_clip = valid_clips[target_idx - 1]
    local next_clip = valid_clips[target_idx + 1]

    local edges = {}
    local boundary_time

    if side == "downstream" then
        -- Boundary at clip's end (out edge)
        boundary_time = clip.timeline_start + clip.duration

        -- Left side of boundary: this clip's out edge
        local left_edge = {
            clip_id = clip.id,
            edge_type = "out",
            track_id = clip.track_id
        }

        -- Right side of boundary: next clip's in edge (gap or media)
        -- With gap-as-clip, gap clips are in the track list. The next clip
        -- at this boundary is always found — it's either a media clip or a gap clip.
        local right_edge
        if next_clip and next_clip.timeline_start == boundary_time then
            right_edge = {
                clip_id = next_clip.id,
                edge_type = "in",
                track_id = next_clip.track_id
            }
        else
            -- No adjacent clip — this clip is at the end of the track.
            -- No roll partner available.
            right_edge = nil
        end

        if click_type == "roll" then
            table.insert(edges, left_edge)
            table.insert(edges, right_edge)
        else
            -- Single click on downstream = out edge
            table.insert(edges, left_edge)
        end

    else -- side == "upstream"
        -- Boundary at clip's start (in edge)
        boundary_time = clip.timeline_start

        -- Right side of boundary: this clip's in edge
        local right_edge = {
            clip_id = clip.id,
            edge_type = "in",
            track_id = clip.track_id
        }

        -- Left side of boundary: prev clip's out edge (gap or media)
        -- With gap-as-clip, the previous clip is always found if one exists.
        local left_edge
        if prev_clip and (prev_clip.timeline_start + prev_clip.duration) == boundary_time then
            left_edge = {
                clip_id = prev_clip.id,
                edge_type = "out",
                track_id = prev_clip.track_id
            }
        else
            -- No adjacent clip — this clip is at the start of the track.
            -- No roll partner available.
            left_edge = nil
        end

        if click_type == "roll" then
            table.insert(edges, left_edge)
            table.insert(edges, right_edge)
        else
            -- Single click on upstream = in edge
            table.insert(edges, right_edge)
        end
    end

    return {edges = edges, boundary_time = boundary_time}
end

-- Validate clip has integer bounds
local function validate_bounds(clip)
    if not clip then return nil end
    local start_val = clip.timeline_start or clip.start_value
    local dur_val = clip.duration or clip.duration_value
    if type(start_val) ~= "number" or type(dur_val) ~= "number" or dur_val <= 0 then
        return nil
    end
    return start_val, dur_val
end

-- Build boundary map for a single track. Each boundary holds the left/right edge
-- that meet at that time (clip edge or gap edge).
-- All times are integer frames.
function M.build_boundaries(track_clips, time_to_pixel, viewport_width)
    if not time_to_pixel or not viewport_width then return {} end

    local valid_clips = {}
    for _, clip in ipairs(track_clips) do
        local start_val, dur_val = validate_bounds(clip)
        if start_val and dur_val then
            clip.timeline_start = start_val
            clip.duration = dur_val
            table.insert(valid_clips, clip)
        end
    end

    table.sort(valid_clips, function(a, b)
        local af = a.timeline_start
        local bf = b.timeline_start
        if af == bf then return (a.id or "") < (b.id or "") end
        return af < bf
    end)

    local boundaries = {}
    for idx, clip in ipairs(valid_clips) do
        local start_frames = clip.timeline_start
        local duration = clip.duration

        local prev = valid_clips[idx - 1]
        local next_clip = valid_clips[idx + 1]

        local end_frames = start_frames + duration

        local start_px = time_to_pixel(start_frames, viewport_width)
        local end_px = time_to_pixel(end_frames, viewport_width)

        -- With gap-as-clip, all boundaries are clip:out / clip:in pairs.
        -- Gap clips appear in the sorted list like any other clip.
        local start_boundary = boundaries[start_frames] or {time = start_frames, px = start_px}
        if prev and (prev.timeline_start + prev.duration) == start_frames then
            start_boundary.left = {clip = prev, clip_id = prev.id, edge_type = "out"}
        end
        start_boundary.right = {clip = clip, clip_id = clip.id, edge_type = "in"}
        boundaries[start_frames] = start_boundary

        local end_boundary = boundaries[end_frames] or {time = end_frames, px = end_px}
        end_boundary.left = {clip = clip, clip_id = clip.id, edge_type = "out"}
        if next_clip and (clip.timeline_start + clip.duration) == next_clip.timeline_start then
            end_boundary.right = {clip = next_clip, clip_id = next_clip.id, edge_type = "in"}
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
    local min_width = opts.min_edge_selectable_width or ui_constants.TIMELINE.MIN_EDGE_SELECTABLE_WIDTH_PX
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
        return entry.clip and entry.clip.clip_kind == "gap"
    end

    -- Calculate element width in pixels for an edge entry
    local function get_element_width_px(entry, _boundary_px)
        if not entry then return nil end

        -- All edges use the clip's pixel width (gap clips included)
        local c = entry.clip
        if c and c.timeline_start and c.duration then
            local start_px = time_to_pixel(c.timeline_start, viewport_width)
            local end_px = time_to_pixel(c.timeline_start + c.duration, viewport_width)
            return end_px - start_px
        end
        return nil
    end

    -- Check if edge is selectable (element width >= min_width)
    local function is_edge_selectable(entry)
        if not entry or not min_width then return true end
        local width = get_element_width_px(entry, b.px)
        if not width then return true end  -- unknown/infinite = allow
        return width >= min_width
    end

    -- Determine which edges are selectable based on width
    local left_selectable = is_edge_selectable(left)
    local right_selectable = is_edge_selectable(right)

    -- If neither edge is selectable, return empty result
    if not left_selectable and not right_selectable then
        return {selection = {}, roll_used = false, candidates = {}, boundaries = boundaries, boundary = b}
    end

    -- Filter edges based on selectability
    local effective_left = left_selectable and left or nil
    local effective_right = right_selectable and right or nil

    local candidates = {}
    if effective_left then table.insert(candidates, {clip = effective_left.clip, clip_id = effective_left.clip_id, edge = effective_left.edge_type, distance = hit.dist}) end
    if effective_right then table.insert(candidates, {clip = effective_right.clip, clip_id = effective_right.clip_id, edge = effective_right.edge_type, distance = hit.dist}) end

    local selection = {}
    local roll_used = false
    local zone
    local offset_px = cursor_x - (b.px or cursor_x)
    local in_center_zone = math.abs(offset_px) <= center_half
    -- Explicit nil checks prevent Lua truthiness issues (false vs nil)
    -- Roll requires BOTH edges to be selectable
    local can_roll = (effective_left ~= nil) and (effective_right ~= nil)
        and (effective_left.clip_id ~= nil) and (effective_right.clip_id ~= nil)
    if can_roll then
        if effective_left.clip_id == effective_right.clip_id and not (edge_is_gap(effective_left) or edge_is_gap(effective_right)) then
            can_roll = false
        end
    end
    local dragged_candidate = nil

    if can_roll and in_center_zone then
        roll_used = true
        zone = "center"
        if offset_px < 0 and effective_left then
            dragged_candidate = effective_left
        elseif offset_px > 0 and effective_right then
            dragged_candidate = effective_right
        else
            dragged_candidate = effective_right or effective_left
        end
        table.insert(selection, {clip_id = effective_left.clip_id, edge_type = effective_left.edge_type, trim_type = "roll"})
        table.insert(selection, {clip_id = effective_right.clip_id, edge_type = effective_right.edge_type, trim_type = "roll"})
    else
        local pick
        if in_center_zone then
            -- Center zone: fallback to whichever side is selectable
            zone = "center"
            pick = effective_right or effective_left
        elseif cursor_x < b.px then
            -- Left zone: ONLY select left edge, no fallback
            -- If left isn't selectable, return empty (cursor stays arrow)
            zone = "left"
            pick = effective_left
        elseif cursor_x > b.px then
            -- Right zone: ONLY select right edge, no fallback
            -- If right isn't selectable, return empty (cursor stays arrow)
            zone = "right"
            pick = effective_right
        else
            -- Exactly on boundary (rare): prefer right, then left
            zone = "center"
            pick = effective_right or effective_left
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
