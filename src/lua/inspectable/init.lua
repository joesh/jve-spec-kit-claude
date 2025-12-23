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
-- Size: ~10 LOC
-- Volatility: unknown
--
-- @file init.lua
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
