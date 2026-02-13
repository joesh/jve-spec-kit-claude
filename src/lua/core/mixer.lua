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

local ffi = require("ffi")

local M = {}

--------------------------------------------------------------------------------
-- Time mapping: playback ↔ source with conform speed ratio
--
-- General formula: src_time = seek_us + (pb_time - clip_start_us) * speed_ratio
-- When speed_ratio=1.0 this degrades to: src_time = pb_time - source_offset_us
-- (where source_offset_us = clip_start_us - seek_us)
--------------------------------------------------------------------------------

--- Map playback time to source time for a source descriptor.
function M.pb_to_source(src, pb_time)
    assert(type(src.seek_us) == "number", "mixer.pb_to_source: src.seek_us must be number")
    assert(type(src.clip_start_us) == "number", "mixer.pb_to_source: src.clip_start_us must be number")
    assert(src.speed_ratio and src.speed_ratio > 0, "mixer.pb_to_source: src.speed_ratio must be > 0")
    return src.seek_us + (pb_time - src.clip_start_us) * src.speed_ratio
end

--- Map source time back to playback time for a source descriptor.
function M.source_to_pb(src, src_time)
    assert(type(src.seek_us) == "number", "mixer.source_to_pb: src.seek_us must be number")
    assert(type(src.clip_start_us) == "number", "mixer.source_to_pb: src.clip_start_us must be number")
    assert(src.speed_ratio and src.speed_ratio > 0, "mixer.source_to_pb: src.speed_ratio must be > 0")
    return src.clip_start_us + (src_time - src.seek_us) / src.speed_ratio
end

--- Resample PCM via linear interpolation (conform speed change).
-- @param input_ptr float* input PCM buffer
-- @param in_frames integer number of input frames
-- @param out_frames integer number of output frames
-- @param channels integer channel count
-- @return float* resampled buffer, integer out_frames
local function resample_linear(input_ptr, in_frames, out_frames, channels)
    if in_frames == out_frames then
        return input_ptr, out_frames
    end
    assert(in_frames > 0,
        string.format("mixer.resample_linear: in_frames must be > 0, got %d", in_frames))
    assert(out_frames > 0,
        string.format("mixer.resample_linear: out_frames must be > 0, got %d", out_frames))

    local float_in = ffi.cast("float*", input_ptr)
    local buf = ffi.new("float[?]", out_frames * channels)
    local ratio = in_frames / out_frames  -- > 1.0 when speeding up (compressing)

    for i = 0, out_frames - 1 do
        local src_pos = i * ratio
        local idx = math.floor(src_pos)
        local frac = src_pos - idx

        if idx + 1 < in_frames then
            for ch = 0, channels - 1 do
                local s0 = float_in[idx * channels + ch]
                local s1 = float_in[(idx + 1) * channels + ch]
                buf[i * channels + ch] = s0 + (s1 - s0) * frac
            end
        else
            for ch = 0, channels - 1 do
                buf[i * channels + ch] = float_in[math.min(idx, in_frames - 1) * channels + ch]
            end
        end
    end

    return buf, out_frames
end

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

    local seq_fps = seq_fps_num / seq_fps_den

    for _, ac in ipairs(audio_clips) do
        local media_info = media_cache.ensure_audio_pooled(ac.media_path)
        assert(media_info, string.format(
            "mixer.build_sources: ensure_audio_pooled returned nil for %s", ac.media_path))

        local timeline_start_frames = ac.clip.timeline_start
        local source_in_frames = ac.clip.source_in
        local source_out_frames = ac.clip.source_out
        -- start_tc may be nil for files without embedded timecode; nil means file starts at 0
        local media_start_tc = media_info.start_tc or 0

        assert(type(timeline_start_frames) == "number", "mixer: timeline_start must be integer")
        assert(type(source_in_frames) == "number", "mixer: source_in must be integer")
        assert(type(source_out_frames) == "number", "mixer: source_out must be integer")

        local clip_duration_frames = source_out_frames - source_in_frames

        -- Derive seek frame: absolute TC → relative to file start
        local seek_frame = source_in_frames - media_start_tc
        assert(seek_frame >= 0, string.format(
            "mixer.build_sources: clip %s seek_frame=%d < 0 (source_in=%d, media_start_tc=%d)",
            ac.clip.id, seek_frame, source_in_frames, media_start_tc))

        -- CLIP rate for source coords — clips MUST have rate (invariant from Rational Refactor)
        assert(ac.clip.rate and ac.clip.rate.fps_numerator and ac.clip.rate.fps_denominator,
            string.format("mixer.build_sources: clip %s has no rate", ac.clip.id))
        local clip_fps_num = ac.clip.rate.fps_numerator
        local clip_fps_den = ac.clip.rate.fps_denominator

        -- Timeline start in microseconds (using SEQUENCE fps)
        local timeline_start_us = math.floor(
            timeline_start_frames * 1000000 * seq_fps_den / seq_fps_num)

        -- Source coords in microseconds using CLIP rate
        local seek_us = math.floor(seek_frame * 1000000 * clip_fps_den / clip_fps_num)
        local source_duration_us = math.floor(
            clip_duration_frames * 1000000 * clip_fps_den / clip_fps_num)

        -- "Frames are frames" audio conform: speed_ratio = seq_fps / media_video_fps
        -- For same-fps or audio-only (rate >= 1000), speed_ratio = 1.0 (no conform).
        local media_fps_num = ac.media_fps_num
        local media_fps_den = ac.media_fps_den
        local media_video_fps = media_fps_num and media_fps_den
            and (media_fps_num / media_fps_den) or nil
        local needs_conform = media_video_fps
            and media_video_fps < 1000
            and math.abs(media_video_fps - seq_fps) > 0.01

        local speed_ratio = 1.0
        if needs_conform then
            speed_ratio = seq_fps / media_video_fps
        end

        -- source_offset_us: backward-compat linear offset (exact only for speed_ratio=1.0).
        -- For conform clips, computed at playhead for change detection / legacy consumers.
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
            seek_us = seek_us,
            speed_ratio = speed_ratio,
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

--- Decode + conform a single source for a playback time window.
-- Reads from the correct source position (scaled by speed_ratio),
-- then resamples if conform is needed so output sample count matches
-- the playback time window at the device sample rate.
-- @param src source descriptor
-- @param pb_start playback start (us)
-- @param pb_end playback end (us)
-- @param sample_rate output sample rate
-- @param channels output channel count
-- @param media_cache media_cache module
-- @return pcm_ptr, out_frames, pb_actual_start  or nil,0,pb_start
local function decode_source(src, pb_start, pb_end, sample_rate, channels, media_cache)
    local speed = src.speed_ratio
    assert(speed and speed > 0,
        "mixer.decode_source: speed_ratio must be > 0")
    assert(type(src.seek_us) == "number",
        "mixer.decode_source: source missing seek_us")
    assert(type(src.clip_start_us) == "number",
        "mixer.decode_source: source missing clip_start_us")
    assert(src.clip_end_us,
        "mixer.decode_source: source missing clip_end_us")

    -- Map playback range → source range
    local src_start = math.max(0, M.pb_to_source(src, pb_start))
    local source_end_us = M.pb_to_source(src, src.clip_end_us)
    local src_end = math.min(source_end_us, M.pb_to_source(src, pb_end))

    if src_end <= src_start then
        return nil, 0, pb_start
    end

    local pcm_ptr, frames, actual_start = media_cache.get_audio_pcm_for_path(
        src.path, src_start, src_end, sample_rate)

    assert(pcm_ptr and frames and frames > 0, string.format(
        "mixer.decode_source: PCM decode failed for '%s' [%.3fs-%.3fs] (ptr=%s frames=%s)",
        src.path, src_start / 1000000, src_end / 1000000,
        tostring(pcm_ptr), tostring(frames)))

    local pb_actual_start = M.source_to_pb(src, actual_start)

    -- Conform: resample source frames → output frames (speed_ratio != 1.0)
    if math.abs(speed - 1.0) > 0.001 then
        local out_frames = math.max(1, math.floor(frames / speed))
        pcm_ptr, frames = resample_linear(pcm_ptr, frames, out_frames, channels)
    end

    return pcm_ptr, frames, pb_actual_start
end

--- Mix multiple audio sources into a single float buffer.
-- Handles conform (speed_ratio != 1.0) via decode_source.
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

    -- Single source fast path
    if #sources == 1 then
        local src = sources[1]
        local pcm_ptr, frames, pb_actual_start =
            decode_source(src, pb_start, pb_end, sample_rate, channels, media_cache)

        if not pcm_ptr or frames <= 0 then
            return nil, 0, pb_start
        end

        -- Apply volume if not unity
        if src.volume ~= 1.0 then
            local float_ptr = ffi.cast("float*", pcm_ptr)
            local n = frames * channels
            local vol = src.volume
            local buf = ffi.new("float[?]", n)
            for i = 0, n - 1 do
                buf[i] = float_ptr[i] * vol
            end
            return buf, frames, pb_actual_start
        end

        return pcm_ptr, frames, pb_actual_start
    end

    -- Multi-source mixing path
    local mix_frames = nil
    local mix_buf = nil
    local mix_actual_start = pb_start

    for _, src in ipairs(sources) do
        local pcm_ptr, frames, pb_actual_start =
            decode_source(src, pb_start, pb_end, sample_rate, channels, media_cache)

        if not pcm_ptr or frames <= 0 then goto continue end

        if not mix_buf then
            mix_frames = frames
            mix_buf = ffi.new("float[?]", frames * channels)
            ffi.fill(mix_buf, ffi.sizeof("float") * frames * channels, 0)
            mix_actual_start = pb_actual_start
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
