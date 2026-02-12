--- Mixer: resolves audio clips and mixes into single PCM buffer.
--
-- Responsibilities:
-- - Resolves all audio clips at playhead via Sequence:get_audio_at()
-- - Computes source offsets with "frames are frames" conform
-- - Decodes PCM from each source via media_cache
-- - Mixes all sources into single float buffer with volume scaling
-- - Returns mixed buffer ready for SSE push
--
-- No sequence-kind branching. Masterclips and timelines are resolved uniformly.
--
-- LIFECYCLE: Mixer is stateless per call. Caching and session management
-- stay in audio_playback (SSE/AOP device, transport state, pump scheduling).
--
-- @file mixer.lua

local logger = require("core.logger")
local ffi = require("ffi")

local M = {}

--------------------------------------------------------------------------------
-- Internal: Build audio source list from sequence resolver results.
-- Absorbs the conform + offset logic from playback_controller.resolve_and_set_audio_sources.
--------------------------------------------------------------------------------

--- Build source descriptors from resolved audio clips.
-- @param audio_clips list from Sequence:get_audio_at()
-- @param playhead_frame integer current playhead
-- @param seq_fps_num integer sequence fps numerator
-- @param seq_fps_den integer sequence fps denominator
-- @param media_cache media_cache module reference
-- @return list of source descriptors
local function build_sources(audio_clips, playhead_frame, seq_fps_num, seq_fps_den, media_cache)
    local sources = {}

    -- Check for solo
    local any_soloed = false
    for _, ac in ipairs(audio_clips) do
        if ac.track.soloed then any_soloed = true; break end
    end

    for _, ac in ipairs(audio_clips) do
        local media_info = media_cache.ensure_audio_pooled(ac.media_path)

        local timeline_start_frames = ac.clip.timeline_start
        local source_in_frames = ac.clip.source_in
        local source_out_frames = ac.clip.source_out
        local media_start_tc = media_info and media_info.start_tc or 0

        assert(type(timeline_start_frames) == "number", "mixer: timeline_start must be integer")
        assert(type(source_in_frames) == "number", "mixer: source_in must be integer")
        assert(type(source_out_frames) == "number", "mixer: source_out must be integer")

        local clip_duration_frames = source_out_frames - source_in_frames

        -- Derive seek frame: absolute TC → relative to file start
        local seek_frame = source_in_frames - media_start_tc
        if seek_frame < 0 then
            logger.warn("mixer", string.format(
                "clip %s source_in (%d) before media start_tc (%d), clamping to 0",
                ac.clip.id:sub(1,8), source_in_frames, media_start_tc))
            seek_frame = 0
        end

        -- CLIP rate for source coords
        local clip_fps_num = ac.clip.rate and ac.clip.rate.fps_numerator or seq_fps_num
        local clip_fps_den = ac.clip.rate and ac.clip.rate.fps_denominator or seq_fps_den

        -- Timeline start in microseconds (using SEQUENCE fps)
        local timeline_start_us = math.floor(
            timeline_start_frames * 1000000 * seq_fps_den / seq_fps_num)

        -- Source coords in microseconds using CLIP rate
        local seek_us = math.floor(seek_frame * 1000000 * clip_fps_den / clip_fps_num)
        local source_duration_us = math.floor(
            clip_duration_frames * 1000000 * clip_fps_den / clip_fps_num)

        -- "Frames are frames" audio conform
        local media_fps_num = ac.media_fps_num
        local media_fps_den = ac.media_fps_den
        local media_video_fps = media_fps_num and media_fps_den
            and (media_fps_num / media_fps_den) or nil
        local needs_conform = media_video_fps
            and media_video_fps < 1000
            and math.abs(media_video_fps - seq_fps_num / seq_fps_den) > 0.01

        local source_offset_us
        if needs_conform then
            local offset_tl = playhead_frame - timeline_start_frames
            local conform_source_time_us = seek_us + math.floor(
                offset_tl * 1000000 * media_fps_den / media_fps_num)
            local playhead_time_us = math.floor(
                playhead_frame * 1000000 * seq_fps_den / seq_fps_num)
            source_offset_us = playhead_time_us - conform_source_time_us
        else
            source_offset_us = timeline_start_us - seek_us
        end

        -- Effective volume (solo/mute)
        local effective_volume
        if any_soloed then
            effective_volume = ac.track.soloed and ac.track.volume or 0
        else
            effective_volume = ac.track.muted and 0 or ac.track.volume
        end

        -- Clip end in playback time
        local clip_end_us
        if ac.clip.duration then
            clip_end_us = math.floor(
                (timeline_start_frames + ac.clip.duration) * 1000000 * seq_fps_den / seq_fps_num)
        else
            local timeline_duration_us = math.floor(
                clip_duration_frames * 1000000 * clip_fps_den / clip_fps_num)
            clip_end_us = timeline_start_us + timeline_duration_us
        end

        sources[#sources + 1] = {
            path = ac.media_path,
            source_offset_us = source_offset_us,
            volume = effective_volume,
            duration_us = source_duration_us,
            clip_start_us = timeline_start_us,
            clip_end_us = clip_end_us,
            clip_id = ac.clip.id,
        }
    end

    return sources
end

--- Resolve audio clips at playhead and return source list for audio_playback.
-- This replaces playback_controller.resolve_and_set_audio_sources() clip resolution.
-- @param sequence Sequence object
-- @param playhead_frame integer
-- @param seq_fps_num integer
-- @param seq_fps_den integer
-- @param media_cache media_cache module
-- @return sources list, clip_ids set
function M.resolve_audio_sources(sequence, playhead_frame, seq_fps_num, seq_fps_den, media_cache)
    assert(sequence, "mixer.resolve_audio_sources: sequence is nil")
    assert(type(playhead_frame) == "number",
        "mixer.resolve_audio_sources: playhead_frame must be integer")
    assert(media_cache, "mixer.resolve_audio_sources: media_cache is nil")

    local audio_clips = sequence:get_audio_at(playhead_frame)
    local sources = build_sources(audio_clips, playhead_frame,
        seq_fps_num, seq_fps_den, media_cache)

    -- Build clip ID set for change detection
    local clip_ids = {}
    for _, ac in ipairs(audio_clips) do
        clip_ids[ac.clip.id] = true
    end

    return sources, clip_ids
end

--- Mix multiple audio sources into a single float buffer.
-- Extracted from audio_playback._ensure_pcm_cache() multi-source mixing path.
-- @param sources list of source descriptors (from resolve_audio_sources)
-- @param pb_start number playback time range start (microseconds)
-- @param pb_end number playback time range end (microseconds)
-- @param sample_rate number output sample rate
-- @param channels number output channel count
-- @param media_cache media_cache module
-- @return mix_buf (float*), mix_frames (int), mix_actual_start (us) or nil if no data
function M.mix_sources(sources, pb_start, pb_end, sample_rate, channels, media_cache)
    assert(sources, "mixer.mix_sources: sources is nil")
    assert(type(pb_start) == "number", "mixer.mix_sources: pb_start must be number")
    assert(type(pb_end) == "number", "mixer.mix_sources: pb_end must be number")
    assert(sample_rate and sample_rate > 0, "mixer.mix_sources: sample_rate must be > 0")
    assert(channels and channels > 0, "mixer.mix_sources: channels must be > 0")
    assert(media_cache, "mixer.mix_sources: media_cache is nil")

    if #sources == 0 then
        return nil, 0, pb_start
    end

    -- Single source fast path (no mixing needed, return raw decoded PCM)
    if #sources == 1 then
        local src = sources[1]
        local src_start = math.max(0, pb_start - src.source_offset_us)
        local source_end_us = src.clip_end_us - src.source_offset_us
        local src_end = math.min(source_end_us, pb_end - src.source_offset_us)
        if src_end <= src_start then
            return nil, 0, pb_start
        end

        local pcm_ptr, frames, actual_start = media_cache.get_audio_pcm_for_path(
            src.path, src_start, src_end, sample_rate)

        if not pcm_ptr or not frames or frames <= 0 then
            return nil, 0, pb_start
        end

        -- Apply volume if not unity
        if src.volume ~= 1.0 then
            local float_ptr = ffi.cast("float*", pcm_ptr)
            local n = frames * channels
            local vol = src.volume
            -- Create mixed buffer with volume applied
            local buf = ffi.new("float[?]", n)
            for i = 0, n - 1 do
                buf[i] = float_ptr[i] * vol
            end
            return buf, frames, actual_start + src.source_offset_us
        end

        return pcm_ptr, frames, actual_start + src.source_offset_us
    end

    -- Multi-source mixing path
    local mix_frames = nil
    local mix_buf = nil
    local mix_actual_start = pb_start

    for _, src in ipairs(sources) do
        local src_start = math.max(0, pb_start - src.source_offset_us)
        local source_end_us = src.clip_end_us - src.source_offset_us
        local src_end = math.min(source_end_us, pb_end - src.source_offset_us)
        if src_end <= src_start then goto continue end

        local pcm_ptr, frames, actual_start = media_cache.get_audio_pcm_for_path(
            src.path, src_start, src_end, sample_rate)

        if not pcm_ptr or not frames or frames <= 0 then
            logger.warn("mixer", string.format(
                "Failed to decode audio for '%s' [%.3fs-%.3fs]",
                src.path, src_start / 1000000, src_end / 1000000))
            goto continue
        end

        if not mix_buf then
            mix_frames = frames
            mix_buf = ffi.new("float[?]", frames * channels)
            ffi.fill(mix_buf, ffi.sizeof("float") * frames * channels, 0)
            mix_actual_start = actual_start + src.source_offset_us
        end

        -- Cast raw userdata to float* for sample-level access
        local float_ptr = ffi.cast("float*", pcm_ptr)

        -- Sum with volume scaling
        local n = math.min(frames, mix_frames) * channels
        local vol = src.volume
        for i = 0, n - 1 do
            mix_buf[i] = mix_buf[i] + float_ptr[i] * vol
        end

        ::continue::
    end

    if not mix_buf or not mix_frames or mix_frames <= 0 then
        return nil, 0, pb_start
    end

    return mix_buf, mix_frames, mix_actual_start
end

return M
