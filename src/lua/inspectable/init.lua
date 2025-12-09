local ClipInspectable = require("inspectable.clip")
local SequenceInspectable = require("inspectable.sequence")

local M = {}

function M.clip(opts)
    return ClipInspectable.new(opts or {})
end

function M.sequence(opts)
    return SequenceInspectable.new(opts or {})
end

return M
