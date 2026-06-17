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

--- Convenience: returns the displayed tab's kind ("source" / "record"),
--- or nil when there is no strip or no displayed tab. Companion to
--- displayed_sequence_id() — the canonical answer to "what kind of tab
--- does the timeline view render?". Keeps id/kind/cache reads on one
--- source so the displayed-tab invariant in capture_displayed_playhead
--- can never see them diverge.
function M.displayed_kind()
    if not _strip then return nil end
    local displayed = _strip:get_displayed()
    return displayed and displayed.kind or nil
end

--- Convenience: returns the displayed tab's cache, or nil when there is
--- no strip or no displayed tab. The cache is the authoritative per-tab
--- store for per-sequence view-state (frame_rate, tc origin, viewport,
--- scroll offsets, playhead). Audit H1 fold-in for L4 (#34) — eliminates
--- the strip:get():get_displayed().cache nil-dance at every read site.
---
--- Returns nil for "blank panel" states (no project, no displayed tab,
--- transient close). Callers that perform arithmetic on cache fields must
--- assert non-nil before proceeding; callers that branch on presence
--- (panel scroll restore, etc.) should handle nil as "no work to do".
function M.displayed_cache()
    if not _strip then return nil end
    local displayed = _strip:get_displayed()
    return displayed and displayed.cache or nil
end

return M
