local ui_constants = require("core.ui_constants")

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
        local edge_a = first.edge
        if clip_a and (edge_a == "in" or edge_a == "out") then
            for j = i + 1, #entries do
                local second = entries[j]
                local clip_b = second.clip
                local edge_b = second.edge
                if clip_b and (edge_b == "in" or edge_b == "out") and clip_a.track_id == clip_b.track_id and clip_a.id ~= clip_b.id then
                    local left_clip, right_clip = nil, nil
                    local left_distance, right_distance = nil, nil

                    if edge_a == "out" and edge_b == "in" then
                        left_clip = clip_a
                        right_clip = clip_b
                        left_distance = first.distance
                        right_distance = second.distance
                    elseif edge_a == "in" and edge_b == "out" then
                        left_clip = clip_b
                        right_clip = clip_a
                        left_distance = second.distance
                        right_distance = first.distance
                    end

                    if left_clip and right_clip then
                        if left_clip.timeline_start > right_clip.timeline_start then
                            left_clip, right_clip = right_clip, left_clip
                            left_distance, right_distance = right_distance, left_distance
                        end
                        -- Require cursor to be inside a tight roll zone near the shared boundary.
                        local roll_radius = math.min((ui_constants.TIMELINE.ROLL_ZONE_PX or 7) / 2, (ui_constants.TIMELINE.EDGE_ZONE_PX or 7) / 2)
                        if (left_distance or math.huge) <= roll_radius and (right_distance or math.huge) <= roll_radius
                            and detect_roll_between_clips(left_clip, right_clip, click_x, viewport_width) then
                            local score = math.max(left_distance or 0, right_distance or 0)
                            local left_target = {clip_id = left_clip.id, edge_type = "out"}
                            local right_target = {clip_id = right_clip.id, edge_type = "in"}
                            local selection = build_selection(left_target, right_target)
                            local pair_meta = {
                                edit_time = left_clip.timeline_start + left_clip.duration,
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

    -- Do not auto-roll on solitary gap edges; require a real neighboring clip pair.

    if not best then
        return nil, nil, math.huge
    end
    return best.selection, best.pair, best.score
end

return RollDetector
