--- Timeline Resolver: resolves playhead time to active clips
--
-- Responsibilities:
-- - Given playhead time, returns the topmost (lowest track_index) video clip
-- - Given playhead time, returns ALL active audio clips (one per track)
-- - Calculates source time for each resolved clip
-- - Returns nil/empty for gaps (no clip at playhead)
--
-- Invariants:
-- - Video: always returns clip from lowest track_index when multiple clips overlap
-- - Audio: returns one clip per audio track (all tracks, not just topmost)
-- - Source time calculation accounts for clip's source_in offset
--
-- @file timeline_resolver.lua

local M = {}
local Track = require("models.track")
local Clip = require("models.clip")
local Media = require("models.media")

--------------------------------------------------------------------------------
-- Internal: Calculate source frame and time for a clip at a given playhead.
--
-- "Frames are frames": source_frame = source_in + timeline_offset (1:1 mapping).
-- A 24fps clip on a 30fps timeline plays each source frame at 1/30s — the clip
-- runs faster. No rate conversion here; the speed conform is the intended behavior.
--
-- @param clip            Clip object (timeline_start, source_in, rate)
-- @param playhead_frame  integer playhead position in timeline frames
-- @return source_time_us (integer microseconds), source_frame (integer)
--------------------------------------------------------------------------------
local function calc_source_time_us(clip, playhead_frame)
    assert(type(playhead_frame) == "number", "timeline_resolver: playhead must be integer")
    assert(type(clip.timeline_start) == "number", "timeline_resolver: timeline_start must be integer")
    assert(type(clip.source_in) == "number", "timeline_resolver: source_in must be integer")

    local offset_frames = playhead_frame - clip.timeline_start
    local source_frame = clip.source_in + offset_frames

    local clip_rate = clip.rate
    assert(clip_rate and clip_rate.fps_numerator and clip_rate.fps_denominator,
        string.format("timeline_resolver: clip %s has no rate", clip.id))

    -- Convert to microseconds: frame * 1000000 * fps_den / fps_num
    local source_time_us = math.floor(
        source_frame * 1000000 * clip_rate.fps_denominator / clip_rate.fps_numerator
    )
    return source_time_us, source_frame
end

--- Resolve the topmost VIDEO clip at a given playhead time
-- @param playhead_frame number: playhead position in timeline frames (integer)
-- @param sequence_id string: ID of the sequence to search
-- @return table or nil: {media_path, source_time_us, source_frame, clip} or nil if gap
function M.resolve_at_time(playhead_frame, sequence_id)
    assert(type(playhead_frame) == "number", "timeline_resolver.resolve_at_time: playhead_frame must be integer")
    assert(sequence_id, "timeline_resolver.resolve_at_time: sequence_id is required")

    -- Get video tracks sorted by track_index (ascending = topmost first)
    local tracks = Track.find_by_sequence(sequence_id, "VIDEO")
    if not tracks or #tracks == 0 then
        return nil
    end

    -- Tracks are already sorted by track_index ASC from the query
    -- Iterate in order (lowest index = topmost = highest priority)
    for _, track in ipairs(tracks) do
        local clip = Clip.find_at_time(track.id, playhead_frame)
        if clip then
            local media = Media.load(clip.media_id)
            assert(media, string.format("timeline_resolver.resolve_at_time: clip %s references missing media %s", clip.id, tostring(clip.media_id)))

            local source_time_us, source_frame = calc_source_time_us(clip, playhead_frame)

            return {
                media_path = media.file_path,
                source_time_us = source_time_us,
                source_frame = source_frame,
                clip = clip,
            }
        end
    end

    -- No clip found at playhead = gap
    return nil
end

--- Resolve ALL active audio clips at a given playhead time
-- Returns one entry per audio track that has a clip at the playhead.
-- @param playhead_frame number: playhead position in timeline frames (integer)
-- @param sequence_id string: ID of the sequence to search
-- @return list of {media_path, source_time_us, source_frame, clip, track} (may be empty)
function M.resolve_all_audio_at_time(playhead_frame, sequence_id)
    assert(type(playhead_frame) == "number", "timeline_resolver.resolve_all_audio_at_time: playhead_frame must be integer")
    assert(sequence_id, "timeline_resolver.resolve_all_audio_at_time: sequence_id is required")

    local tracks = Track.find_by_sequence(sequence_id, "AUDIO")
    if not tracks or #tracks == 0 then
        return {}
    end

    local results = {}
    for _, track in ipairs(tracks) do
        local clip = Clip.find_at_time(track.id, playhead_frame)
        if clip then
            local media = Media.load(clip.media_id)
            assert(media, string.format("timeline_resolver.resolve_all_audio_at_time: audio clip %s references missing media %s", clip.id, tostring(clip.media_id)))

            local source_time_us, source_frame = calc_source_time_us(clip, playhead_frame)

            results[#results + 1] = {
                media_path = media.file_path,
                source_time_us = source_time_us,
                source_frame = source_frame,
                clip = clip,
                track = track,
                -- Media's video fps for "frames are frames" audio conform.
                -- Audio clips need the video rate to compute correct source offset.
                media_fps_num = media.frame_rate.fps_numerator,
                media_fps_den = media.frame_rate.fps_denominator,
            }
        end
    end

    return results
end

return M
