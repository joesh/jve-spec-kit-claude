local M = {}

function M.build_track_clip_map(all_clips)
    assert(all_clips, "build_track_clip_map: all_clips is nil")
    local map = {}
    for _, clip in ipairs(all_clips) do
        assert(clip.track_id, "build_track_clip_map: clip missing track_id (id=" .. tostring(clip.id) .. ")")
        local track_id = clip.track_id
        map[track_id] = map[track_id] or {}
        table.insert(map[track_id], clip)
    end
    for _, list in pairs(map) do
        table.sort(list, function(a, b)
            if a.sequence_start == b.sequence_start then
                return (a.id or "") < (b.id or "")
            end
            return a.sequence_start < b.sequence_start
        end)
    end
    return map
end

function M.build_neighbor_bounds_cache(track_clip_map)
    assert(track_clip_map, "build_neighbor_bounds_cache: track_clip_map is nil")
    local cache = {}

    for _, clips in pairs(track_clip_map) do
        for index, clip in ipairs(clips) do
            -- All coords are integer frames
            assert(clip and clip.id, "build_neighbor_bounds_cache: clip missing id")
            assert(type(clip.sequence_start) == "number", "build_neighbor_bounds_cache: clip.sequence_start must be integer")
            assert(type(clip.duration) == "number", "build_neighbor_bounds_cache: clip.duration must be integer")

            local prev_clip = clips[index - 1]
            local next_clip = clips[index + 1]

            local prev_end_frames = nil
            local prev_id = nil
            if prev_clip then
                assert(type(prev_clip.sequence_start) == "number", "build_neighbor_bounds_cache: prev_clip.sequence_start must be integer")
                assert(type(prev_clip.duration) == "number", "build_neighbor_bounds_cache: prev_clip.duration must be integer")
                prev_end_frames = prev_clip.sequence_start + prev_clip.duration
                prev_id = prev_clip.id
            end

            local next_start_frames = nil
            local next_id = nil
            if next_clip then
                assert(type(next_clip.sequence_start) == "number", "build_neighbor_bounds_cache: next_clip.sequence_start must be integer")
                next_start_frames = next_clip.sequence_start
                next_id = next_clip.id
            end

            cache[clip.id] = {
                prev_end_frames = prev_end_frames,
                next_start_frames = next_start_frames,
                prev_id = prev_id,
                next_id = next_id
            }
        end
    end

    return cache
end

function M.find_next_clip_on_track(all_clips, clip)
    if not clip or not clip.track_id then return nil end
    assert(all_clips, "find_next_clip_on_track: all_clips is nil")
    local clip_end = clip.sequence_start + clip.duration
    local best = nil
    for _, other in ipairs(all_clips) do
        if other.id ~= clip.id and other.track_id == clip.track_id then
            local other_start = other.sequence_start
            if other_start >= clip_end then
                if not best or other_start < best.sequence_start then
                    best = other
                end
            end
        end
    end
    return best
end

function M.find_prev_clip_on_track(all_clips, clip)
    if not clip or not clip.track_id then return nil end
    assert(all_clips, "find_prev_clip_on_track: all_clips is nil")
    local start_value = clip.sequence_start
    local best = nil
    for _, other in ipairs(all_clips) do
        if other.id ~= clip.id and other.track_id == clip.track_id then
            local other_end = other.sequence_start + other.duration
            if other_end <= start_value then
                if not best or other_end > (best.sequence_start + best.duration) then
                    best = other
                end
            end
        end
    end
    return best
end

return M

