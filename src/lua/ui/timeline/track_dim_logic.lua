local M = {}

local VALID_TRACK_TYPES = { AUDIO = true, VIDEO = true }

-- Returns true if any track of the given type ("AUDIO" or "VIDEO") is soloed.
function M.any_solo_for_type(tracks, track_type)
    assert(tracks   ~= nil, "any_solo_for_type: tracks is nil")
    assert(VALID_TRACK_TYPES[track_type],
        "any_solo_for_type: unknown track_type " .. tostring(track_type))
    for _, t in ipairs(tracks) do
        if t.track_type == track_type and t.soloed then
            return true
        end
    end
    return false
end

-- Returns true if the track should be visually dimmed.
-- any_solo_same_type: result of any_solo_for_type for this track's type.
-- Solo trumps mute: a soloed track is always audible (see the audio mix in
-- audio_playback.send_mix_params_to_tmb and the video include rule in
-- renderer.compute_effective_video_indices), so it is never dimmed — even when
-- also muted. Otherwise a track is dim when muted, or when a same-type solo is
-- active and this track is not the soloed one.
function M.should_dim(track, any_solo_same_type)
    assert(track ~= nil, "should_dim: track is nil")
    if track.soloed then return false end
    return track.muted or any_solo_same_type or false
end

return M
