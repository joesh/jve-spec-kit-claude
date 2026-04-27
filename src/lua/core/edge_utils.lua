local M = {}

-- Convert edge types to their corresponding bracket representation for rendering/display.
-- With gap-as-clip, gap clips use standard "in"/"out" edge types.
function M.to_bracket(edge_type)
    return edge_type
end

return M

