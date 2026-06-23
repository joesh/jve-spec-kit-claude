--- Inspector implied target picker (pure).
---
--- A blank inspector on empty selection is uninformative — the user is
--- always looking AT something. The clip under the displayed playhead
--- is the natural subject; the runtime caller marshals the displayed
--- tab's tracks + clips-at-playhead into this pure pick so it stays
--- testable without timeline_state.
---
--- @file implied_target.lua

local M = {}

--- Partition enabled tracks by kind and pre-sort:
---   video_desc — video tracks, highest track_index first  (topmost)
---   audio_asc  — audio tracks, lowest  track_index first  (topmost)
--- Disabled tracks are excluded entirely so the picker never sees them.
local function build_enabled_track_index(tracks)
    local video, audio = {}, {}
    for _, t in ipairs(tracks) do
        assert(t.id and t.id ~= "",
            "implied_target: track missing id")
        assert(type(t.track_index) == "number",
            "implied_target: track " .. tostring(t.id)
            .. " missing track_index")
        assert(t.track_type == "VIDEO" or t.track_type == "AUDIO",
            "implied_target: track " .. tostring(t.id)
            .. " has unknown track_type " .. tostring(t.track_type))
        if t.enabled then
            if t.track_type == "VIDEO" then
                table.insert(video, t)
            else
                table.insert(audio, t)
            end
        end
    end
    table.sort(video, function(a, b) return a.track_index > b.track_index end)
    table.sort(audio, function(a, b) return a.track_index < b.track_index end)
    return { video_desc = video, audio_asc = audio }
end

--- Index clips by their owning track_id. A clip with no track_id is an
--- upstream bug (timeline clips always belong to a track) — assert.
local function bucket_clips_by_track(clips_at_frame)
    local by_track = {}
    for _, c in ipairs(clips_at_frame) do
        assert(c.id and c.id ~= "",
            "implied_target: clip missing id")
        assert(c.track_id and c.track_id ~= "",
            "implied_target: clip " .. tostring(c.id) .. " missing track_id")
        by_track[c.track_id] = by_track[c.track_id] or {}
        table.insert(by_track[c.track_id], c)
    end
    return by_track
end

--- Walk the ordered enabled-track list; return the clip whose track has a
--- candidate at the playhead. Two-clips-on-one-track-at-one-frame is a
--- VIDEO_OVERLAP-class invariant violation upstream — assert rather than
--- silently disambiguate (rule 1.14).
local function pick_for_kind(ordered_tracks, clips_by_track)
    for _, t in ipairs(ordered_tracks) do
        local list = clips_by_track[t.id]
        if list and #list > 0 then
            assert(#list == 1, string.format(
                "implied_target: %d clips overlap at the playhead on track %s "
                .. "— upstream VIDEO_OVERLAP invariant violated",
                #list, tostring(t.id)))
            return list[1]
        end
    end
    return nil
end

--- Pick the implied inspectable clip given the displayed tab's tracks
--- and the set of clips overlapping the playhead frame.
---
--- @param tracks          list of {id, track_type ("VIDEO"|"AUDIO"),
---                                  track_index (int), enabled (bool)}
--- @param clips_at_frame  list of clip rows with at least {id, track_id}
--- @return clip table or nil
function M.pick(tracks, clips_at_frame)
    assert(type(tracks) == "table",
        "implied_target.pick: tracks must be a list")
    assert(type(clips_at_frame) == "table",
        "implied_target.pick: clips_at_frame must be a list")

    local enabled = build_enabled_track_index(tracks)
    local by_track = bucket_clips_by_track(clips_at_frame)

    local video_pick = pick_for_kind(enabled.video_desc, by_track)
    if video_pick then return video_pick end

    return pick_for_kind(enabled.audio_asc, by_track)
end

return M
