-- Timeline Tracks State
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
    for _, track in ipairs(data.state.tracks) do
        if track.id == track_id then
            return track.height or data.dimensions.default_track_height
        end
    end
    return data.dimensions.default_track_height
end

function M.set_height(track_id, height, persist_callback)
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

return M
