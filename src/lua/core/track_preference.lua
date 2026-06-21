--- core/track_preference.lua — the single write chokepoint for boolean
--- track preferences (muted / soloed / locked / enabled / autoselect).
---
--- Both ToggleTrackPreference (single-track flip) and
--- ExclusiveToggleTrackPreference (set-one, opposite-all) route their
--- writes through M.set so the persistence + change signal happen in
--- exactly one place (spec 025 FR-005; ENGINEERING.md Rule #4 / 2.16).
---
--- These are session-monitoring preferences, NOT mix decisions — callers
--- keep them off the undo stack (spec 015 FR-040a).

local M = {}

local Signals = require("core.signals")
local log     = require("core.logger").for_area("commands")

-- autoselect (Avid track auto-select / Premiere track targeting) is a
-- preference alongside the monitoring booleans; see ToggleTrackPreference.
M.ALLOWED = { muted = true, soloed = true, locked = true, enabled = true, autoselect = true }

--- Set `property` on a loaded `track` to boolean `value`, persist it, and
--- emit `track_preference_changed(track_id, property, new_int, prev_int)`
--- (1/0 ints, matching the established signal contract). Returns the
--- previous boolean value.
function M.set(track, property, value)
    assert(track and track.id, "track_preference.set: a loaded track is required")
    assert(M.ALLOWED[property], string.format(
        "track_preference.set: property must be muted/soloed/locked/enabled/autoselect; got %s",
        tostring(property)))

    local new_val  = value and true or false
    local prev_val = track[property]
    track[property] = new_val
    assert(track:save(), string.format(
        "track_preference.set: track:save() failed for track=%s property=%s",
        tostring(track.id), tostring(property)))

    local db_new  = new_val and 1 or 0
    local db_prev = prev_val and 1 or 0
    log.event("track_preference.set: track=%s %s %s->%s",
        track.id, property, tostring(db_prev), tostring(db_new))
    Signals.emit("track_preference_changed", track.id, property, db_new, db_prev)

    return prev_val
end

return M
