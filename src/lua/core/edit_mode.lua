--- core/edit_mode — narrow trim-mode toggle for the source viewer's
--- live-bound retrim dispatch (spec 019 FR-008..012).
---
--- Module-level session state. Two enum values: "overwrite" (default) and
--- "ripple". Default established on every process start; never read from
--- or written to disk — FR-010 mandates session-transient semantics.
---
--- The source viewer's mark-setter dispatch (FR-013) reads
--- `get_trim_mode()` to choose between `OverwriteTrimEdge` and
--- `RippleTrimEdge` when retrim is invoked from live-bound mode. No
--- other gesture consults this value — FR-012 explicitly limits scope.
---
--- @file edit_mode.lua

local Signals = require("core.signals")

local M = {}

local _trim_mode = "overwrite"

--- Return the current trim mode.
--- @return string "overwrite" | "ripple"
function M.get_trim_mode()
    return _trim_mode
end

--- Set the trim mode to one of the two enum values.
--- Asserts on any other value (FR-009 — no silent coerce, no fallback).
--- Emits `trim_mode_changed(new, old)` on every successful set so
--- listeners (future status-bar indicator, etc.) can react.
--- @param mode string "overwrite" | "ripple"
function M.set_trim_mode(mode)
    assert(mode == "overwrite" or mode == "ripple", string.format(
        "edit_mode.set_trim_mode: mode must be 'overwrite' or 'ripple'; got %s (%s)",
        type(mode), tostring(mode)))
    local old = _trim_mode
    _trim_mode = mode
    Signals.emit("trim_mode_changed", _trim_mode, old)
end

--- Test-only: restore the module to its initial state. Per FR-010 the
--- normal application lifecycle resets to "overwrite" on every project
--- open / process start; this helper exposes the same restore for unit
--- tests that need a known starting point.
function M._reset_for_tests()
    _trim_mode = "overwrite"
end

return M
