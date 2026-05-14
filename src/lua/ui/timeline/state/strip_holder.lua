--- Strip-holder: a single module-level slot for the TimelineTabStrip
--- instance, set by timeline_state at init/project-change and read by
--- modules that can't (or shouldn't) own the strip themselves
--- (timeline_core_state, etc.).
---
--- Why a holder: timeline_state owns the strip lifecycle, but
--- timeline_core_state's persist/load machinery needs to ask "which tab
--- is displayed right now?" — and the natural require timeline_state ←→
--- core_state would be circular. The holder breaks the cycle: both
--- modules require this file; timeline_state writes; core_state reads.
---
--- The slot is `nil` until timeline_state.init() runs. Readers must
--- tolerate nil (no project loaded yet).
---
--- @file strip_holder.lua

local M = {}

local _strip = nil

--- Install the canonical strip instance. Called by timeline_state
--- on init and on every project_changed.
function M.set(strip)
    assert(strip == nil or type(strip) == "table",
        "strip_holder.set: strip must be a TimelineTabStrip instance or nil")
    _strip = strip
end

--- Return the strip instance, or nil if none has been installed.
function M.get()
    return _strip
end

--- Convenience: returns the displayed tab's sequence_id, or nil when
--- there is no strip or no displayed tab. The single, canonical answer
--- to "what sequence does the timeline view render?".
function M.displayed_sequence_id()
    if not _strip then return nil end
    local displayed = _strip:get_displayed()
    return displayed and displayed.sequence_id or nil
end

return M
