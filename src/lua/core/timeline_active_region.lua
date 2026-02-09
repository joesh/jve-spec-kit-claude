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
-- Size: ~233 LOC
-- Volatility: unknown
--
-- @file timeline_active_region.lua
local M = {}

local function assert_rate(rate)
    assert(rate and rate.fps_numerator and rate.fps_denominator, "timeline_active_region: missing sequence frame rate")
    return rate.fps_numerator, rate.fps_denominator
end

local function binary_search_first_start_on_or_after(track_clips, target_frames)
    local lo = 1
    local hi = #track_clips
    local ans = #track_clips + 1
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local clip = track_clips[mid]
        assert(clip, "timeline_active_region: nil clip in binary search at index " .. tostring(mid))
        assert(type(clip.timeline_start) == "number",
            "timeline_active_region: clip missing integer timeline_start in binary search (id=" .. tostring(clip.id) .. ")")
        local start_frames = clip.timeline_start
        if start_frames >= target_frames then
            ans = mid
            hi = mid - 1
        else
            lo = mid + 1
        end
    end
    return ans
end

local function clip_start_frames(clip)
    if not clip or type(clip.timeline_start) ~= "number" then
        return nil
    end
    return clip.timeline_start
end

local function clip_end_frames(clip)
    local start_frames = clip_start_frames(clip)
    if not start_frames or type(clip.duration) ~= "number" then
        return nil
    end
    return start_frames + clip.duration
end

local function edge_point_frames(edge, clip)
    if not clip or type(clip.timeline_start) ~= "number" or type(clip.duration) ~= "number" then
        return nil
    end
    local start_frames = clip.timeline_start
    local end_frames = start_frames + clip.duration
    local edge_type = edge and edge.edge_type
    if edge_type == "in" or edge_type == "gap_before" then
        return start_frames
    end
    if edge_type == "out" or edge_type == "gap_after" then
        return end_frames
    end
    error("timeline_active_region: unsupported edge_type " .. tostring(edge_type))
end

local function include_neighbor_if_close(min_frames, max_frames, neighbor, point_frames, pad_frames, force_include)
    if not neighbor or not point_frames or not pad_frames then
        return min_frames, max_frames
    end
    local n_start = clip_start_frames(neighbor)
    local n_end = clip_end_frames(neighbor)
    if not n_start or not n_end then
        return min_frames, max_frames
    end

    -- Only include the neighbor when it is close enough to plausibly participate
    -- in the active interaction zone. Far-away clips across large gaps should not
    -- expand the region (they cannot constrain a localized edge drag).
    if not force_include and n_end <= point_frames then
        local gap_before = point_frames - n_end
        if gap_before > pad_frames then
            return min_frames, max_frames
        end
    elseif not force_include and n_start >= point_frames then
        local gap_after = n_start - point_frames
        if gap_after > pad_frames then
            return min_frames, max_frames
        end
    end

    min_frames = min_frames and math.min(min_frames, n_start) or n_start
    max_frames = max_frames and math.max(max_frames, n_end) or n_end
    return min_frames, max_frames
end

function M.compute_for_edge_drag(state_module, edges, opts)
    assert(type(opts) == "table", "TimelineActiveRegion.compute_for_edge_drag: opts table required")
    assert(state_module, "TimelineActiveRegion.compute_for_edge_drag: state_module is required")
    assert(type(edges) == "table" and #edges > 0, "TimelineActiveRegion.compute_for_edge_drag: edges required")

    local rate = state_module.get_sequence_frame_rate and state_module.get_sequence_frame_rate()
    local fps_num, fps_den = assert_rate(rate)

    local pad_frames = opts.pad_frames
    assert(type(pad_frames) == "number" and pad_frames > 0, "TimelineActiveRegion.compute_for_edge_drag: opts.pad_frames must be a positive number")

    local min_frames = nil
    local max_frames = nil
    local min_ripple_point = nil
    local any_ripple = false

    for _, edge in ipairs(edges) do
        assert(edge and edge.clip_id, "TimelineActiveRegion.compute_for_edge_drag: edge.clip_id required")
        local clip = state_module.get_clip_by_id and state_module.get_clip_by_id(edge.clip_id) or nil
        assert(clip, "TimelineActiveRegion.compute_for_edge_drag: missing clip for edge " .. tostring(edge.clip_id))
        assert(clip.track_id, "TimelineActiveRegion.compute_for_edge_drag: clip missing track_id " .. tostring(edge.clip_id))
        assert(type(clip.timeline_start) == "number" and type(clip.duration) == "number",
            "TimelineActiveRegion.compute_for_edge_drag: clip missing integer time fields " .. tostring(edge.clip_id))

        local clip_start = clip.timeline_start
        local clip_end = clip_start + clip.duration
        local point = edge_point_frames(edge, clip)

        min_frames = min_frames and math.min(min_frames, clip_start) or clip_start
        max_frames = max_frames and math.max(max_frames, clip_end) or clip_end

        if point then
            min_ripple_point = min_ripple_point and math.min(min_ripple_point, point) or point
        end
        assert(edge.trim_type, "TimelineActiveRegion.compute_for_edge_drag: edge.trim_type required")
        if edge.trim_type ~= "roll" then
            any_ripple = true
        end

        local track_clips = state_module.get_track_clip_index and state_module.get_track_clip_index(clip.track_id) or nil
        if track_clips and #track_clips > 0 and point then
            local idx = binary_search_first_start_on_or_after(track_clips, point)
            local prev_clip = (idx > 1) and track_clips[idx - 1] or nil
            local next_clip = (idx <= #track_clips) and track_clips[idx] or nil
            local force_prev = (edge.edge_type == "gap_before")
            local force_next = (edge.edge_type == "gap_after")
            min_frames, max_frames = include_neighbor_if_close(min_frames, max_frames, prev_clip, point, pad_frames, force_prev)
            min_frames, max_frames = include_neighbor_if_close(min_frames, max_frames, next_clip, point, pad_frames, force_next)
        end
    end

    assert(min_frames and max_frames, "TimelineActiveRegion.compute_for_edge_drag: unable to compute bounds")

    local interaction_start = math.max(0, min_frames - pad_frames)
    local interaction_end = max_frames + pad_frames

    return {
        fps_numerator = fps_num,
        fps_denominator = fps_den,
        interaction_start_frames = interaction_start,
        interaction_end_frames = interaction_end,
        -- Past the interaction window boundary, ripple behaves like a rigid translation.
        bulk_shift_start_frames = any_ripple and interaction_end or nil,
        pad_frames = pad_frames,
        signature = string.format("%d:%d:%s", interaction_start, interaction_end, tostring(min_ripple_point or "")),
    }
end

function M.build_snapshot_for_region(state_module, region)
    assert(state_module, "TimelineActiveRegion.build_snapshot_for_region: state_module is required")
    assert(region and region.interaction_start_frames and region.interaction_end_frames, "TimelineActiveRegion.build_snapshot_for_region: region bounds required")

    local rate = state_module.get_sequence_frame_rate and state_module.get_sequence_frame_rate()
    local fps_num, fps_den = assert_rate(rate)

    local start_frames = region.interaction_start_frames
    local end_frames = region.interaction_end_frames

    assert(state_module.get_all_tracks, "TimelineActiveRegion.build_snapshot_for_region: state_module.get_all_tracks required")
    assert(state_module.get_track_clip_index, "TimelineActiveRegion.build_snapshot_for_region: state_module.get_track_clip_index required")
    local tracks = state_module.get_all_tracks()
    local clips = {}
    local clip_lookup = {}
    local clip_track_lookup = {}
    local track_clip_map = {}
    local track_clip_positions = {}
    local post_boundary_first_clip = {}
    local post_boundary_prev_clip = {}

    local function add_clip(track_id, clip)
        if not clip or not clip.id then
            return
        end
        if clip_lookup[clip.id] then
            return
        end
        table.insert(clips, clip)
        clip_lookup[clip.id] = clip
        clip_track_lookup[clip.id] = clip.track_id
        track_clip_map[track_id] = track_clip_map[track_id] or {}
        table.insert(track_clip_map[track_id], clip)
    end

    for _, track in ipairs(tracks) do
        local track_id = track and track.id
        if track_id then
            local track_clips = state_module.get_track_clip_index(track_id)
            if track_clips and #track_clips > 0 then
                local idx = binary_search_first_start_on_or_after(track_clips, start_frames)

                local prev_idx = idx - 1
                if prev_idx >= 1 then
                    add_clip(track_id, track_clips[prev_idx])
                end

                if idx >= 1 and idx <= #track_clips then
                    add_clip(track_id, track_clips[idx])
                end

                if idx > 1 then idx = idx - 1 end
                local first_index_after_end = nil
                for i = idx, #track_clips do
                    local clip = track_clips[i]
                    local cs = type(clip.timeline_start) == "number" and clip.timeline_start or nil
                    local cd = type(clip.duration) == "number" and clip.duration or nil
                    if not cs or not cd then
                        goto continue_clip
                    end
                    if cs >= end_frames then
                        first_index_after_end = i
                        break
                    end
                    if (cs + cd) <= start_frames then
                        goto continue_clip
                    end
                    add_clip(track_id, clip)
                    ::continue_clip::
                end
                if first_index_after_end then
                    local next_clip = track_clips[first_index_after_end]
                    if next_clip and next_clip.id then
                        post_boundary_first_clip[track_id] = next_clip.id
                        add_clip(track_id, next_clip)
                        local prev_clip = track_clips[first_index_after_end - 1]
                        if prev_clip and prev_clip.id then
                            post_boundary_prev_clip[track_id] = prev_clip.id
                            add_clip(track_id, prev_clip)
                        end
                    end
                end
            end
        end
    end

    for track_id, list in pairs(track_clip_map) do
        table.sort(list, function(a, b)
            local a_start = type(a.timeline_start) == "number" and a.timeline_start or 0
            local b_start = type(b.timeline_start) == "number" and b.timeline_start or 0
            if a_start == b_start then
                return (a.id or "") < (b.id or "")
            end
            return a_start < b_start
        end)
        track_clip_positions[track_id] = {}
        for index, clip in ipairs(list) do
            if clip.id then
                track_clip_positions[track_id][clip.id] = index
            end
        end
    end

    return {
        clips = clips,
        clip_lookup = clip_lookup,
        clip_track_lookup = clip_track_lookup,
        track_clip_map = track_clip_map,
        track_clip_positions = track_clip_positions,
        post_boundary_first_clip = post_boundary_first_clip,
        post_boundary_prev_clip = post_boundary_prev_clip,
        fps_numerator = fps_num,
        fps_denominator = fps_den,
        active_region = region,
    }
end

return M
