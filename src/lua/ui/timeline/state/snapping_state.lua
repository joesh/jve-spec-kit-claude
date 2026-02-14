--- Magnetic snapping state for timeline drag operations.
--
-- Manages baseline snapping preference (persists across drags) and
-- per-drag inversion (resets when drag ends). The effective snapping
-- state is baseline XOR drag_inverted.
--
-- @file snapping_state.lua
local M = {}
local logger = require("core.logger")

-- Baseline preference (persists across drags)
local baseline_enabled = true  -- Default ON

-- Per-drag inversion (resets when drag ends)
local drag_inverted = false

--- Get effective snapping state (baseline XOR drag_inverted).
function M.is_enabled()
    local effective = baseline_enabled
    if drag_inverted then
        effective = not effective
    end
    return effective
end

--- Toggle baseline snapping preference.
function M.toggle_baseline()
    baseline_enabled = not baseline_enabled
    logger.info("snapping_state", string.format("Snapping %s", baseline_enabled and "ON" or "OFF"))
end

--- Invert snapping for current drag only.
function M.invert_drag()
    drag_inverted = not drag_inverted
    logger.info("snapping_state", string.format("Snapping temporarily %s for this drag", M.is_enabled() and "ON" or "OFF"))
end

--- Reset drag inversion (call when drag ends).
function M.reset_drag()
    drag_inverted = false
end

return M
