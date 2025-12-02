local edge_utils = require('ui.timeline.edge_utils')
local Rational = require('core.rational')

local Renderer = {}

local function to_rational_if_needed(val, ref_rational)
    if type(val) == "number" then
        -- Preserve infinity
        if val == math.huge or val == -math.huge then return val end
        if ref_rational and getmetatable(ref_rational) == Rational.metatable then
            return Rational.new(val, ref_rational.fps_numerator, ref_rational.fps_denominator)
        end
    end
    return val
end

-- Helper for min/max with mixed Rational/Number (Infinity)
local function min_val(a, b)
    if a == -math.huge or b == -math.huge then return -math.huge end
    if a == math.huge then return b end
    if b == math.huge then return a end
    if getmetatable(a) == Rational.metatable and getmetatable(b) == Rational.metatable then
        return (a < b) and a or b
    elseif getmetatable(a) == Rational.metatable and type(b) == "number" then
        return (a < Rational.new(b, a.fps_numerator, a.fps_denominator)) and a or b
    elseif type(a) == "number" and getmetatable(b) == Rational.metatable then
        return (Rational.new(a, b.fps_numerator, b.fps_denominator) < b) and a or b
    else
        return math.min(a, b)
    end
end

local function max_val(a, b)
    if a == math.huge or b == math.huge then return math.huge end
    if a == -math.huge then return b end
    if b == -math.huge then return a end
    if getmetatable(a) == Rational.metatable and getmetatable(b) == Rational.metatable then
        return Rational.max(a, b)
    else
        -- Fallback/mixed
        return (a < b) and b or a
    end
end

local function is_rational(v)
    return getmetatable(v) == Rational.metatable
end

-- Normalize constraints lookup for a given edge.
local function constraint_for_edge(trim_constraints, edge)
    if not edge or not edge.clip_id or not edge.edge_type then
        return nil
    end
    local key = edge.clip_id .. ":" .. edge.edge_type
    return trim_constraints[key]
end

-- Compute a shared clamped delta across all edges by intersecting their constraints.
local function compute_shared_delta(drag_edges, drag_delta, trim_constraints)
    local global_min = -math.huge
    local global_max = math.huge

    for _, edge in ipairs(drag_edges or {}) do
        local constraints = constraint_for_edge(trim_constraints, edge)
        if constraints then
            if constraints.min_delta then
                global_min = max_val(global_min, constraints.min_delta)
            end
            if constraints.max_delta then
                global_max = min_val(global_max, constraints.max_delta)
            end
        end
    end

    if global_min > global_max then
        -- No valid range; block movement.
        -- Return 0 matching the type of drag_delta if possible
        if is_rational(drag_delta) then
            return Rational.new(0, drag_delta.fps_numerator, drag_delta.fps_denominator), global_min, global_max
        end
        return 0, global_min, global_max
    end

    local clamped = max_val(global_min, min_val(global_max, drag_delta))
    return clamped, global_min, global_max
end

-- Clamp the requested delta using the calculated trim constraints.
local function clamp_edge_delta(edge, delta, trim_constraints)
    local constraints = constraint_for_edge(trim_constraints, edge)
    if not constraints then
        return delta, false
    end
    local min_delta = constraints.min_delta or -math.huge
    local max_delta = constraints.max_delta or math.huge
    
    local clamped = max_val(min_delta, min_val(max_delta, delta))
    local at_limit = (clamped ~= delta)
    return clamped, at_limit
end

-- Prepare preview metadata for a single edge: clamped delta, at-limit flag, color.
local function build_preview_edge(edge, shared_delta, requested_delta, trim_constraints, colors)
    local normalized_edge = edge_utils.normalize_edge_type(edge.edge_type)
    local constraints = constraint_for_edge(trim_constraints, edge)
    local clamped_delta, _ = clamp_edge_delta(edge, shared_delta, trim_constraints)

    -- Flag limit only if this edge's own constraint was the limiter
    local at_limit = false
    if constraints and requested_delta then
        if constraints.max_delta and requested_delta > constraints.max_delta and clamped_delta == constraints.max_delta then
            at_limit = true
        elseif constraints.min_delta and requested_delta < constraints.min_delta and clamped_delta == constraints.min_delta then
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
        delta = clamped_delta,
        delta_ms = (type(clamped_delta) == "number") and clamped_delta or (clamped_delta.frames and clamped_delta.frames * 1000 / (clamped_delta.fps_numerator or 1) or clamped_delta),
        at_limit = at_limit,
        color = color
    }
end

-- Public API: normalize a list of drag edges into preview-ready edges
function Renderer.build_preview_edges(drag_edges, drag_delta, trim_constraints, colors)
    local previews = {}
    if not drag_edges or #drag_edges == 0 then
        return previews
    end

    local shared_delta = compute_shared_delta(drag_edges, drag_delta, trim_constraints)

    for _, edge in ipairs(drag_edges) do
        local preview = build_preview_edge(edge, shared_delta, drag_delta, trim_constraints, colors)
        table.insert(previews, preview)
    end
    return previews
end

return Renderer
