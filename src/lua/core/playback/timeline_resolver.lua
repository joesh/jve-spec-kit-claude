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
local logger = require("core.logger")

--------------------------------------------------------------------------------
-- Internal: Calculate source time for a clip at a given playhead position
-- @param clip Clip object (must have timeline_start, source_in, rate)
-- @param playhead_rat Rational playhead position
-- @return source_time_us (integer microseconds)
--------------------------------------------------------------------------------
local function calc_source_time_us(clip, playhead_rat)
    local offset = playhead_rat - clip.timeline_start
    local clip_rate = clip.rate
    assert(clip_rate and clip_rate.fps_numerator and clip_rate.fps_denominator,
        string.format("timeline_resolver: clip %s has no rate", clip.id))

    -- Rescale offset to clip's frame rate
    local offset_in_clip_rate = offset:rescale(clip_rate.fps_numerator, clip_rate.fps_denominator)
    local source_frame = clip.source_in + offset_in_clip_rate

    -- Convert to microseconds: frame * 1000000 * fps_den / fps_num
    return math.floor(
        source_frame.frames * 1000000 * clip_rate.fps_denominator / clip_rate.fps_numerator
    )
end

--- Resolve the topmost VIDEO clip at a given playhead time
-- @param playhead_rat Rational: playhead position in timeline time
-- @param sequence_id string: ID of the sequence to search
-- @return table or nil: {media_path, source_time_us, clip} or nil if gap
function M.resolve_at_time(playhead_rat, sequence_id)
    assert(playhead_rat, "timeline_resolver.resolve_at_time: playhead_rat is required")
    assert(sequence_id, "timeline_resolver.resolve_at_time: sequence_id is required")

    -- Get video tracks sorted by track_index (ascending = topmost first)
    local tracks = Track.find_by_sequence(sequence_id, "VIDEO")
    if not tracks or #tracks == 0 then
        return nil
    end

    -- Tracks are already sorted by track_index ASC from the query
    -- Iterate in order (lowest index = topmost = highest priority)
    for _, track in ipairs(tracks) do
        local clip = Clip.find_at_time(track.id, playhead_rat)
        if clip then
            local media = Media.load(clip.media_id)
            if not media then
                logger.warn("timeline_resolver",
                    string.format("Clip %s references missing media %s", clip.id, tostring(clip.media_id)))
                goto continue_track
            end

            local source_time_us = calc_source_time_us(clip, playhead_rat)

            return {
                media_path = media.file_path,
                source_time_us = source_time_us,
                clip = clip,
            }
        end
        ::continue_track::
    end

    -- No clip found at playhead = gap
    return nil
end

--- Resolve ALL active audio clips at a given playhead time
-- Returns one entry per audio track that has a clip at the playhead.
-- @param playhead_rat Rational: playhead position in timeline time
-- @param sequence_id string: ID of the sequence to search
-- @return list of {media_path, source_time_us, clip, track} (may be empty)
function M.resolve_all_audio_at_time(playhead_rat, sequence_id)
    assert(playhead_rat, "timeline_resolver.resolve_all_audio_at_time: playhead_rat is required")
    assert(sequence_id, "timeline_resolver.resolve_all_audio_at_time: sequence_id is required")

    local tracks = Track.find_by_sequence(sequence_id, "AUDIO")
    if not tracks or #tracks == 0 then
        return {}
    end

    local results = {}
    for _, track in ipairs(tracks) do
        local clip = Clip.find_at_time(track.id, playhead_rat)
        if clip then
            local media = Media.load(clip.media_id)
            if not media then
                logger.warn("timeline_resolver",
                    string.format("Audio clip %s references missing media %s",
                        clip.id, tostring(clip.media_id)))
                goto continue_audio_track
            end

            local source_time_us = calc_source_time_us(clip, playhead_rat)

            results[#results + 1] = {
                media_path = media.file_path,
                source_time_us = source_time_us,
                clip = clip,
                track = track,
            }
        end
        ::continue_audio_track::
    end

    return results
end

return M
