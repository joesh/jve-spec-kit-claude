--- Global cancel — set by Escape, consumed by any modal operation.
--
-- Two mechanisms:
--   1. Signal "cancel" — emitted immediately on request(). Subscribers
--      do instant visual cleanup (hide rubber band, etc.)
--   2. Flag — consumed by drag/modal handlers on next event for state cleanup.
--
-- @file cancel.lua
local M = {}
local Signals = require("core.signals")

local requested = false

function M.request()
    requested = true
    Signals.emit("cancel")
end

function M.consume()
    if requested then
        requested = false
        return true
    end
    return false
end

function M.peek()
    return requested
end

function M.clear()
    requested = false
end

return M
