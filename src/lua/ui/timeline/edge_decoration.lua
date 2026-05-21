--- Shared edge-info decoration.
---
--- Selected edges (from timeline_state) carry { clip_id, edge_type,
--- trim_type } but no track_id. BatchRippleEdit and friends need
--- track_id, which lives on the clip row. This module joins the two,
--- asserting every selected edge resolves to a real clip on the
--- timeline (a stale edge means selection state diverged from the model
--- — silent drop would mask the upstream bug).

local M = {}

--- Given selected_edges and the timeline's clip list, return
--- BatchRippleEdit-shaped edge_infos with track_id joined in.
--- @param selected_edges table  array of {clip_id, edge_type, trim_type}
--- @param all_clips       table  array of clip rows (must have .id, .track_id)
--- @param caller_name     string  command name for assert messages (e.g. "ExtendEdit")
--- @return table  array of {clip_id, edge_type, track_id, trim_type}
function M.decorate(selected_edges, all_clips, caller_name)
    local clip_by_id = {}
    for _, c in ipairs(all_clips) do clip_by_id[c.id] = c end

    local edge_infos = {}
    for _, edge in ipairs(selected_edges) do
        local clip = clip_by_id[edge.clip_id]
        assert(clip, string.format(
            "%s: selected edge references clip_id=%s, which is not on the "
            .. "active timeline (selection is stale)",
            tostring(caller_name), tostring(edge.clip_id)))
        edge_infos[#edge_infos + 1] = {
            clip_id   = edge.clip_id,
            edge_type = edge.edge_type,
            track_id  = clip.track_id,
            trim_type = edge.trim_type,
        }
    end
    return edge_infos
end

return M
