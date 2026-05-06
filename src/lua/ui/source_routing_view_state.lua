-- source_routing_view_state — tracks the effective source-routing display mode (FR-029d).
--
-- effective_mode() = pref.get() XOR modifier_held:
--   modifier not held → returns pref.get() directly
--   modifier held → returns the opposite mode

local M = {}

local OPPOSITE = { per_channel = "per_clip", per_clip = "per_channel" }

local _pref           = nil
local _modifier_held  = false

--- Initialize with the pref module. Must be called before effective_mode() or set_modifier_held().
function M.init(pref_module)
    assert(pref_module and type(pref_module.get) == "function",
        "source_routing_view_state.init: pref_module with get() required")
    _pref          = pref_module
    _modifier_held = false
end

--- Record whether the view-toggle modifier key (Option/Alt) is currently held.
function M.set_modifier_held(held)
    assert(_pref, "source_routing_view_state: call init() first")
    assert(type(held) == "boolean",
        "source_routing_view_state.set_modifier_held: boolean required, got " .. type(held))
    _modifier_held = held
end

--- Return the effective display mode, accounting for modifier-key flip.
--- Reads pref.get() on every call so preference changes are reflected immediately.
function M.effective_mode()
    assert(_pref, "source_routing_view_state: call init() first")
    local base = _pref.get()
    assert(base == "per_channel" or base == "per_clip",
        "source_routing_view_state: pref returned unexpected value '" .. tostring(base) .. "'")
    if _modifier_held then
        return assert(OPPOSITE[base], "source_routing_view_state: no opposite for '" .. base .. "'")
    end
    return base
end

return M
