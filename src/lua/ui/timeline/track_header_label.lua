--- Track header label derivation.
---
--- A channel-backed audio track (a synced clip's per-channel audio) shows
--- the recorder/user channel label on EITHER tab — the label follows the
--- channel, not the tab. Priority:
---   1. track.name         — the user's override (a rename), authoritative.
---   2. track.channel_name — the recorder's iXML channel name, probed by
---                           the view for nameless channel tracks.
---   3. ""                 — blank, when neither is present.
---
--- A plain (non-channel) track keeps the historical convention:
---   Source tab — abbreviated form (V1/A1), ignoring any stored default
---     ("Video 1"/"Audio N"); the source view shows the same shorthand the
---     user reads on records.
---   Record tab — the stored name verbatim (the user may have renamed it),
---     else blank.
---
--- track.name is OPTIONAL (nil = unset). track.channel_backed marks the
--- track as a synced master channel (has a media_ref with a source_channel).
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
    -- Channel-backed master audio track: label follows the channel on
    -- either tab — user rename, else probed iXML channel name, else blank.
    if track.channel_backed then
        if type(track.name) == "string" and track.name ~= "" then
            return track.name
        end
        if type(track.channel_name) == "string" and track.channel_name ~= "" then
            return track.channel_name
        end
        return ""
    end
    -- Plain track: source abbreviates (ignoring stored defaults); record
    -- shows the stored name, else blank.
    if displayed_kind == "source" then return abbreviate(track) end
    if type(track.name) == "string" and track.name ~= "" then
        return track.name
    end
    return ""
end

return M
