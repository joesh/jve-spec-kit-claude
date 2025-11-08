local M = {}

-- Keep edge identifiers stable so gap edges stay distinct from clip edges.
function M.normalize_edge_type(edge_type)
    if edge_type == nil or edge_type == "" then
        return edge_type
    end
    return edge_type
end

return M
