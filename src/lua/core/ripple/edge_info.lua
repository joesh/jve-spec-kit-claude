local M = {}

local edge_utils = require("core.edge_utils")

function M.get_edge_track_id(edge_info, clip_lookup, original_states_map)
    if not edge_info then
        return nil
    end
    if edge_info.track_id and edge_info.track_id ~= "" then
        return edge_info.track_id
    end
    if clip_lookup and edge_info.clip_id and clip_lookup[edge_info.clip_id] then
        return clip_lookup[edge_info.clip_id].track_id
    end
    local original = original_states_map and edge_info.clip_id and original_states_map[edge_info.clip_id]
    if original then
        return original.track_id
    end
    return nil
end

function M.compute_edge_boundary_time(edge_info, original_states_map)
    if not edge_info or not original_states_map then
        return nil
    end
    local clip_state = original_states_map[edge_info.clip_id]
    if not clip_state then
        return nil
    end
    local is_temp_gap = type(edge_info.clip_id) == "string" and edge_info.clip_id:find("^temp_gap_")
    local raw_edge = edge_info.edge_type
    local normalized_edge = edge_info.normalized_edge or edge_utils.to_bracket(raw_edge)
    if raw_edge == "gap_before" then
        if is_temp_gap then
            return clip_state.timeline_start + clip_state.duration
        end
        return clip_state.timeline_start
    elseif raw_edge == "gap_after" then
        if is_temp_gap then
            return clip_state.timeline_start
        end
        return clip_state.timeline_start + clip_state.duration
    elseif normalized_edge == "in" then
        return clip_state.timeline_start
    elseif normalized_edge == "out" then
        return clip_state.timeline_start + clip_state.duration
    end
    return nil
end

function M.build_edge_key(edge_info)
    if not edge_info then
        return "::"
    end
    local source_id = edge_info.original_clip_id or edge_info.clip_id
    return string.format("%s:%s", tostring(source_id or ""), tostring(edge_info.edge_type or ""))
end

function M.bracket_for_normalized_edge(edge_type)
    if edge_type == "in" then
        return "["
    elseif edge_type == "out" then
        return "]"
    end
    return nil
end

return M
