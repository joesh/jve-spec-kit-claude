--- Identity marker — single Lua source for the JVE-clip identity carrier.
---
--- The marker has two carriers on the wire:
---   1. Sm2Ti FieldsBlob inside `<Sm2TiItemLockableBlob>` (file-side carrier).
---   2. Live-API marker added via TimelineItem:AddMarker(customData=clip_id)
---      by the helper after import (verbs.py:_stamp_marker_safe).
---
--- Both must agree on color / name / note / frame / duration so that:
---   * Resolve's UI shows one marker per clip, not two (visual dedup).
---   * The helper's idempotent re-stamp check sees `existing == clip_id`
---     and skips, instead of stacking a second identity marker per Send.
---   * drt_round_trip.validate finds the marker by color+name and confirms
---     the writer didn't drift the fingerprint.
---
--- Python helper carries its own copies at tools/resolve-helper/verbs.py
--- (_IDENTITY_MARKER_*) — language boundary forces that duplication; the
--- values here are the canonical ones.

local M = {}

M.COLOR           = "Purple"
M.NAME            = "JVE clip identity"
M.NOTE            = ""
M.DURATION_FRAMES = 1
M.FRAME           = 0

--- Build the marker dict for a clip — the payload `drt_binary` encodes
--- into the FieldsBlob and the test harness asserts on round-trip.
function M.for_clip(clip_id)
    assert(type(clip_id) == "string" and clip_id ~= "",
        "drt_identity_marker.for_clip: clip_id (non-empty string) required")
    return {
        frame       = M.FRAME,
        color       = M.COLOR,
        name        = M.NAME,
        note        = M.NOTE,
        duration    = M.DURATION_FRAMES,
        custom_data = clip_id,
    }
end

--- True iff `m` is the identity-marker fingerprint (color + name). No other
--- marker JVE emits shares both, so this predicate is sufficient.
function M.matches(m)
    return type(m) == "table"
        and m.color == M.COLOR
        and m.name  == M.NAME
end

return M
