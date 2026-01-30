--- Multi-Reader LRU Media Cache
--
-- Responsibilities:
-- - Maintains LRU pool of open readers (max 4 simultaneously open media files)
-- - Each reader has dual AVFormatContexts (video + audio) for seek isolation
-- - activate(path) makes a reader "active" — pool lookup, open if miss, LRU evict if full
-- - Provides video frame decode and audio PCM access for the active reader
--
-- Why LRU pool:
-- Timeline scrubbing clicks between clips on different media files. Without a pool,
-- every clip switch does: unload all → open file ×2 → create reader ×2 (~15-30ms).
-- With the pool, re-activating a recently used file is a table lookup (~0µs).
--
-- Why dual assets per reader:
-- AVFormatContext is NOT thread-safe for seeking. When audio seeks to decode
-- PCM while video is decoding frames, the shared demuxer state corrupts both.
-- Opening twice gives each domain its own demuxer/decoder state.
--
-- @file media_cache.lua

local logger = require("core.logger")
local qt_constants = require("core.qt_constants")

local M = {
    -- LRU reader pool: { [file_path] = pool_entry }
    -- pool_entry = { video_asset, video_reader, audio_asset, audio_reader, info, last_used }
    reader_pool = {},
    max_readers = 4,

    -- Currently active reader path (for get_video_frame/get_audio_pcm)
    active_path = nil,

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
    last_prefetch_direction = 0,
}

--------------------------------------------------------------------------------
-- Internal: Get the active pool entry (asserts if none active)
--------------------------------------------------------------------------------

local function active_entry()
    assert(M.active_path, "media_cache: no active reader (call activate() first)")
    local entry = M.reader_pool[M.active_path]
    assert(entry, string.format(
        "media_cache: active_path '%s' not in pool", M.active_path))
    return entry
end

--------------------------------------------------------------------------------
-- Internal: Open a new reader pair for a file path
--------------------------------------------------------------------------------

local function open_reader(file_path)
    assert(qt_constants, "media_cache.open_reader: qt_constants not available")
    assert(qt_constants.EMP, "media_cache.open_reader: EMP bindings not available")

    -- Open VIDEO asset (format context A)
    local video_asset, err = qt_constants.EMP.ASSET_OPEN(file_path)
    assert(video_asset, string.format(
        "media_cache.open_reader: ASSET_OPEN failed for video '%s': %s",
        file_path, err and err.msg or "unknown error"))

    local info = qt_constants.EMP.ASSET_INFO(video_asset)
    assert(info, string.format(
        "media_cache.open_reader: ASSET_INFO failed for '%s'", file_path))
    assert(info.has_video, string.format(
        "media_cache.open_reader: no video stream in '%s'", file_path))

    -- Create video reader
    local video_reader, reader_err = qt_constants.EMP.READER_CREATE(video_asset)
    assert(video_reader, string.format(
        "media_cache.open_reader: READER_CREATE failed for video: %s",
        reader_err and reader_err.msg or "unknown error"))

    local entry = {
        video_asset = video_asset,
        video_reader = video_reader,
        audio_asset = nil,
        audio_reader = nil,
        info = info,
        last_used = os.clock(),
    }

    -- Open AUDIO asset (format context B) - SEPARATE from video
    if info.has_audio then
        local audio_asset, audio_err = qt_constants.EMP.ASSET_OPEN(file_path)
        assert(audio_asset, string.format(
            "media_cache.open_reader: ASSET_OPEN failed for audio '%s': %s",
            file_path, audio_err and audio_err.msg or "unknown error"))

        local audio_reader, areader_err = qt_constants.EMP.READER_CREATE(audio_asset)
        assert(audio_reader, string.format(
            "media_cache.open_reader: READER_CREATE failed for audio: %s",
            areader_err and areader_err.msg or "unknown error"))

        entry.audio_asset = audio_asset
        entry.audio_reader = audio_reader

        logger.info("media_cache", string.format(
            "Opened dual assets: video + audio for '%s'", file_path))
    else
        logger.info("media_cache", string.format(
            "Opened single asset (no audio) for '%s'", file_path))
    end

    logger.info("media_cache", string.format(
        "Media: %dx%d @ %d/%d fps, duration=%.2fs, has_audio=%s",
        info.width, info.height, info.fps_num, info.fps_den,
        info.duration_us / 1000000, tostring(info.has_audio)))

    return entry
end

--------------------------------------------------------------------------------
-- Internal: Close a pool entry (release all its resources)
--------------------------------------------------------------------------------

local function close_entry(entry)
    -- Stop prefetch thread first
    if entry.video_reader then
        qt_constants.EMP.READER_STOP_PREFETCH(entry.video_reader)
    end

    -- Close video reader and asset
    if entry.video_reader then
        qt_constants.EMP.READER_CLOSE(entry.video_reader)
        entry.video_reader = nil
    end
    if entry.video_asset then
        qt_constants.EMP.ASSET_CLOSE(entry.video_asset)
        entry.video_asset = nil
    end

    -- Close audio reader and asset
    if entry.audio_reader then
        qt_constants.EMP.READER_CLOSE(entry.audio_reader)
        entry.audio_reader = nil
    end
    if entry.audio_asset then
        qt_constants.EMP.ASSET_CLOSE(entry.audio_asset)
        entry.audio_asset = nil
    end

    entry.info = nil
end

--------------------------------------------------------------------------------
-- Internal: Find and evict the LRU entry from the pool
--------------------------------------------------------------------------------

local function evict_lru()
    local oldest_path = nil
    local oldest_time = math.huge

    for path, entry in pairs(M.reader_pool) do
        -- Never evict the active reader
        if path ~= M.active_path and entry.last_used < oldest_time then
            oldest_time = entry.last_used
            oldest_path = path
        end
    end

    assert(oldest_path, "media_cache.evict_lru: no evictable entry (all are active?)")

    local entry = M.reader_pool[oldest_path]
    close_entry(entry)
    M.reader_pool[oldest_path] = nil

    logger.debug("media_cache", string.format("Evicted LRU reader: %s", oldest_path))
end

--------------------------------------------------------------------------------
-- Internal: Release Lua-side caches (video frames, audio PCM)
-- Called when switching active reader so stale frames aren't displayed.
--------------------------------------------------------------------------------

local function release_lua_caches()
    -- Release cached video frames
    for idx, frame in pairs(M.video_cache.frames) do
        if frame then
            qt_constants.EMP.FRAME_RELEASE(frame)
        end
    end
    M.video_cache.frames = {}
    M.video_cache.center_idx = 0
    M.video_cache.reverse_window_start = nil
    M.video_cache.reverse_window_end = nil

    -- Release cached PCM
    if M.audio_cache.pcm then
        qt_constants.EMP.PCM_RELEASE(M.audio_cache.pcm)
        M.audio_cache.pcm = nil
        M.audio_cache.data_ptr = nil
        M.audio_cache.start_us = 0
        M.audio_cache.end_us = 0
        M.audio_cache.frames = 0
    end

    -- Reset prefetch state
    M.last_prefetch_direction = 0
    M.playhead_direction = nil
end

--------------------------------------------------------------------------------
-- Query Functions
--------------------------------------------------------------------------------

function M.is_loaded()
    return M.active_path ~= nil and M.reader_pool[M.active_path] ~= nil
end

function M.get_video_asset()
    if not M.is_loaded() then return nil end
    return active_entry().video_asset
end

function M.get_audio_asset()
    if not M.is_loaded() then return nil end
    return active_entry().audio_asset
end

function M.get_video_reader()
    if not M.is_loaded() then return nil end
    return active_entry().video_reader
end

function M.get_audio_reader()
    if not M.is_loaded() then return nil end
    return active_entry().audio_reader
end

function M.get_asset_info()
    if not M.is_loaded() then return nil end
    return active_entry().info
end

function M.get_file_path()
    return M.active_path
end

--------------------------------------------------------------------------------
-- Lifecycle: Pool-based activate / cleanup
--------------------------------------------------------------------------------

--- Activate a media file as the current source.
-- If already in the pool, promote to active (no I/O).
-- If not in pool, open and add. LRU-evict if pool full.
-- @param file_path Path to media file
-- @return asset_info
function M.activate(file_path)
    assert(file_path, "media_cache.activate: file_path is nil")
    assert(type(file_path) == "string", string.format(
        "media_cache.activate: file_path must be string, got %s", type(file_path)))

    -- Fast path: already active
    if file_path == M.active_path then
        local entry = M.reader_pool[file_path]
        assert(entry, "media_cache.activate: active_path in pool but entry missing")
        entry.last_used = os.clock()
        return entry.info
    end

    -- Stop old reader's prefetch thread before switching.
    -- release_lua_caches resets Lua-side last_prefetch_direction but doesn't
    -- stop the C++ thread — leaving it decoding at a stale position.
    if M.active_path and M.last_prefetch_direction ~= 0 then
        local old_entry = M.reader_pool[M.active_path]
        if old_entry and old_entry.video_reader then
            qt_constants.EMP.READER_STOP_PREFETCH(old_entry.video_reader)
        end
    end

    -- Release Lua-side caches from old active reader
    if M.active_path then
        release_lua_caches()
    end

    -- Check pool for existing entry
    local entry = M.reader_pool[file_path]
    if entry then
        -- Pool hit — promote to active
        entry.last_used = os.clock()
        M.active_path = file_path
        logger.debug("media_cache", string.format("Pool hit: %s", file_path))
        return entry.info
    end

    -- Pool miss — need to open. Evict if full.
    local pool_count = 0
    for _ in pairs(M.reader_pool) do pool_count = pool_count + 1 end
    if pool_count >= M.max_readers then
        evict_lru()
    end

    -- Open new reader pair
    entry = open_reader(file_path)
    M.reader_pool[file_path] = entry
    M.active_path = file_path

    logger.debug("media_cache", string.format("Pool miss, opened: %s (pool size=%d)",
        file_path, pool_count + 1))

    return entry.info
end

--- Legacy load() — calls activate() for backward compat with source-mode callers.
-- @param file_path Path to media file
-- @return asset_info
function M.load(file_path)
    return M.activate(file_path)
end

--- Legacy unload() — releases the active reader's Lua caches but keeps it pooled.
-- For full cleanup, use M.cleanup().
function M.unload()
    release_lua_caches()
    -- Note: does NOT remove from pool — that's the whole point of the LRU cache.
    -- Active path stays set so is_loaded() returns true.
    logger.debug("media_cache", "Unloaded Lua caches (reader stays pooled)")
end

--- Release ALL pooled readers and reset state.
-- Called on application exit or when switching projects.
function M.cleanup()
    release_lua_caches()

    for path, entry in pairs(M.reader_pool) do
        close_entry(entry)
    end
    M.reader_pool = {}
    M.active_path = nil

    logger.debug("media_cache", "Cleaned up all pooled readers")
end

--------------------------------------------------------------------------------
-- Video Frame Access
--------------------------------------------------------------------------------

--- Get video frame by index (from C++ cache or decode)
-- @param frame_idx Frame index to retrieve
-- @return EMP frame handle
function M.get_video_frame(frame_idx)
    assert(M.is_loaded(), "media_cache.get_video_frame: not loaded (call activate() first)")
    assert(frame_idx, "media_cache.get_video_frame: frame_idx is nil")
    assert(type(frame_idx) == "number", string.format(
        "media_cache.get_video_frame: frame_idx must be number, got %s", type(frame_idx)))
    assert(frame_idx >= 0, string.format(
        "media_cache.get_video_frame: frame_idx must be >= 0, got %d", frame_idx))

    local entry = active_entry()

    -- Let C++ handle caching (prefetch thread fills cache, DecodeAtUS checks cache first)
    -- Don't double-cache in Lua - causes stale handle issues when C++ evicts
    local frame, err = qt_constants.EMP.READER_DECODE_FRAME(
        entry.video_reader,
        frame_idx,
        entry.info.fps_num,
        entry.info.fps_den
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
    if not M.is_loaded() then
        return
    end

    local entry = active_entry()
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
            local frame = qt_constants.EMP.READER_DECODE_FRAME(
                entry.video_reader, i, entry.info.fps_num, entry.info.fps_den)
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
    assert(M.is_loaded(), "media_cache.get_audio_pcm: not loaded (call activate() first)")
    local entry = active_entry()
    assert(entry.audio_reader,
        "media_cache.get_audio_pcm: active reader has no audio_reader")
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
    local us_per_frame = (entry.info.fps_den * 1000000) / entry.info.fps_num
    local frame_start = math.floor(start_us / us_per_frame)
    local frame_end = math.ceil(end_us / us_per_frame)

    -- Decode audio range
    local pcm, err = qt_constants.EMP.READER_DECODE_AUDIO_RANGE(
        entry.audio_reader,
        frame_start,
        frame_end,
        entry.info.fps_num,
        entry.info.fps_den,
        entry.info.audio_sample_rate,
        entry.info.audio_channels
    )
    assert(pcm, string.format(
        "media_cache.get_audio_pcm: READER_DECODE_AUDIO_RANGE failed [%d-%d]: %s",
        frame_start, frame_end, err and err.msg or "unknown error"))

    -- Cache the result
    local info = qt_constants.EMP.PCM_INFO(pcm)
    M.audio_cache.pcm = pcm
    M.audio_cache.start_us = info.start_time_us
    M.audio_cache.end_us = info.start_time_us + (info.frames * 1000000 / entry.info.audio_sample_rate)
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
    assert(M.is_loaded(), "media_cache.set_playhead: not loaded (call activate() first)")

    local entry = active_entry()

    -- Store direction for reverse window logic
    M.playhead_direction = direction

    -- Manage background prefetch thread (now has separate decoder - works for both directions)
    if direction ~= M.last_prefetch_direction then
        if direction == 0 then
            -- Stopped: stop prefetch thread
            qt_constants.EMP.READER_STOP_PREFETCH(entry.video_reader)
            logger.debug("media_cache", "Prefetch stopped")
        else
            -- Playing: start prefetch (forward or reverse)
            qt_constants.EMP.READER_START_PREFETCH(entry.video_reader, direction)
            logger.debug("media_cache", string.format("Prefetch started: direction=%d", direction))
        end
        M.last_prefetch_direction = direction
    end

    -- Update prefetch target (tells background thread where to decode ahead)
    if direction ~= 0 then
        qt_constants.EMP.READER_UPDATE_PREFETCH_TARGET(
            entry.video_reader,
            frame_idx,
            entry.info.fps_num,
            entry.info.fps_den
        )
    end

    -- Update cache center
    M.video_cache.center_idx = frame_idx
end

return M
