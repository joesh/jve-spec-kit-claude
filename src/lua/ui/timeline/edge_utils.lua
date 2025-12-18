local M = {}

local core_edge_utils = require("core.edge_utils")

-- Convert gap edge types to their corresponding bracket representation for rendering/display.
-- Gap edges represent empty timeline space but are rendered at the clip boundaries they touch.
function M.to_bracket(edge_type)
    return core_edge_utils.to_bracket(edge_type)
end

return M
