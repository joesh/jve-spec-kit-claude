--- Track header label derivation.
---
--- Source tab: abbreviated form (V1/A1) — matches the Rec tab visual
--- convention and ignores the master's stored "Video 1"/"Audio N"
--- names. The master can carry a longer name in DB; the source tab
--- view shows the user the same shorthand they read on records.
---
--- Record tab: verbatim track.name — the user may have renamed it.
---
--- @file ui/timeline/track_header_label.lua
local M = {}

local function abbreviate(track)
    assert(track.track_index, "track_header_label: track.track_index required")
    assert(track.track_type == "VIDEO" or track.track_type == "AUDIO",
        "track_header_label: track.track_type must be VIDEO|AUDIO")
    local prefix = (track.track_type == "VIDEO") and "V" or "A"
    return string.format("%s%d", prefix, track.track_index)
end

--- Return the label string for the track header given the displayed
--- tab kind ("source" or "record"). Asserts on unknown kinds — there
--- is no third tab type.
function M.for_display(track, displayed_kind)
    assert(track, "track_header_label.for_display: track required")
    assert(displayed_kind == "source" or displayed_kind == "record",
        string.format(
            "track_header_label.for_display: displayed_kind must be "
            .. "'source'|'record'; got %s", tostring(displayed_kind)))
    if displayed_kind == "source" then return abbreviate(track) end
    assert(type(track.name) == "string" and track.name ~= "",
        "track_header_label.for_display: track.name required for record kind")
    return track.name
end

return M
