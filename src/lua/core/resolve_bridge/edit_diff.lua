--- edit_diff — classify a Resolve-side edit against the stored
--- fingerprint + the current JVE clip state (spec 023 T053, FR-025).
---
--- The identity ledger stores `edit_fingerprint` = the canonical
--- fingerprint of a clip's edit state at the last successful sync.
--- On the next SyncEditsFromResolve, for each matched clip we have
--- three pieces of state:
---   • `live`      — what Resolve currently reports (read_timeline)
---   • `stored_fp` — the fingerprint stored in resolve_bridge_link
---   • `current`  — what JVE currently shows (the clip row)
---
--- Classify into one of four kinds:
---   "neither"        live == stored AND current == stored
---   "resolve_only"   live ≠ stored AND current == stored  (safe apply)
---   "jve_only"       live == stored AND current ≠ stored  (no-op)
---   "both"           live ≠ stored AND current ≠ stored   (conflict)
---
--- Pure data — no DB, no side effects. SyncEditsFromResolve (T054)
--- decides what to do per kind.

local M = {}

local REQUIRED_FIELDS = {
    "source_in", "source_out", "record_start", "record_dur", "enabled",
}

local function assert_edit_state(state, label)
    assert(type(state) == "table",
        "edit_diff: " .. label .. " must be table")
    for _, k in ipairs(REQUIRED_FIELDS) do
        assert(state[k] ~= nil, string.format(
            "edit_diff: %s missing field '%s' — every edit-state record "
            .. "must carry source_in/source_out/record_start/record_dur/"
            .. "enabled", label, k))
    end
end

--- Deterministic canonical fingerprint of a clip edit state.
function M.fingerprint(state)
    assert_edit_state(state, "state")
    -- Canonical order; the boolean is normalized to 0/1 so callers can
    -- pass `true`/`false` or `1`/`0` interchangeably without changing
    -- the hash (Resolve uses int-like, JVE uses bool internally).
    local enabled = state.enabled and 1 or 0
    return string.format("si=%d|so=%d|rs=%d|rd=%d|en=%d",
        state.source_in, state.source_out,
        state.record_start, state.record_dur, enabled)
end

--- Classify a single clip's edit-state divergence.
--- @param live     table  current Resolve read_timeline row
--- @param stored_fp string fingerprint captured at last sync
--- @param current  table  current JVE clip edit state
--- @return table { kind, live, current, stored_fp }
function M.classify(live, stored_fp, current)
    assert_edit_state(live, "live")
    assert(type(stored_fp) == "string" and stored_fp ~= "",
        "edit_diff.classify: stored_fp string required")
    assert_edit_state(current, "current")

    local live_fp    = M.fingerprint(live)
    local current_fp = M.fingerprint(current)
    local resolve_changed = live_fp ~= stored_fp
    local jve_changed     = current_fp ~= stored_fp

    local kind
    if resolve_changed and jve_changed then
        kind = "both"
    elseif resolve_changed then
        kind = "resolve_only"
    elseif jve_changed then
        kind = "jve_only"
    else
        kind = "neither"
    end

    return {
        kind      = kind,
        live      = live,
        current   = current,
        stored_fp = stored_fp,
    }
end

return M
