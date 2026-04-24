--- Inspectable factory: constructors for the Inspector's adapter objects
--- that front either a clip or a sequence. The Inspector queries
--- inspectables via `:get(field)` / `:set(field, value)` — this module
--- is the single entry point so callers don't reach into the per-kind
--- implementation files directly.
---
--- @file init.lua
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
