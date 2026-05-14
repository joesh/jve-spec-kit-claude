--- Timeline Tracks State
-- Manages track list, layout, and properties
local M = {}
local data = require("ui.timeline.state.timeline_state_data")

local track_layout_dirty = false

function M.get_all()
    return data.state.tracks
end

function M.get_video_tracks()
    local result = {}
    for _, track in ipairs(data.state.tracks) do
        if track.track_type == "VIDEO" then table.insert(result, track) end
    end
    return result
end

function M.get_audio_tracks()
    local result = {}
    for _, track in ipairs(data.state.tracks) do
        if track.track_type == "AUDIO" then table.insert(result, track) end
    end
    return result
end

function M.get_height(track_id)
    assert(type(track_id) == "string" and track_id ~= "",
        "track_state.get_height: track_id required")
    for _, track in ipairs(data.state.tracks) do
        if track.id == track_id then
            -- track.height nil = "exists but never resized" → DEFAULT is
            -- the correct semantic. Unknown track is a different story
            -- (see assert below).
            return track.height or data.dimensions.default_track_height
        end
    end
    error(string.format(
        "track_state.get_height: track %s not in state — caller is asking "
        .. "about a track that does not exist on the active sequence",
        tostring(track_id)))
end

function M.set_height(track_id, height, persist_callback)
    assert(type(track_id) == "string" and track_id ~= "",
        "track_state.set_height: track_id required")
    for _, track in ipairs(data.state.tracks) do
        if track.id == track_id then
            if track.height ~= height then
                track.height = height
                track_layout_dirty = true
                data.notify_listeners()
                if persist_callback then persist_callback(true) end -- force persist layout
            end
            return
        end
    end
    error(string.format(
        "track_state.set_height: track %s not in state — caller is trying "
        .. "to size a track that does not exist on the active sequence",
        tostring(track_id)))
end

function M.is_layout_dirty() return track_layout_dirty end
function M.clear_layout_dirty() track_layout_dirty = false end

function M.get_primary_id(track_type)
    local type_upper = track_type:upper()
    for _, track in ipairs(data.state.tracks) do
        if track.track_type == type_upper then return track.id end
    end
    return nil
end

function M.get_by_id(track_id)
    if not track_id then return nil end
    for _, track in ipairs(data.state.tracks) do
        if track.id == track_id then
            return track
        end
    end
    return nil
end

--- Get whether waveform display is enabled for a track.
--- Audio tracks default to true; video tracks always return false.
function M.get_waveform_enabled(track_id)
    local track = M.get_by_id(track_id)
    if not track then return false end
    if track.track_type ~= "AUDIO" then return false end
    if track.waveform_enabled == nil then return true end
    return track.waveform_enabled
end

--- Set waveform display enabled state for a track. Notifies listeners.
function M.set_waveform_enabled(track_id, enabled)
    local track = M.get_by_id(track_id)
    assert(track, "track_state.set_waveform_enabled: track not found: " .. tostring(track_id))
    assert(track.track_type == "AUDIO",
        "track_state.set_waveform_enabled: only audio tracks have waveform toggle")
    track.waveform_enabled = enabled
    data.notify_listeners()
end

return M
