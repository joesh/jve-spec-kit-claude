--- Unified Media Cache with Dual Assets
--
-- Responsibilities:
-- - Opens media file TWICE (separate AVFormatContexts) for independent video/audio
-- - Maintains sliding window cache for video frames
-- - Maintains PCM cache for audio around playhead
-- - Provides unified interface for viewer_panel and audio_playback
--
-- Why dual assets:
-- AVFormatContext is NOT thread-safe for seeking. When audio seeks to decode
-- PCM while video is decoding frames, the shared demuxer state corrupts both.
-- Opening twice gives each domain its own demuxer/decoder state.
--
-- @file media_cache.lua

local logger = require("core.logger")
local qt_constants = require("core.qt_constants")

local M = {
    -- Dual assets (independent AVFormatContexts)
    video_asset = nil,
    video_reader = nil,
    audio_asset = nil,
    audio_reader = nil,

    -- Cached asset info (from video_asset)
    asset_info = nil,
    file_path = nil,

    -- Video frame cache (sliding window around playhead)
    video_cache = {
        frames = {},           -- { [frame_idx] = emp_frame }
        window_size = 150,     -- total frames to cache (±75 from playhead = ±2.5s at 30fps)
        center_idx = 0,        -- current center of cache window
        reverse_window_start = nil,
        reverse_window_end = nil,
        bulk_keep_min = nil,
        bulk_keep_max = nil,
        reverse_decode_budget = 60,
    },

    -- Audio PCM cache (single chunk around playhead)
    audio_cache = {
        pcm = nil,             -- EMP PCM handle
        start_us = 0,          -- start time of cached PCM
        end_us = 0,            -- end time of cached PCM
        data_ptr = nil,        -- pointer to PCM data for SSE
        frames = 0,            -- sample frames in cache
    },

    -- Prefetch state (background decode thread)
    last_prefetch_direction = 0,  -- Track direction changes
}

--------------------------------------------------------------------------------
-- Query Functions
--------------------------------------------------------------------------------

function M.is_loaded()
    return M.video_asset ~= nil and M.video_reader ~= nil
end

function M.get_video_asset()
    return M.video_asset
end

function M.get_audio_asset()
    return M.audio_asset
end

function M.get_video_reader()
    return M.video_reader
end

function M.get_audio_reader()
    return M.audio_reader
end

function M.get_asset_info()
    return M.asset_info
end

function M.get_file_path()
    return M.file_path
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

--- Load media file with dual assets
-- @param file_path Path to media file
-- @return asset_info on success
function M.load(file_path)
    assert(file_path, "media_cache.load: file_path is nil")
    assert(type(file_path) == "string", string.format(
        "media_cache.load: file_path must be string, got %s", type(file_path)))
    assert(qt_constants, "media_cache.load: qt_constants not available")
    assert(qt_constants.EMP, "media_cache.load: EMP bindings not available")

    -- Clean up any previous load
    M.unload()

    -- Open VIDEO asset (format context A)
    local video_asset, err = qt_constants.EMP.ASSET_OPEN(file_path)
    assert(video_asset, string.format(
        "media_cache.load: ASSET_OPEN failed for video '%s': %s",
        file_path, err and err.msg or "unknown error"))

    local info = qt_constants.EMP.ASSET_INFO(video_asset)
    assert(info, string.format(
        "media_cache.load: ASSET_INFO failed for '%s'", file_path))
    assert(info.has_video, string.format(
        "media_cache.load: no video stream in '%s'", file_path))

    -- Create video reader
    local video_reader, reader_err = qt_constants.EMP.READER_CREATE(video_asset)
    assert(video_reader, string.format(
        "media_cache.load: READER_CREATE failed for video: %s",
        reader_err and reader_err.msg or "unknown error"))

    M.video_asset = video_asset
    M.video_reader = video_reader
    M.asset_info = info
    M.file_path = file_path

    -- Open AUDIO asset (format context B) - SEPARATE from video
    if info.has_audio then
        local audio_asset, audio_err = qt_constants.EMP.ASSET_OPEN(file_path)
        assert(audio_asset, string.format(
            "media_cache.load: ASSET_OPEN failed for audio '%s': %s",
            file_path, audio_err and audio_err.msg or "unknown error"))

        local audio_reader, areader_err = qt_constants.EMP.READER_CREATE(audio_asset)
        assert(audio_reader, string.format(
            "media_cache.load: READER_CREATE failed for audio: %s",
            areader_err and areader_err.msg or "unknown error"))

        M.audio_asset = audio_asset
        M.audio_reader = audio_reader

        logger.info("media_cache", string.format(
            "Loaded dual assets: video + audio for '%s'", file_path))
    else
        logger.info("media_cache", string.format(
            "Loaded single asset (no audio) for '%s'", file_path))
    end

    logger.info("media_cache", string.format(
        "Media: %dx%d @ %d/%d fps, duration=%.2fs, has_audio=%s",
        info.width, info.height, info.fps_num, info.fps_den,
        info.duration_us / 1000000, tostring(info.has_audio)))

    return info
end

--- Unload all resources
function M.unload()
    -- Stop prefetch thread first (before closing reader)
    if M.video_reader then
        qt_constants.EMP.READER_STOP_PREFETCH(M.video_reader)
    end
    M.last_prefetch_direction = 0
    M.playhead_direction = nil

    -- Release cached video frames
    for idx, frame in pairs(M.video_cache.frames) do
        if frame then
            qt_constants.EMP.FRAME_RELEASE(frame)
        end
    end
    M.video_cache.frames = {}
    M.video_cache.center_idx = 0

    -- Release cached PCM
    if M.audio_cache.pcm then
        qt_constants.EMP.PCM_RELEASE(M.audio_cache.pcm)
        M.audio_cache.pcm = nil
        M.audio_cache.data_ptr = nil
        M.audio_cache.start_us = 0
        M.audio_cache.end_us = 0
        M.audio_cache.frames = 0
    end

    -- Close video reader and asset
    if M.video_reader then
        qt_constants.EMP.READER_CLOSE(M.video_reader)
        M.video_reader = nil
    end
    if M.video_asset then
        qt_constants.EMP.ASSET_CLOSE(M.video_asset)
        M.video_asset = nil
    end

    -- Close audio reader and asset (separate handles)
    if M.audio_reader then
        qt_constants.EMP.READER_CLOSE(M.audio_reader)
        M.audio_reader = nil
    end
    if M.audio_asset then
        qt_constants.EMP.ASSET_CLOSE(M.audio_asset)
        M.audio_asset = nil
    end

    M.asset_info = nil
    M.file_path = nil

    logger.debug("media_cache", "Unloaded all resources")
end

--------------------------------------------------------------------------------
-- Video Frame Access
--------------------------------------------------------------------------------

--- Get video frame by index (from C++ cache or decode)
-- @param frame_idx Frame index to retrieve
-- @return EMP frame handle
function M.get_video_frame(frame_idx)
    assert(M.video_reader, "media_cache.get_video_frame: not loaded (video_reader is nil)")
    assert(frame_idx, "media_cache.get_video_frame: frame_idx is nil")
    assert(type(frame_idx) == "number", string.format(
        "media_cache.get_video_frame: frame_idx must be number, got %s", type(frame_idx)))
    assert(frame_idx >= 0, string.format(
        "media_cache.get_video_frame: frame_idx must be >= 0, got %d", frame_idx))

    -- Let C++ handle caching (prefetch thread fills cache, DecodeAtUS checks cache first)
    -- Don't double-cache in Lua - causes stale handle issues when C++ evicts
    local frame, err = qt_constants.EMP.READER_DECODE_FRAME(
        M.video_reader,
        frame_idx,
        M.asset_info.fps_num,
        M.asset_info.fps_den
    )
    assert(frame, string.format(
        "media_cache.get_video_frame: READER_DECODE_FRAME failed at frame %d: %s",
        frame_idx, err and err.msg or "unknown error"))

    return frame
end

--- Internal: cache a video frame, evicting old frames if needed
function M._cache_video_frame(frame_idx, frame)
    M.video_cache.frames[frame_idx] = frame

    -- Evict frames outside window
    local min_keep, max_keep
    if M.video_cache.bulk_keep_min and M.video_cache.bulk_keep_max then
        min_keep = M.video_cache.bulk_keep_min
        max_keep = M.video_cache.bulk_keep_max
    else
        local half_window = math.floor(M.video_cache.window_size / 2)
        min_keep = frame_idx - half_window
        max_keep = frame_idx + half_window
    end

    for idx, cached_frame in pairs(M.video_cache.frames) do
        if idx < min_keep or idx > max_keep then
            qt_constants.EMP.FRAME_RELEASE(cached_frame)
            M.video_cache.frames[idx] = nil
        end
    end

    M.video_cache.center_idx = frame_idx
end

--- Internal: decode a contiguous window ending at end_frame_idx, avoiding per-frame reverse seeks
function M._ensure_reverse_window(end_frame_idx, backfill_count)
    if not M.video_reader then
        return
    end

    local want = backfill_count or M.video_cache.window_size
    if want < 1 then want = 1 end
    if want > M.video_cache.window_size then want = M.video_cache.window_size end

    local start_frame_idx = end_frame_idx - want
    if start_frame_idx < 0 then start_frame_idx = 0 end

    -- Fast path: already have the current end frame and the cached window still covers it
    if M.video_cache.reverse_window_start ~= nil and M.video_cache.reverse_window_end ~= nil then
        if end_frame_idx >= M.video_cache.reverse_window_start and end_frame_idx <= M.video_cache.reverse_window_end then
            if M.video_cache.frames[end_frame_idx] then
                return
            end
        end
    end

    M.video_cache.reverse_window_start = start_frame_idx
    M.video_cache.reverse_window_end = end_frame_idx

    M.video_cache.bulk_keep_min = start_frame_idx
    M.video_cache.bulk_keep_max = end_frame_idx

    for i = start_frame_idx, end_frame_idx do
        if not M.video_cache.frames[i] then
            local frame = qt_constants.EMP.READER_DECODE_FRAME(M.video_reader, i, M.asset_info.fps_num, M.asset_info.fps_den)
            if frame then
                M._cache_video_frame(i, frame)
            end
        end
    end

    M.video_cache.bulk_keep_min = nil
    M.video_cache.bulk_keep_max = nil
end

--------------------------------------------------------------------------------
-- Audio PCM Access
--------------------------------------------------------------------------------

--- Get audio PCM for time range (from cache or decode)
-- @param start_us Start time in microseconds
-- @param end_us End time in microseconds
-- @return pcm_data_ptr, frames, actual_start_us
function M.get_audio_pcm(start_us, end_us)
    assert(M.audio_reader, "media_cache.get_audio_pcm: not loaded (audio_reader is nil)")
    assert(start_us, "media_cache.get_audio_pcm: start_us is nil")
    assert(end_us, "media_cache.get_audio_pcm: end_us is nil")
    assert(type(start_us) == "number", string.format(
        "media_cache.get_audio_pcm: start_us must be number, got %s", type(start_us)))
    assert(type(end_us) == "number", string.format(
        "media_cache.get_audio_pcm: end_us must be number, got %s", type(end_us)))
    assert(end_us > start_us, string.format(
        "media_cache.get_audio_pcm: end_us (%d) must be > start_us (%d)", end_us, start_us))

    -- Check if requested range is within cache
    if M.audio_cache.pcm and
       start_us >= M.audio_cache.start_us and
       end_us <= M.audio_cache.end_us then
        return M.audio_cache.data_ptr, M.audio_cache.frames, M.audio_cache.start_us
    end

    -- Need to decode new range - release old cache first
    if M.audio_cache.pcm then
        qt_constants.EMP.PCM_RELEASE(M.audio_cache.pcm)
        M.audio_cache.pcm = nil
    end

    -- Convert time to frames for EMP API
    local us_per_frame = (M.asset_info.fps_den * 1000000) / M.asset_info.fps_num
    local frame_start = math.floor(start_us / us_per_frame)
    local frame_end = math.ceil(end_us / us_per_frame)

    -- Decode audio range
    local pcm, err = qt_constants.EMP.READER_DECODE_AUDIO_RANGE(
        M.audio_reader,
        frame_start,
        frame_end,
        M.asset_info.fps_num,
        M.asset_info.fps_den,
        M.asset_info.audio_sample_rate,
        M.asset_info.audio_channels
    )
    assert(pcm, string.format(
        "media_cache.get_audio_pcm: READER_DECODE_AUDIO_RANGE failed [%d-%d]: %s",
        frame_start, frame_end, err and err.msg or "unknown error"))

    -- Cache the result
    local info = qt_constants.EMP.PCM_INFO(pcm)
    M.audio_cache.pcm = pcm
    M.audio_cache.start_us = info.start_time_us
    M.audio_cache.end_us = info.start_time_us + (info.frames * 1000000 / M.asset_info.audio_sample_rate)
    M.audio_cache.data_ptr = qt_constants.EMP.PCM_DATA_PTR(pcm)
    M.audio_cache.frames = info.frames

    logger.debug("media_cache", string.format(
        "Cached audio PCM: %.3fs - %.3fs (%d frames)",
        M.audio_cache.start_us / 1000000,
        M.audio_cache.end_us / 1000000,
        M.audio_cache.frames))

    -- Log codec delay drift (>10ms difference between requested and actual start)
    local drift_us = info.start_time_us - start_us
    if drift_us > 10000 then
        logger.debug("media_cache", string.format(
            "Codec delay: requested=%.3fs, actual=%.3fs, drift=%.1fms",
            start_us / 1000000, info.start_time_us / 1000000, drift_us / 1000))
    end

    return M.audio_cache.data_ptr, M.audio_cache.frames, M.audio_cache.start_us
end

--------------------------------------------------------------------------------
-- Playhead Management
--------------------------------------------------------------------------------

--- Update playhead position (triggers prefetch in travel direction)
-- @param frame_idx Current frame index
-- @param direction -1=reverse, 0=stopped, 1=forward
-- @param speed Playback speed multiplier
function M.set_playhead(frame_idx, direction, speed)
    assert(frame_idx, "media_cache.set_playhead: frame_idx is nil")
    assert(direction, "media_cache.set_playhead: direction is nil")
    assert(speed, "media_cache.set_playhead: speed is nil")
    assert(M.is_loaded(), "media_cache.set_playhead: not loaded (call load() first)")

    -- Store direction for reverse window logic
    M.playhead_direction = direction

    -- Manage background prefetch thread (now has separate decoder - works for both directions)
    if direction ~= M.last_prefetch_direction then
        if direction == 0 then
            -- Stopped: stop prefetch thread
            qt_constants.EMP.READER_STOP_PREFETCH(M.video_reader)
            logger.debug("media_cache", "Prefetch stopped")
        else
            -- Playing: start prefetch (forward or reverse)
            qt_constants.EMP.READER_START_PREFETCH(M.video_reader, direction)
            logger.debug("media_cache", string.format("Prefetch started: direction=%d", direction))
        end
        M.last_prefetch_direction = direction
    end

    -- Update prefetch target (tells background thread where to decode ahead)
    if direction ~= 0 then
        qt_constants.EMP.READER_UPDATE_PREFETCH_TARGET(
            M.video_reader,
            frame_idx,
            M.asset_info.fps_num,
            M.asset_info.fps_den
        )
    end

    -- Update cache center
    M.video_cache.center_idx = frame_idx
end

return M
