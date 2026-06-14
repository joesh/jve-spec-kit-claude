local M = {}

-- Returns true if any track of the given type (\"AUDIO\" or \"VIDEO\") is soloed.
function M.any_solo_for_type(tracks, track_type)
    for _, t in ipairs(tracks) do
        if t.track_type == track_type and (t.soloed == true or t.soloed == 1) then
            return true
        end
    end
    return false
end

-- Returns true if the track should be visually dimmed.
-- any_solo_same_type: result of any_solo_for_type for this track's type.
function M.should_dim(track, any_solo_same_type)
    local is_muted  = track.muted  == true or track.muted  == 1
    local is_soloed = track.soloed == true or track.soloed == 1
    return is_muted or (any_solo_same_type and not is_soloed)
end

return M
