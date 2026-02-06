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
-- Size: ~62 LOC
-- Volatility: unknown
--
-- @file edge_info.lua
local M = {}

local edge_utils = require("core.edge_utils")

function M.get_edge_track_id(edge_info, clip_lookup, original_states_map)
    assert(edge_info, "edge_info.get_edge_track_id: edge_info is nil")
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
    error(string.format("edge_info.get_edge_track_id: unable to resolve track_id for clip %s",
        tostring(edge_info.clip_id)))
end

function M.compute_edge_boundary_time(edge_info, original_states_map)
    assert(edge_info, "edge_info.compute_edge_boundary_time: edge_info is nil")
    assert(original_states_map, "edge_info.compute_edge_boundary_time: original_states_map is nil")
    local clip_state = original_states_map[edge_info.clip_id]
    assert(clip_state, string.format("edge_info.compute_edge_boundary_time: no original state for clip %s", tostring(edge_info.clip_id)))
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
    error(string.format("edge_info.compute_edge_boundary_time: unhandled edge_type=%s normalized=%s for clip %s",
        tostring(raw_edge), tostring(normalized_edge), tostring(edge_info.clip_id)))
end

function M.build_edge_key(edge_info)
    assert(edge_info, "edge_info.build_edge_key: edge_info is nil")
    local source_id = edge_info.original_clip_id or edge_info.clip_id
    assert(source_id, string.format("edge_info.build_edge_key: missing clip_id (original_clip_id=%s, clip_id=%s)", tostring(edge_info.original_clip_id), tostring(edge_info.clip_id)))
    assert(edge_info.edge_type, string.format("edge_info.build_edge_key: missing edge_type for clip %s", tostring(source_id)))
    return string.format("%s:%s", source_id, edge_info.edge_type)
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
