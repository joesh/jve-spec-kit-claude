--- Media inspection utilities for clip insertion
--
-- Provides pure functions to inspect clip/media properties
-- Used by commands to determine what channels to insert
--
-- @file clip_media.lua
local M = {}

function M.has_video(clip, media)
    local width = assert(clip.width or media.width, "clip_media.has_video: missing video width")
    local height = assert(clip.height or media.height, "clip_media.has_video: missing video height")
    return width > 0 and height > 0
end

function M.audio_channel_count(clip, media)
    local channels = assert(clip.audio_channels or media.audio_channels, "clip_media.audio_channel_count: missing audio channel count")
    return assert(tonumber(channels), "clip_media.audio_channel_count: audio channel count must be a number")
end

function M.has_audio(clip, media)
    return M.audio_channel_count(clip, media) > 0
end

return M
