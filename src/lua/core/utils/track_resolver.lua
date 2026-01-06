--- Track resolution utilities for timeline operations
--
-- Provides functions to resolve track references from timeline state
-- Handles track sorting and index-based lookup
--
-- @file track_resolver.lua
local M = {}

local function sort_tracks(tracks)
    table.sort(tracks, function(a, b)
        local a_index = a.track_index or 0
        local b_index = b.track_index or 0
        return a_index < b_index
    end)
end

function M.resolve_video_track(timeline_state, index)
    local tracks = assert(timeline_state.get_video_tracks and timeline_state.get_video_tracks(),
        "track_resolver.resolve_video_track: missing video tracks")
    sort_tracks(tracks)
    local track = tracks[index + 1]
    assert(track and track.id, string.format("track_resolver.resolve_video_track: missing video track %d", index))
    return track
end

function M.resolve_audio_track(timeline_state, index)
    local tracks = assert(timeline_state.get_audio_tracks and timeline_state.get_audio_tracks(),
        "track_resolver.resolve_audio_track: missing audio tracks")
    sort_tracks(tracks)
    local track = tracks[index + 1]
    assert(track and track.id, string.format("track_resolver.resolve_audio_track: missing audio track %d", index))
    return track
end

return M
