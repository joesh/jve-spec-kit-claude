--- models/sequence/point_in_time.lua — point-in-time accessors:
--- Sequence:get_{video,audio}_at(playhead) and get_{next,prev}_{video,audio}.
---
--- Extracted from models/sequence.lua (2.6: that file was 2481 LOC).
--- Methods install onto the Sequence class via M.install(Sequence) so
--- the external surface — both playback_engine, the renderer, and tests
--- — sees no change.
---
--- Methods owned by this module:
---   * Sequence:get_video_at(playhead_frame)
---   * Sequence:get_audio_at(playhead_frame)
---   * Sequence:get_next_video(after_frame)
---   * Sequence:get_prev_video(before_frame)
---   * Sequence:get_next_audio(after_frame)
---   * Sequence:get_prev_audio(before_frame)
---
--- File-local helpers (calc_source_time_us, pick_master_at) live here
--- — only point-in-time accessors call them.

local database = require("core.database")

local function resolve_db()
    local conn = database.get_connection()
    assert(conn, "models.sequence.point_in_time: no database connection")
    return conn
end

local M = {}

function M.install(Sequence)

local function calc_source_time_us(clip, playhead_frame)
    assert(type(playhead_frame) == "number", "Sequence: playhead must be integer")
    assert(type(clip.sequence_start) == "number", "Sequence: sequence_start must be integer")
    assert(type(clip.source_in) == "number", "Sequence: source_in must be integer")

    local offset_frames = playhead_frame - clip.sequence_start
    local source_frame = clip.source_in + offset_frames

    local clip_rate = clip.frame_rate
    assert(clip_rate and clip_rate.fps_numerator and clip_rate.fps_denominator,
        string.format("Sequence: clip %s has no frame_rate", clip.id))

    -- Convert to microseconds: frame * 1000000 * fps_den / fps_num
    local source_time_us = math.floor(
        source_frame * 1000000 * clip_rate.fps_denominator / clip_rate.fps_numerator
    )
    return source_time_us, source_frame
end

-- Master-side get_video_at / get_audio_at helper.
-- V13 master sequences hold media_refs on their tracks; render the
-- media_ref at the requested playhead and shape the result like the
-- nested-sequence path so callers don't need to branch.
local function pick_master_at(self, tracks, playhead_frame, track_kind)
    local Media = require("models.media")
    local conn = resolve_db()
    local results = {}
    for _, track in ipairs(tracks) do
        local stmt = assert(conn:prepare([[
            SELECT id, media_id, source_in_frame, source_out_frame,
                   sequence_start_frame, duration_frames, enabled, volume
              FROM media_refs WHERE track_id = ? LIMIT 1
        ]]), "Sequence:pick_master_at: prepare failed")
        stmt:bind_value(1, track.id)
        local row
        if stmt:exec() and stmt:next() then
            row = {
                id             = stmt:value(0),
                media_id       = stmt:value(1),
                source_in      = stmt:value(2),
                source_out     = stmt:value(3),
                sequence_start = stmt:value(4),
                duration       = stmt:value(5),
                enabled        = stmt:value(6) == 1,
                volume         = stmt:value(7),
            }
        end
        stmt:finalize()
        if row then
            local mr_end = row.sequence_start + row.duration
            if playhead_frame >= row.sequence_start and playhead_frame < mr_end then
                local media = Media.load(row.media_id)
                assert(media, string.format(
                    "Sequence:pick_master_at: media %s not found", tostring(row.media_id)))

                -- Audio MR placement is in master.fps frames (post unify),
                -- but source_in / source_out are file-natural samples. The
                -- "frames are frames" 1:1 helper (calc_source_time_us)
                -- doesn't apply across that unit gap — convert the
                -- master.fps offset to samples for audio rows before
                -- adding to the sample-unit source_in, then express the
                -- file position in microseconds via the audio sample
                -- rate. Video rows still hit the like-unit helper.
                local source_time_us, source_frame
                if track_kind == "AUDIO" then
                    local sr = media.audio_sample_rate
                    assert(type(sr) == "number" and sr > 0, string.format(
                        "Sequence:pick_master_at: media %s has invalid "
                        .. "audio_sample_rate=%s for AUDIO track",
                        tostring(row.media_id), tostring(sr)))
                    local fps_num = self.frame_rate.fps_numerator
                    local fps_den = self.frame_rate.fps_denominator
                    assert(type(fps_num) == "number" and fps_num > 0
                        and type(fps_den) == "number" and fps_den > 0,
                        string.format("Sequence:pick_master_at: master %s "
                            .. "has invalid frame_rate %s/%s",
                            tostring(self.id), tostring(fps_num), tostring(fps_den)))
                    local offset_frames = playhead_frame - row.sequence_start
                    local offset_samples = math.floor(
                        offset_frames * sr * fps_den / fps_num + 0.5)
                    source_frame = row.source_in + offset_samples
                    source_time_us = math.floor(source_frame * 1000000 / sr)
                else
                    local mr_for_calc = {
                        sequence_start = row.sequence_start,
                        source_in      = row.source_in,
                        frame_rate     = self.frame_rate,
                        id             = row.id,
                    }
                    source_time_us, source_frame = calc_source_time_us(
                        mr_for_calc, playhead_frame)
                end

                local mr = {
                    id                = row.id,
                    track_id          = track.id,
                    sequence_id       = self.id,
                    sequence_start    = row.sequence_start,
                    duration          = row.duration,
                    source_in         = row.source_in,
                    source_out        = row.source_out,
                    enabled           = row.enabled,
                    volume            = row.volume,
                    frame_rate        = self.frame_rate,
                    track_type        = track_kind,
                }
                results[#results + 1] = {
                    media_path     = media.file_path,
                    source_time_us = source_time_us,
                    source_frame   = source_frame,
                    clip           = mr,
                    track          = track,
                }
            end
        end
    end
    return results
end

--- Get ALL video clips at position, ordered by track_index ascending.
-- Returns one entry per video track that has a clip at playhead.
-- Renderer iterates highest-index-first for display. Future: composite all layers.
-- @param playhead_frame integer
-- @return list of {media_path, source_time_us, source_frame, clip, track} (may be empty = gap)
function Sequence:get_video_at(playhead_frame)
    assert(type(playhead_frame) == "number",
        "Sequence:get_video_at: playhead_frame must be integer")

    local Track = require("models.track")
    local Clip = require("models.clip")
    local Media = require("models.media")

    local tracks = Track.find_by_sequence(self.id, "VIDEO")
    if not tracks or #tracks == 0 then
        return {}
    end

    -- V13 master sequences hold media_refs (not clips) on their tracks.
    -- Read the media_ref + its media row to materialise the same shape
    -- callers expect from a nested-sequence get_video_at result.
    if self.kind == "master" then
        return pick_master_at(self, tracks, playhead_frame, "VIDEO")
    end

    local results = {}
    -- Tracks are sorted by track_index ASC (V1=1, V2=2, ...; highest = topmost)
    for _, track in ipairs(tracks) do
        local clip = Clip.find_at_time(track.id, playhead_frame)
        if clip then
            local media = Media.load(clip.resolved_media and clip.resolved_media.id)
            assert(media, string.format(
                "Sequence:get_video_at: clip %s references missing media %s",
                clip.id, tostring(clip.resolved_media and clip.resolved_media.id)))

            local source_time_us, source_frame = calc_source_time_us(clip, playhead_frame)

            results[#results + 1] = {
                media_path = media.file_path,
                source_time_us = source_time_us,
                source_frame = source_frame,
                clip = clip,
                track = track,
            }
        end
    end

    return results
end

--- Get all audio clips at position (works for any sequence kind).
-- @param playhead_frame integer
-- @return list of {media_path, source_time_us, source_frame, clip, track, media_fps_num, media_fps_den}
function Sequence:get_audio_at(playhead_frame)
    assert(type(playhead_frame) == "number",
        "Sequence:get_audio_at: playhead_frame must be integer")

    local Track = require("models.track")
    local Clip = require("models.clip")
    local Media = require("models.media")

    local tracks = Track.find_by_sequence(self.id, "AUDIO")
    if not tracks or #tracks == 0 then
        return {}
    end

    if self.kind == "master" then
        return pick_master_at(self, tracks, playhead_frame, "AUDIO")
    end

    local results = {}
    for _, track in ipairs(tracks) do
        local clip = Clip.find_at_time(track.id, playhead_frame)
        if clip then
            local media = Media.load(clip.resolved_media and clip.resolved_media.id)
            assert(media, string.format(
                "Sequence:get_audio_at: audio clip %s references missing media %s",
                clip.id, tostring(clip.resolved_media and clip.resolved_media.id)))

            local source_time_us, source_frame = calc_source_time_us(clip, playhead_frame)

            results[#results + 1] = {
                media_path = media.file_path,
                source_time_us = source_time_us,
                source_frame = source_frame,
                clip = clip,
                track = track,
                -- Media's video fps for "frames are frames" audio conform.
                media_fps_num = media.frame_rate.fps_numerator,
                media_fps_den = media.frame_rate.fps_denominator,
            }
        end
    end

    return results
end

--- Get next video clips (one per track) starting at or after a boundary frame.
-- Used by engine lookahead for pre-buffering. Entry format matches get_video_at.
-- @param after_frame integer: boundary frame (inclusive)
-- @return list of {media_path, source_time_us, source_frame, clip, track}
function Sequence:get_next_video(after_frame)
    assert(type(after_frame) == "number",
        "Sequence:get_next_video: after_frame must be integer")

    local Track = require("models.track")
    local Clip = require("models.clip")
    local Media = require("models.media")

    local tracks = Track.find_by_sequence(self.id, "VIDEO")
    if not tracks or #tracks == 0 then return {} end

    local results = {}
    for _, track in ipairs(tracks) do
        local clip = Clip.find_next_on_track(track.id, after_frame)
        if clip then
            local media = Media.load(clip.resolved_media and clip.resolved_media.id)
            assert(media, string.format(
                "Sequence:get_next_video: clip %s references missing media %s",
                clip.id, tostring(clip.resolved_media and clip.resolved_media.id)))
            -- source_frame at clip start = source_in
            local source_time_us, source_frame = calc_source_time_us(clip, clip.sequence_start)
            results[#results + 1] = {
                media_path = media.file_path,
                source_time_us = source_time_us,
                source_frame = source_frame,
                clip = clip,
                track = track,
            }
        end
    end
    return results
end

--- Get previous video clips (one per track) ending at or before a boundary frame.
-- @param before_frame integer: boundary frame (inclusive upper bound for clip end)
-- @return list of {media_path, source_time_us, source_frame, clip, track}
function Sequence:get_prev_video(before_frame)
    assert(type(before_frame) == "number",
        "Sequence:get_prev_video: before_frame must be integer")

    local Track = require("models.track")
    local Clip = require("models.clip")
    local Media = require("models.media")

    local tracks = Track.find_by_sequence(self.id, "VIDEO")
    if not tracks or #tracks == 0 then return {} end

    local results = {}
    for _, track in ipairs(tracks) do
        local clip = Clip.find_prev_on_track(track.id, before_frame)
        if clip then
            local media = Media.load(clip.resolved_media and clip.resolved_media.id)
            assert(media, string.format(
                "Sequence:get_prev_video: clip %s references missing media %s",
                clip.id, tostring(clip.resolved_media and clip.resolved_media.id)))
            -- Source position at clip END (last frame): reverse playback enters here
            local last_frame = clip.sequence_start + clip.duration - 1
            local source_time_us, source_frame = calc_source_time_us(clip, last_frame)
            results[#results + 1] = {
                media_path = media.file_path,
                source_time_us = source_time_us,
                source_frame = source_frame,
                clip = clip,
                track = track,
            }
        end
    end
    return results
end

--- Get next audio clips (one per track) starting at or after a boundary frame.
-- @param after_frame integer
-- @return list of {media_path, source_time_us, source_frame, clip, track, media_fps_num, media_fps_den}
function Sequence:get_next_audio(after_frame)
    assert(type(after_frame) == "number",
        "Sequence:get_next_audio: after_frame must be integer")

    local Track = require("models.track")
    local Clip = require("models.clip")
    local Media = require("models.media")

    local tracks = Track.find_by_sequence(self.id, "AUDIO")
    if not tracks or #tracks == 0 then return {} end

    local results = {}
    for _, track in ipairs(tracks) do
        local clip = Clip.find_next_on_track(track.id, after_frame)
        if clip then
            local media = Media.load(clip.resolved_media and clip.resolved_media.id)
            assert(media, string.format(
                "Sequence:get_next_audio: clip %s references missing media %s",
                clip.id, tostring(clip.resolved_media and clip.resolved_media.id)))
            local source_time_us, source_frame = calc_source_time_us(clip, clip.sequence_start)
            results[#results + 1] = {
                media_path = media.file_path,
                source_time_us = source_time_us,
                source_frame = source_frame,
                clip = clip,
                track = track,
                media_fps_num = media.frame_rate.fps_numerator,
                media_fps_den = media.frame_rate.fps_denominator,
            }
        end
    end
    return results
end

--- Get previous audio clips (one per track) ending at or before a boundary frame.
-- @param before_frame integer
-- @return list of {media_path, source_time_us, source_frame, clip, track, media_fps_num, media_fps_den}
function Sequence:get_prev_audio(before_frame)
    assert(type(before_frame) == "number",
        "Sequence:get_prev_audio: before_frame must be integer")

    local Track = require("models.track")
    local Clip = require("models.clip")
    local Media = require("models.media")

    local tracks = Track.find_by_sequence(self.id, "AUDIO")
    if not tracks or #tracks == 0 then return {} end

    local results = {}
    for _, track in ipairs(tracks) do
        local clip = Clip.find_prev_on_track(track.id, before_frame)
        if clip then
            local media = Media.load(clip.resolved_media and clip.resolved_media.id)
            assert(media, string.format(
                "Sequence:get_prev_audio: clip %s references missing media %s",
                clip.id, tostring(clip.resolved_media and clip.resolved_media.id)))
            -- Source position at clip END (last frame): reverse playback enters here
            local last_frame = clip.sequence_start + clip.duration - 1
            local source_time_us, source_frame = calc_source_time_us(clip, last_frame)
            results[#results + 1] = {
                media_path = media.file_path,
                source_time_us = source_time_us,
                source_frame = source_frame,
                clip = clip,
                track = track,
                media_fps_num = media.frame_rate.fps_numerator,
                media_fps_den = media.frame_rate.fps_denominator,
            }
        end
    end
    return results
end

end -- M.install

return M
