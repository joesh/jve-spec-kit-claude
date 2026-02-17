--- Multi-Reader LRU Media Cache with Per-View Contexts
--
-- Responsibilities:
-- - Maintains LRU pool of open readers (max 8 simultaneously open media files)
-- - Each reader has dual AVFormatContexts (video + audio) for seek isolation
-- - Per-context state: active_path, video_cache, prefetch direction
-- - Shared reader_pool benefits all contexts (LRU eviction skips active paths)
-- - ensure_audio_pooled(path) opens a reader for audio without changing any context
--
-- Context model:
-- Each monitor (source_monitor, timeline_monitor) creates its own context via create_context().
-- Contexts hold per-view state (active_path, video_cache, prefetch).
-- The shared reader_pool is context-agnostic — readers are shared across contexts.
--
-- @file media_cache.lua

local logger = require("core.logger")
local qt_constants = require("core.qt_constants")

-- Forward declarations for functions used before definition
local release_context_caches

local M = {
    -- LRU reader pool: { [file_path] = pool_entry }
    -- pool_entry = { video_asset, video_reader, audio_asset, audio_reader, info,
    --               audio_cache, last_used }
    reader_pool = {},
    max_readers = 8,

    -- Per-context state: { [context_id] = context }
    contexts = {},

    -- Offline registry: { [file_path] = { error_code, error_msg, path, first_seen } }
    -- Populated when ASSET_OPEN fails for any filesystem reason.
    -- Cleared on cleanup() / project change.
    -- TODO: Register FSEvents interest for each offline path to detect when files
    -- come back online. Also watch online paths to detect deletion/modification.
    _offline_registry = {},
}

--------------------------------------------------------------------------------
-- Internal: Create a fresh per-context state table
--------------------------------------------------------------------------------

local function new_context_state()
    return {
        active_path = nil,
        video_cache = {
            frames = {},
            window_size = 150,
            center_idx = 0,
            reverse_window_start = nil,
            reverse_window_end = nil,
            bulk_keep_min = nil,
            bulk_keep_max = nil,
            reverse_decode_budget = 60,
        },
        audio_cache = {
            pcm = nil,
            start_us = 0,
            end_us = 0,
            data_ptr = nil,
            frames = 0,
        },
        last_prefetch_direction = 0,
        playhead_direction = nil,
    }
end

--------------------------------------------------------------------------------
-- Context Management
--------------------------------------------------------------------------------

--- Create a new per-view context.
-- @param context_id string unique ID for this view
function M.create_context(context_id)
    assert(context_id, "media_cache.create_context: context_id is nil")
    assert(not M.contexts[context_id], string.format(
        "media_cache.create_context: context '%s' already exists", context_id))
    M.contexts[context_id] = new_context_state()
    logger.debug("media_cache", string.format("Created context '%s'", context_id))
end

--- Destroy a per-view context (releases its caches).
-- @param context_id string
function M.destroy_context(context_id)
    assert(context_id, "media_cache.destroy_context: context_id is nil")
    local ctx = M.contexts[context_id]
    assert(ctx, string.format(
        "media_cache.destroy_context: context '%s' does not exist (double-destroy?)", context_id))

    release_context_caches(ctx)
    M.contexts[context_id] = nil
    logger.debug("media_cache", string.format("Destroyed context '%s'", context_id))
end

--- Get context, creating lazily if needed.
-- @param context_id string
-- @return context table
local function get_context(context_id)
    assert(context_id, "media_cache: context_id is required")
    local ctx = M.contexts[context_id]
    if not ctx then
        -- Lazy creation for callers that haven't explicitly created a context
        M.contexts[context_id] = new_context_state()
        ctx = M.contexts[context_id]
    end
    return ctx
end

--------------------------------------------------------------------------------
-- Internal: Get pool entry for a context's active path
--------------------------------------------------------------------------------

local function context_active_entry(ctx)
    assert(ctx.active_path, "media_cache: no active reader (call activate() first)")
    local entry = M.reader_pool[ctx.active_path]
    assert(entry, string.format(
        "media_cache: active_path '%s' not in pool", ctx.active_path))
    return entry
end

--------------------------------------------------------------------------------
-- Internal: Create a fresh per-entry audio cache
--------------------------------------------------------------------------------

local function new_audio_cache()
    return { pcm = nil, start_us = 0, end_us = 0, data_ptr = nil, frames = 0 }
end

--------------------------------------------------------------------------------
-- Internal: Release a per-entry audio cache
--------------------------------------------------------------------------------

local function release_entry_audio_cache(entry)
    if entry.audio_cache and entry.audio_cache.pcm then
        qt_constants.EMP.PCM_RELEASE(entry.audio_cache.pcm)
        entry.audio_cache.pcm = nil
        entry.audio_cache.data_ptr = nil
        entry.audio_cache.start_us = 0
        entry.audio_cache.end_us = 0
        entry.audio_cache.frames = 0
    end
end

--------------------------------------------------------------------------------
-- Internal: Open a new reader pair for a file path
-- Supports both video+audio and audio-only files.
--------------------------------------------------------------------------------

local function open_reader(file_path)
    assert(qt_constants, "media_cache.open_reader: qt_constants not available")
    assert(qt_constants.EMP, "media_cache.open_reader: EMP bindings not available")

    local first_asset, err = qt_constants.EMP.ASSET_OPEN(file_path)
    if not first_asset then
        local entry = {
            error_code = err and err.code or "Unknown",
            error_msg = err and err.msg or "unknown error",
            path = file_path,
            first_seen = os.clock(),
        }
        M._offline_registry[file_path] = entry
        logger.warn("media_cache", string.format(
            "Media offline: '%s' (%s: %s)", file_path, entry.error_code, entry.error_msg))
        return nil, entry
    end

    local info = qt_constants.EMP.ASSET_INFO(first_asset)
    assert(info, string.format(
        "media_cache.open_reader: ASSET_INFO failed for '%s'", file_path))
    assert(info.has_video or info.has_audio, string.format(
        "media_cache.open_reader: no video or audio stream in '%s'", file_path))

    local entry = {
        video_asset = nil,
        video_reader = nil,
        audio_asset = nil,
        audio_reader = nil,
        info = info,
        audio_cache = new_audio_cache(),
        last_used = os.clock(),
    }

    if info.has_video then
        entry.video_asset = first_asset
        local video_reader, reader_err = qt_constants.EMP.READER_CREATE(first_asset)
        assert(video_reader, string.format(
            "media_cache.open_reader: READER_CREATE failed for video: %s",
            reader_err and reader_err.msg or "unknown error"))
        entry.video_reader = video_reader
    end

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

        if info.has_video then
            logger.info("media_cache", string.format(
                "Opened dual assets: video + audio for '%s'", file_path))
        else
            logger.info("media_cache", string.format(
                "Opened audio-only asset for '%s'", file_path))
        end
    else
        logger.info("media_cache", string.format(
            "Opened single asset (no audio) for '%s'", file_path))
    end

    if not info.has_video then
        qt_constants.EMP.ASSET_CLOSE(first_asset)
    end

    if info.has_video then
        logger.info("media_cache", string.format(
            "Media: %dx%d @ %d/%d fps, duration=%.2fs, has_audio=%s",
            info.width, info.height, info.fps_num, info.fps_den,
            info.duration_us / 1000000, tostring(info.has_audio)))
    else
        logger.info("media_cache", string.format(
            "Audio-only: duration=%.2fs, sample_rate=%d, channels=%d",
            info.duration_us / 1000000,
            info.audio_sample_rate or 0, info.audio_channels or 0))
    end

    return entry
end

--------------------------------------------------------------------------------
-- Internal: Close a pool entry (release all its resources)
--------------------------------------------------------------------------------

local function close_entry(entry)
    if entry.video_reader then
        qt_constants.EMP.READER_STOP_PREFETCH(entry.video_reader)
    end

    release_entry_audio_cache(entry)

    if entry.video_reader then
        qt_constants.EMP.READER_CLOSE(entry.video_reader)
        entry.video_reader = nil
    end
    if entry.video_asset then
        qt_constants.EMP.ASSET_CLOSE(entry.video_asset)
        entry.video_asset = nil
    end
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
-- Internal: Collect all active paths across contexts (for LRU eviction safety)
--------------------------------------------------------------------------------

local function collect_active_paths()
    local paths = {}
    for _, ctx in pairs(M.contexts) do
        if ctx.active_path then
            paths[ctx.active_path] = true
        end
    end
    return paths
end

--------------------------------------------------------------------------------
-- Internal: Find and evict the LRU entry from the pool
--------------------------------------------------------------------------------

local function evict_lru()
    local active_paths = collect_active_paths()
    local oldest_path = nil
    local oldest_time = math.huge

    for path, entry in pairs(M.reader_pool) do
        -- Never evict any context's active reader
        if not active_paths[path] and entry.last_used < oldest_time then
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
-- Internal: Count pool entries
--------------------------------------------------------------------------------

local function pool_count()
    local count = 0
    for _ in pairs(M.reader_pool) do count = count + 1 end
    return count
end

--------------------------------------------------------------------------------
-- Internal: Ensure path is in pool (open if needed, LRU evict if full).
-- Does NOT change any context's active_path.
-- @return pool_entry
--------------------------------------------------------------------------------

local function ensure_in_pool(file_path)
    -- Fast-path: already known offline
    if M._offline_registry[file_path] then
        return nil
    end

    local entry = M.reader_pool[file_path]
    if entry then
        entry.last_used = os.clock()
        return entry
    end

    if pool_count() >= M.max_readers then
        evict_lru()
    end

    entry = open_reader(file_path)
    if not entry then
        return nil  -- offline; open_reader already registered in _offline_registry
    end
    M.reader_pool[file_path] = entry

    logger.debug("media_cache", string.format("Pool miss (ensure_in_pool), opened: %s", file_path))

    return entry
end

--------------------------------------------------------------------------------
-- Internal: Release Lua-side caches for a context
--------------------------------------------------------------------------------

release_context_caches = function(ctx)
    -- Release cached video frames
    for idx, frame in pairs(ctx.video_cache.frames) do
        if frame then
            qt_constants.EMP.FRAME_RELEASE(frame)
        end
    end
    ctx.video_cache.frames = {}
    ctx.video_cache.center_idx = 0
    ctx.video_cache.reverse_window_start = nil
    ctx.video_cache.reverse_window_end = nil

    -- Release context audio cache
    if ctx.audio_cache.pcm then
        qt_constants.EMP.PCM_RELEASE(ctx.audio_cache.pcm)
        ctx.audio_cache.pcm = nil
        ctx.audio_cache.data_ptr = nil
        ctx.audio_cache.start_us = 0
        ctx.audio_cache.end_us = 0
        ctx.audio_cache.frames = 0
    end

    ctx.last_prefetch_direction = 0
    ctx.playhead_direction = nil
end

--------------------------------------------------------------------------------
-- Query Functions (per-context)
--------------------------------------------------------------------------------

--- Check if context has an active reader.
-- @param context_id string
function M.is_loaded(context_id)
    local ctx = get_context(context_id)
    return ctx.active_path ~= nil and M.reader_pool[ctx.active_path] ~= nil
end

function M.get_video_asset(context_id)
    local ctx = get_context(context_id)
    if not ctx.active_path then return nil end
    return context_active_entry(ctx).video_asset
end

function M.get_audio_asset(context_id)
    local ctx = get_context(context_id)
    if not ctx.active_path then return nil end
    return context_active_entry(ctx).audio_asset
end

function M.get_video_reader(context_id)
    local ctx = get_context(context_id)
    if not ctx.active_path then return nil end
    return context_active_entry(ctx).video_reader
end

function M.get_audio_reader(context_id)
    local ctx = get_context(context_id)
    if not ctx.active_path then return nil end
    return context_active_entry(ctx).audio_reader
end

--- Get asset info for context's active reader.
-- @param context_id string
function M.get_asset_info(context_id)
    local ctx = get_context(context_id)
    if not ctx.active_path or not M.reader_pool[ctx.active_path] then return nil end
    return context_active_entry(ctx).info
end

--- Get active file path for context.
-- @param context_id string
function M.get_file_path(context_id)
    local ctx = get_context(context_id)
    return ctx.active_path
end

function M.get_rotation(context_id)
    local ctx = get_context(context_id)
    if not ctx.active_path or not M.reader_pool[ctx.active_path] then return 0 end
    local info = context_active_entry(ctx).info
    return info and info.rotation or 0
end

--------------------------------------------------------------------------------
-- Lifecycle: Pool-based activate / cleanup (per-context)
--------------------------------------------------------------------------------

--- Activate a media file in a context.
-- If already in the pool, promote to active (no I/O).
-- If not in pool, open and add. LRU-evict if pool full.
-- @param file_path Path to media file
-- @param context_id string
-- @return asset_info
function M.activate(file_path, context_id)
    assert(file_path, "media_cache.activate: file_path is nil")
    assert(type(file_path) == "string", string.format(
        "media_cache.activate: file_path must be string, got %s", type(file_path)))

    local ctx = get_context(context_id)

    -- Fast path: already active in this context
    if file_path == ctx.active_path then
        local entry = M.reader_pool[file_path]
        assert(entry, "media_cache.activate: active_path in pool but entry missing")
        entry.last_used = os.clock()
        return entry.info
    end

    -- Stop old reader's prefetch thread before switching
    if ctx.active_path and ctx.last_prefetch_direction ~= 0 then
        local old_entry = M.reader_pool[ctx.active_path]
        if old_entry and old_entry.video_reader then
            qt_constants.EMP.READER_STOP_PREFETCH(old_entry.video_reader)
        end
    end

    -- Release Lua-side caches from this context's old active reader
    if ctx.active_path then
        release_context_caches(ctx)
    end

    -- Ensure in pool (opens if needed)
    local entry = ensure_in_pool(file_path)
    if not entry then
        -- Offline: don't set active_path (context stays on previous or nil)
        return nil
    end
    ctx.active_path = file_path

    logger.debug("media_cache", string.format("Activated '%s' in context '%s'",
        file_path, context_id))

    return entry.info
end

--- Legacy load() — calls activate() for backward compat.
-- @param file_path Path to media file
-- @param context_id string
-- @return asset_info
function M.load(file_path, context_id)
    return M.activate(file_path, context_id)
end

--- Unload a context's active reader caches (keeps reader pooled).
-- @param context_id string
function M.unload(context_id)
    local ctx = get_context(context_id)
    release_context_caches(ctx)
    logger.debug("media_cache", string.format(
        "Unloaded Lua caches for context '%s' (reader stays pooled)", context_id))
end

--- Get offline info for a path (nil if path is not offline).
-- @param file_path string
-- @return table|nil: { error_code, error_msg, path, first_seen }
function M.get_offline_info(file_path)
    return M._offline_registry[file_path]
end

--- Release ALL pooled readers and ALL contexts.
-- Called on application exit or when switching projects.
function M.cleanup()
    -- Release all context caches
    for _, ctx in pairs(M.contexts) do
        release_context_caches(ctx)
    end
    M.contexts = {}

    for path, entry in pairs(M.reader_pool) do
        close_entry(entry)
    end
    M.reader_pool = {}
    M._offline_registry = {}

    logger.debug("media_cache", "Cleaned up all pooled readers and contexts")
end

--- Clear state that shouldn't persist across projects
function M.on_project_change()
    M.cleanup()
end

--- Stop all prefetch threads (without closing readers).
-- Called when playback stops to prevent runaway prefetch loops.
function M.stop_all_prefetch()
    for path, entry in pairs(M.reader_pool) do
        if entry.video_reader then
            qt_constants.EMP.READER_STOP_PREFETCH(entry.video_reader)
        end
    end
    -- Reset prefetch direction for all contexts
    for _, ctx in pairs(M.contexts) do
        ctx.last_prefetch_direction = 0
    end
    logger.debug("media_cache", "Stopped all prefetch threads")
end

--------------------------------------------------------------------------------
-- Audio Pool Access (shared, no context needed)
--------------------------------------------------------------------------------

--- Ensure a path is in the reader pool for audio access.
-- Opens the file if not already pooled. Does NOT change any context's active_path.
-- @param file_path Path to media file
-- @return asset_info
function M.ensure_audio_pooled(file_path)
    assert(file_path, "media_cache.ensure_audio_pooled: file_path is nil")
    assert(type(file_path) == "string", string.format(
        "media_cache.ensure_audio_pooled: file_path must be string, got %s",
        type(file_path)))

    local entry = ensure_in_pool(file_path)
    if not entry then
        return nil  -- offline
    end
    return entry.info
end

--- Get audio PCM for a specific pooled path (multi-track audio).
-- Uses per-entry audio cache. Does NOT require path to be active in any context.
-- @param file_path Path to media file (must be in pool)
-- @param start_us Start time in microseconds
-- @param end_us End time in microseconds
-- @param out_sample_rate Output sample rate
-- @return pcm_data_ptr, frames, actual_start_us
function M.get_audio_pcm_for_path(file_path, start_us, end_us, out_sample_rate)
    assert(file_path, "media_cache.get_audio_pcm_for_path: file_path is nil")
    local entry = M.reader_pool[file_path]
    assert(entry, string.format(
        "media_cache.get_audio_pcm_for_path: '%s' not in pool (call ensure_audio_pooled first)",
        file_path))
    assert(entry.audio_reader, string.format(
        "media_cache.get_audio_pcm_for_path: '%s' has no audio_reader", file_path))
    assert(type(start_us) == "number",
        "media_cache.get_audio_pcm_for_path: start_us must be number")
    assert(type(end_us) == "number",
        "media_cache.get_audio_pcm_for_path: end_us must be number")
    assert(end_us > start_us, string.format(
        "media_cache.get_audio_pcm_for_path: end_us (%d) must be > start_us (%d)",
        end_us, start_us))

    local cache = entry.audio_cache

    if cache.pcm and
       start_us >= cache.start_us and
       end_us <= cache.end_us then
        return cache.data_ptr, cache.frames, cache.start_us
    end

    if cache.pcm then
        qt_constants.EMP.PCM_RELEASE(cache.pcm)
        cache.pcm = nil
    end

    local audio_rate = entry.info.audio_sample_rate
    local us_per_sample = 1000000 / audio_rate
    local sample_start = math.floor(start_us / us_per_sample)
    local sample_end = math.ceil(end_us / us_per_sample)

    local decode_rate = out_sample_rate or audio_rate
    local pcm, err = qt_constants.EMP.READER_DECODE_AUDIO_RANGE(
        entry.audio_reader,
        sample_start,
        sample_end,
        audio_rate,
        1,
        decode_rate,
        entry.info.audio_channels
    )
    assert(pcm, string.format(
        "media_cache.get_audio_pcm_for_path: READER_DECODE_AUDIO_RANGE failed [%d-%d] for '%s': %s",
        sample_start, sample_end, file_path, err and err.msg or "unknown error"))

    local info = qt_constants.EMP.PCM_INFO(pcm)
    cache.pcm = pcm
    cache.start_us = info.start_time_us
    cache.end_us = info.start_time_us + (info.frames * 1000000 / decode_rate)
    cache.data_ptr = qt_constants.EMP.PCM_DATA_PTR(pcm)
    cache.frames = info.frames

    entry.last_used = os.clock()

    logger.debug("media_cache", string.format(
        "Cached audio PCM for '%s': %.3fs - %.3fs (%d frames)",
        file_path, cache.start_us / 1000000, cache.end_us / 1000000, cache.frames))

    return cache.data_ptr, cache.frames, cache.start_us
end

--------------------------------------------------------------------------------
-- Video Frame Access (per-context)
--------------------------------------------------------------------------------

--- Get video frame by index (from C++ cache or decode)
-- @param frame_idx Frame index to retrieve
-- @param context_id string
-- @return EMP frame handle
function M.get_video_frame(frame_idx, context_id, fps_num, fps_den)
    assert(M.is_loaded(context_id),
        "media_cache.get_video_frame: not loaded (call activate() first)")
    assert(frame_idx, "media_cache.get_video_frame: frame_idx is nil")
    assert(type(frame_idx) == "number", string.format(
        "media_cache.get_video_frame: frame_idx must be number, got %s", type(frame_idx)))
    assert(frame_idx >= 0, string.format(
        "media_cache.get_video_frame: frame_idx must be >= 0, got %d", frame_idx))

    local ctx = get_context(context_id)
    local entry = context_active_entry(ctx)
    assert(entry.video_reader, string.format(
        "media_cache.get_video_frame: active entry '%s' has no video_reader (audio-only file?)",
        ctx.active_path))

    -- Use caller-provided fps (clip's timebase) or fall back to media's native rate
    local decode_fps_num = fps_num or entry.info.fps_num
    local decode_fps_den = fps_den or entry.info.fps_den

    local frame, err = qt_constants.EMP.READER_DECODE_FRAME(
        entry.video_reader,
        frame_idx,
        decode_fps_num,
        decode_fps_den
    )
    if not frame then
        local msg = err and err.msg or "unknown error"
        if msg:match("End of file") then
            -- EOF: source material exhausted (clip duration exceeds media file).
            logger.warn("media_cache", string.format(
                "EOF at file_frame=%d fps=%d/%d media_dur=%.3fs media_fps=%d/%d path=%s",
                frame_idx, decode_fps_num, decode_fps_den,
                (entry.info.duration_us or 0) / 1000000,
                entry.info.fps_num or 0, entry.info.fps_den or 0,
                tostring(ctx.active_path)))
            return nil
        end
        assert(false, string.format(
            "media_cache.get_video_frame: READER_DECODE_FRAME failed at frame %d: %s",
            frame_idx, msg))
    end

    return frame
end

--- Internal: cache a video frame for a context, evicting old frames if needed
function M._cache_video_frame(frame_idx, frame, context_id)
    local ctx = get_context(context_id)
    ctx.video_cache.frames[frame_idx] = frame

    local min_keep, max_keep
    if ctx.video_cache.bulk_keep_min and ctx.video_cache.bulk_keep_max then
        min_keep = ctx.video_cache.bulk_keep_min
        max_keep = ctx.video_cache.bulk_keep_max
    else
        local half_window = math.floor(ctx.video_cache.window_size / 2)
        min_keep = frame_idx - half_window
        max_keep = frame_idx + half_window
    end

    for idx, cached_frame in pairs(ctx.video_cache.frames) do
        if idx < min_keep or idx > max_keep then
            qt_constants.EMP.FRAME_RELEASE(cached_frame)
            ctx.video_cache.frames[idx] = nil
        end
    end

    ctx.video_cache.center_idx = frame_idx
end

--- Internal: decode a contiguous window ending at end_frame_idx
-- @param fps_num number|nil clip fps numerator (falls back to media's native rate)
-- @param fps_den number|nil clip fps denominator
function M._ensure_reverse_window(end_frame_idx, backfill_count, context_id, fps_num, fps_den)
    if not M.is_loaded(context_id) then
        return
    end

    local ctx = get_context(context_id)
    local entry = context_active_entry(ctx)
    local want = backfill_count or ctx.video_cache.window_size
    if want < 1 then want = 1 end
    if want > ctx.video_cache.window_size then want = ctx.video_cache.window_size end

    local start_frame_idx = end_frame_idx - want
    if start_frame_idx < 0 then start_frame_idx = 0 end

    if ctx.video_cache.reverse_window_start ~= nil and ctx.video_cache.reverse_window_end ~= nil then
        if end_frame_idx >= ctx.video_cache.reverse_window_start and end_frame_idx <= ctx.video_cache.reverse_window_end then
            if ctx.video_cache.frames[end_frame_idx] then
                return
            end
        end
    end

    ctx.video_cache.reverse_window_start = start_frame_idx
    ctx.video_cache.reverse_window_end = end_frame_idx

    ctx.video_cache.bulk_keep_min = start_frame_idx
    ctx.video_cache.bulk_keep_max = end_frame_idx

    local decode_fps_num = fps_num or entry.info.fps_num
    local decode_fps_den = fps_den or entry.info.fps_den
    for i = start_frame_idx, end_frame_idx do
        if not ctx.video_cache.frames[i] then
            local frame = qt_constants.EMP.READER_DECODE_FRAME(
                entry.video_reader, i, decode_fps_num, decode_fps_den)
            if frame then
                M._cache_video_frame(i, frame, context_id)
            end
        end
    end

    ctx.video_cache.bulk_keep_min = nil
    ctx.video_cache.bulk_keep_max = nil
end

--------------------------------------------------------------------------------
-- Audio PCM Access (per-context, for source-mode compat)
--------------------------------------------------------------------------------

--- Get audio PCM for time range using context's active reader.
-- @param start_us Start time in microseconds
-- @param end_us End time in microseconds
-- @param out_sample_rate Output sample rate
-- @param context_id string
-- @return pcm_data_ptr, frames, actual_start_us
function M.get_audio_pcm(start_us, end_us, out_sample_rate, context_id)
    assert(M.is_loaded(context_id),
        "media_cache.get_audio_pcm: not loaded (call activate() first)")
    local ctx = get_context(context_id)
    local entry = context_active_entry(ctx)
    assert(entry.audio_reader,
        "media_cache.get_audio_pcm: active reader has no audio_reader")
    assert(type(start_us) == "number", "media_cache.get_audio_pcm: start_us must be number")
    assert(type(end_us) == "number", "media_cache.get_audio_pcm: end_us must be number")
    assert(end_us > start_us, string.format(
        "media_cache.get_audio_pcm: end_us (%d) must be > start_us (%d)", end_us, start_us))

    local cache = ctx.audio_cache

    if cache.pcm and
       start_us >= cache.start_us and
       end_us <= cache.end_us then
        return cache.data_ptr, cache.frames, cache.start_us
    end

    if cache.pcm then
        qt_constants.EMP.PCM_RELEASE(cache.pcm)
        cache.pcm = nil
    end

    local audio_rate = entry.info.audio_sample_rate
    local us_per_sample = 1000000 / audio_rate
    local sample_start = math.floor(start_us / us_per_sample)
    local sample_end = math.ceil(end_us / us_per_sample)

    local decode_rate = out_sample_rate or audio_rate
    local pcm, err = qt_constants.EMP.READER_DECODE_AUDIO_RANGE(
        entry.audio_reader,
        sample_start,
        sample_end,
        audio_rate,
        1,
        decode_rate,
        entry.info.audio_channels
    )
    assert(pcm, string.format(
        "media_cache.get_audio_pcm: READER_DECODE_AUDIO_RANGE failed [%d-%d]: %s",
        sample_start, sample_end, err and err.msg or "unknown error"))

    local info = qt_constants.EMP.PCM_INFO(pcm)
    cache.pcm = pcm
    cache.start_us = info.start_time_us
    cache.end_us = info.start_time_us + (info.frames * 1000000 / decode_rate)
    cache.data_ptr = qt_constants.EMP.PCM_DATA_PTR(pcm)
    cache.frames = info.frames

    logger.debug("media_cache", string.format(
        "Cached audio PCM: %.3fs - %.3fs (%d frames)",
        cache.start_us / 1000000, cache.end_us / 1000000, cache.frames))

    local drift_us = info.start_time_us - start_us
    if drift_us > 10000 then
        logger.debug("media_cache", string.format(
            "Codec delay: requested=%.3fs, actual=%.3fs, drift=%.1fms",
            start_us / 1000000, info.start_time_us / 1000000, drift_us / 1000))
    end

    return cache.data_ptr, cache.frames, cache.start_us
end

--------------------------------------------------------------------------------
-- Pre-Buffer (warm reader pool + decode ahead, no context change)
--------------------------------------------------------------------------------

--- Pre-buffer video frames for an upcoming clip transition.
-- Opens reader in pool (if not already) and pre-decodes ~5 frames at entry point.
-- Does NOT change any context's active_path. Used by engine lookahead.
-- @param path string: media file path
-- @param entry_frame number: first source frame to decode
-- @param fps_num number: clip fps numerator
-- @param fps_den number: clip fps denominator
function M.pre_buffer(path, entry_frame, fps_num, fps_den)
    assert(path and type(path) == "string",
        "media_cache.pre_buffer: path must be a non-nil string")
    assert(type(entry_frame) == "number",
        "media_cache.pre_buffer: entry_frame must be a number")
    assert(type(fps_num) == "number" and fps_num > 0,
        "media_cache.pre_buffer: fps_num must be positive number")
    assert(type(fps_den) == "number" and fps_den > 0,
        "media_cache.pre_buffer: fps_den must be positive number")

    -- Warm the reader pool (opens file if not already pooled)
    local entry = ensure_in_pool(path)
    if not entry then
        return  -- offline; can't pre-buffer
    end

    -- Pre-decode ~5 frames starting at entry point (if video reader exists).
    -- Stop early if decode returns nil (past EOF).
    if entry.video_reader then
        local pre_decode_count = 5
        local decoded = 0
        for i = 0, pre_decode_count - 1 do
            local frame_handle = qt_constants.EMP.READER_DECODE_FRAME(
                entry.video_reader, entry_frame + i, fps_num, fps_den)
            if not frame_handle then break end
            decoded = decoded + 1
        end
        logger.debug("media_cache", string.format(
            "Pre-buffered %d/%d frames at %d for '%s'",
            decoded, pre_decode_count, entry_frame, path))
    end
end

--------------------------------------------------------------------------------
-- Playhead Management (per-context)
--------------------------------------------------------------------------------

--- Update playhead position (triggers prefetch in travel direction)
-- @param frame_idx Current frame index
-- @param direction -1=reverse, 0=stopped, 1=forward
-- @param speed Playback speed multiplier
-- @param context_id string
-- @param fps_num number|nil clip fps numerator (falls back to media's native rate)
-- @param fps_den number|nil clip fps denominator
function M.set_playhead(frame_idx, direction, speed, context_id, fps_num, fps_den)
    assert(frame_idx, "media_cache.set_playhead: frame_idx is nil")
    assert(direction, "media_cache.set_playhead: direction is nil")
    assert(speed, "media_cache.set_playhead: speed is nil")
    assert(M.is_loaded(context_id),
        "media_cache.set_playhead: not loaded (call activate() first)")

    local ctx = get_context(context_id)
    local entry = context_active_entry(ctx)

    ctx.playhead_direction = direction

    if direction ~= ctx.last_prefetch_direction then
        if direction == 0 then
            if entry.video_reader then
                qt_constants.EMP.READER_STOP_PREFETCH(entry.video_reader)
            end
            logger.debug("media_cache", "Prefetch stopped")
        else
            if entry.video_reader then
                qt_constants.EMP.READER_START_PREFETCH(entry.video_reader, direction)
                logger.debug("media_cache", string.format("Prefetch started: direction=%d", direction))
            end
        end
        ctx.last_prefetch_direction = direction
    end

    if direction ~= 0 and entry.video_reader then
        local prefetch_fps_num = fps_num or entry.info.fps_num
        local prefetch_fps_den = fps_den or entry.info.fps_den
        qt_constants.EMP.READER_UPDATE_PREFETCH_TARGET(
            entry.video_reader,
            frame_idx,
            prefetch_fps_num,
            prefetch_fps_den
        )
    end

    ctx.video_cache.center_idx = frame_idx
end

--------------------------------------------------------------------------------
-- Register for project_changed signal (priority 20: after playback stops)
--------------------------------------------------------------------------------
local Signals = require("core.signals")
Signals.connect("project_changed", M.on_project_change, 20)

return M
