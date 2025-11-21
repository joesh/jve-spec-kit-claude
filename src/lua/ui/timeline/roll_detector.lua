local edge_utils = require('ui.timeline.edge_utils')

local RollDetector = {}

local function build_selection(left_target, right_target)
    return {
        {
            clip_id = left_target.clip_id,
            edge_type = left_target.edge_type,
            trim_type = "roll"
        },
        {
            clip_id = right_target.clip_id,
            edge_type = right_target.edge_type,
            trim_type = "roll"
        }
    }
end

local function evaluate_candidate(current, candidate_score, candidate_selection, candidate_pair)
    if not current or candidate_score < current.score then
        return {
            score = candidate_score,
            selection = candidate_selection,
            pair = candidate_pair
        }
    end
    return current
end

function RollDetector.find_best_roll_pair(entries, click_x, viewport_width, detect_roll_between_clips)
    if not entries or #entries == 0 then
        return nil, nil, math.huge
    end

    local best = nil
    detect_roll_between_clips = detect_roll_between_clips or function()
        return false
    end

    for i = 1, #entries do
        local first = entries[i]
        local clip_a = first.clip
        local norm_a = edge_utils.normalize_edge_type(first.edge)
        if clip_a and (norm_a == "in" or norm_a == "out") then
            for j = i + 1, #entries do
                local second = entries[j]
                local clip_b = second.clip
                local norm_b = edge_utils.normalize_edge_type(second.edge)
                if clip_b and (norm_b == "in" or norm_b == "out") and clip_a.track_id == clip_b.track_id and clip_a.id ~= clip_b.id then
                    local left_clip, right_clip = nil, nil
                    local left_distance, right_distance = nil, nil

                    if norm_a == "out" and norm_b == "in" then
                        left_clip = clip_a
                        right_clip = clip_b
                        left_distance = first.distance
                        right_distance = second.distance
                    elseif norm_a == "in" and norm_b == "out" then
                        left_clip = clip_b
                        right_clip = clip_a
                        left_distance = second.distance
                        right_distance = first.distance
                    end

                    if left_clip and right_clip then
                        if left_clip.start_value > right_clip.start_value then
                            left_clip, right_clip = right_clip, left_clip
                            left_distance, right_distance = right_distance, left_distance
                        end

                        if detect_roll_between_clips(left_clip, right_clip, click_x, viewport_width) then
                            local score = math.max(left_distance or 0, right_distance or 0)
                            local left_target = {clip_id = left_clip.id, edge_type = "out"}
                            local right_target = {clip_id = right_clip.id, edge_type = "in"}
                            local selection = build_selection(left_target, right_target)
                            local pair_meta = {
                                edit_time = left_clip.start_value + left_clip.duration_value,
                                left_target = left_target,
                                right_target = right_target,
                                roll_kind = "clip_clip"
                            }
                            best = evaluate_candidate(best, score, selection, pair_meta)
                        end
                    end
                end
            end
        end
    end

    local gap_candidates = {}
    for _, entry in ipairs(entries) do
        local edge = edge_utils.normalize_edge_type(entry.edge)
        if edge == "gap_after" or edge == "gap_before" then
            table.insert(gap_candidates, entry)
        end
    end

    for _, entry in ipairs(gap_candidates) do
        local clip = entry.clip
        if clip then
            local score = entry.distance or math.huge
            local left_target
            local right_target
            local edit_time
            local roll_kind

            if entry.edge == "gap_after" then
                left_target = {clip_id = clip.id, edge_type = "out"}
                right_target = {clip_id = clip.id, edge_type = "gap_after"}
                edit_time = clip.start_value + clip.duration_value
                roll_kind = "clip_gap_after"
            else -- gap_before
                left_target = {clip_id = clip.id, edge_type = "gap_before"}
                right_target = {clip_id = clip.id, edge_type = "in"}
                edit_time = clip.start_value
                roll_kind = "gap_before_clip"
            end

            local selection = build_selection(left_target, right_target)
            local pair_meta = {
                edit_time = edit_time,
                left_target = left_target,
                right_target = right_target,
                roll_kind = roll_kind
            }
            best = evaluate_candidate(best, score, selection, pair_meta)
        end
    end

    if not best then
        return nil, nil, math.huge
    end
    return best.selection, best.pair, best.score
end

return RollDetector
