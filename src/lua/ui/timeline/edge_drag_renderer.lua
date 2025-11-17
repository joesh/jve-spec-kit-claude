local edge_utils = require('ui.timeline.edge_utils')

local Renderer = {}

-- Normalize constraints lookup for a given edge.
local function constraint_for_edge(trim_constraints, edge)
    if not edge or not edge.clip_id or not edge.edge_type then
        return nil
    end
    local key = edge.clip_id .. ":" .. edge.edge_type
    return trim_constraints[key]
end

-- Compute a shared clamped delta across all edges by intersecting their constraints.
local function compute_shared_delta(drag_edges, drag_delta_ms, trim_constraints)
    local global_min = -math.huge
    local global_max = math.huge

    for _, edge in ipairs(drag_edges or {}) do
        local constraints = constraint_for_edge(trim_constraints, edge)
        if constraints then
            if constraints.min_delta and constraints.min_delta > global_min then
                global_min = constraints.min_delta
            end
            if constraints.max_delta and constraints.max_delta < global_max then
                global_max = constraints.max_delta
            end
        end
    end

    if global_min > global_max then
        -- No valid range; block movement.
        return 0, global_min, global_max
    end

    local clamped = math.max(global_min, math.min(global_max, drag_delta_ms))
    return clamped, global_min, global_max
end

-- Clamp the requested delta_ms using the calculated trim constraints.
local function clamp_edge_delta(edge, delta_ms, trim_constraints)
    local constraints = constraint_for_edge(trim_constraints, edge)
    if not constraints then
        return delta_ms, false
    end
    local min_delta = constraints.min_delta or -math.huge
    local max_delta = constraints.max_delta or math.huge
    local clamped = math.max(min_delta, math.min(max_delta, delta_ms))
    local at_limit = (clamped ~= delta_ms)
    return clamped, at_limit
end

-- Prepare preview metadata for a single edge: clamped delta, at-limit flag, color.
local function build_preview_edge(edge, shared_delta_ms, requested_delta_ms, trim_constraints, colors)
    local normalized_edge = edge_utils.normalize_edge_type(edge.edge_type)
    local constraints = constraint_for_edge(trim_constraints, edge)
    local clamped_delta, at_limit = clamp_edge_delta(edge, shared_delta_ms, trim_constraints)
    if constraints and requested_delta_ms and requested_delta_ms ~= shared_delta_ms then
        local eps = 0.0001
        local min_d = constraints.min_delta or -math.huge
        local max_d = constraints.max_delta or math.huge
        if shared_delta_ms <= min_d + eps or shared_delta_ms >= max_d - eps then
            at_limit = true
        end
    end
    local color = colors.edge_selected_available
    if at_limit then
        color = colors.edge_selected_limit
    end
    return {
        clip_id = edge.clip_id,
        edge_type = normalized_edge,
        target_track_id = edge.track_id,
        delta_ms = clamped_delta,
        at_limit = at_limit,
        color = color
    }
end

-- Public API: normalize a list of drag edges into preview-ready edges
function Renderer.build_preview_edges(drag_edges, drag_delta_ms, trim_constraints, colors)
    local previews = {}
    if not drag_edges or #drag_edges == 0 then
        return previews
    end

    local shared_delta = compute_shared_delta(drag_edges, drag_delta_ms, trim_constraints)

    for _, edge in ipairs(drag_edges) do
        local preview = build_preview_edge(edge, shared_delta, drag_delta_ms, trim_constraints, colors)
        table.insert(previews, preview)
    end
    return previews
end

return Renderer
