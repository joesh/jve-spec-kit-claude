--- Peak data cache — manages loading, generation, and querying of waveform peak data.
---
--- Peaks are per-media-file (keyed by media_id). All clip instances sharing
--- a media file share the same peak data. Peak files are binary `.peaks` files
--- stored in `<project>.jvp-cache/peaks/`.
---
--- @module peak_cache
local M = {}
local log = require("core.logger").for_area("media")
local fs_utils = require("core.fs_utils")
local Signals = require("core.signals")

-- EMP bindings (set during init)
local EMP = nil

-- Cache state
local cache_dir = nil          -- absolute path to peaks/ directory
local peak_handles = {}        -- media_id → peak_handle (from EMP.PEAK_LOAD)
local generation_status = {}   -- media_id → "generating" | "complete" | "failed"
local media_tc_origins = {}    -- media_id → audio TC origin in samples (absolute→file-relative)

--- Get the peak file path for a media ID.
local function peak_file_path(media_id)
    assert(cache_dir, "peak_cache: not initialized (call init_for_project first)")
    return cache_dir .. "/" .. media_id .. ".peaks"
end

-- ============================================================================
-- ensure_peaks subfunctions (rule 2.5)
-- ============================================================================

--- Check if a generating job has completed and load its peaks.
local function try_finalize_generating(media_id)
    local status = EMP.PEAK_STATUS(media_id)
    if not status then return end

    if status.state == "complete" then
        local handle, err = EMP.PEAK_LOAD(peak_file_path(media_id))
        if handle then
            peak_handles[media_id] = handle
            generation_status[media_id] = "complete"
            log.event("peak_cache: loaded peaks for %s", media_id)
        else
            log.warn("peak_cache: generation complete but load failed for %s: %s",
                media_id, tostring(err))
            generation_status[media_id] = "failed"
        end
    elseif status.state == "failed" then
        generation_status[media_id] = "failed"
    end
end

--- Try loading an existing peak file and validate its mtime.
--- @return boolean true if loaded and valid
local function try_load_existing(media_id, source_mtime)
    local path = peak_file_path(media_id)
    local handle = EMP.PEAK_LOAD(path)
    if not handle then return false end

    local hdr = EMP.PEAK_HEADER(handle)
    assert(hdr, string.format(
        "peak_cache: PEAK_HEADER returned nil for valid handle (media_id=%s)", media_id))

    if hdr.source_mtime == source_mtime then
        peak_handles[media_id] = handle
        generation_status[media_id] = "complete"
        return true
    end

    -- Stale — release, delete, and let caller regenerate
    EMP.PEAK_RELEASE(handle)
    os.remove(path)
    log.event("peak_cache: stale peaks for %s (mtime %d vs %d), regenerating",
        media_id, hdr.source_mtime, source_mtime)
    return false
end

-- ============================================================================
-- Completion poll timer — triggers timeline repaint as peaks finish generating
-- ============================================================================

local poll_timer_active = false

local function start_completion_poll()
    if poll_timer_active then return end
    if type(qt_create_single_shot_timer) ~= "function" then return end

    local function poll()
        poll_timer_active = false
        if not EMP or not cache_dir then return end

        local any_generating = false
        local any_newly_loaded = false

        for media_id, status in pairs(generation_status) do
            if status == "generating" then
                try_finalize_generating(media_id)
                if generation_status[media_id] == "complete" then
                    any_newly_loaded = true
                elseif generation_status[media_id] == "generating" then
                    any_generating = true
                end
            end
        end

        -- Trigger timeline repaint if peaks newly loaded OR still generating
        -- (progressive display: in-progress waveforms update each poll cycle)
        if any_newly_loaded or any_generating then
            local timeline_data = require("ui.timeline.state.timeline_state_data")
            timeline_data.notify_listeners()
        end

        -- Re-schedule if more jobs pending
        if any_generating then
            poll_timer_active = true
            qt_create_single_shot_timer(500, poll)
        end
    end

    poll_timer_active = true
    qt_create_single_shot_timer(500, poll)
end

--- Request background generation for a media file.
local function request_generation(media_id, media_path)
    generation_status[media_id] = "generating"
    EMP.PEAK_REQUEST(media_id, media_path, peak_file_path(media_id))
    log.event("peak_cache: requested peak gen for %s (%s)", media_id, media_path)
    start_completion_poll()  -- ensure poll timer is running
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Initialize the peak cache for a project.
--- Scans all audio media and queues peak generation for any without cached peaks.
function M.init_for_project(project_id)
    assert(project_id and project_id ~= "",
        "peak_cache.init_for_project: project_id required")

    local database = require("core.database")
    cache_dir = database.get_peak_cache_dir()
    assert(cache_dir and cache_dir ~= "",
        "peak_cache.init_for_project: get_peak_cache_dir returned empty")

    EMP = qt_constants and qt_constants.EMP
    assert(EMP, "peak_cache.init_for_project: qt_constants.EMP not available")

    local Media = require("models.media")
    local audio_media = Media.get_audio_for_project(project_id)

    for _, rec in ipairs(audio_media) do
        assert(rec.file_path and rec.file_path ~= "",
            string.format("peak_cache: media %s has nil/empty file_path", tostring(rec.id)))

        -- Cache audio TC origin for absolute→file-relative conversion.
        -- nil from get_audio_start_tc means "no timecode metadata" → origin is 0
        -- (file-relative and absolute coordinates are the same).
        local media_obj = Media.load(rec.id)
        assert(media_obj, string.format(
            "peak_cache: Media.load returned nil for media_id=%s", tostring(rec.id)))
        local tc_samples = media_obj:get_audio_start_tc()
        media_tc_origins[rec.id] = (tc_samples ~= nil) and tc_samples or 0

        -- Only generate peaks for files that exist on disk (skip offline media)
        if not fs_utils.file_exists(rec.file_path) then
            log.detail("peak_cache: skipping offline %s", rec.file_path)
            goto continue_media
        end

        local mtime = fs_utils.file_mtime(rec.file_path)
        if mtime then
            M.ensure_peaks(rec.id, rec.file_path, mtime)
        else
            log.warn("peak_cache: could not stat %s — skipping peak gen", rec.file_path)
        end
        ::continue_media::
    end

    log.event("peak_cache: initialized for project %s (%d audio media)",
        project_id, #audio_media)

    start_completion_poll()
end

--- Ensure peaks exist for a media file. Triggers background generation if needed.
--- Idempotent — safe to call on every render frame.
function M.ensure_peaks(media_id, media_path, source_mtime)
    assert(media_id, "peak_cache.ensure_peaks: media_id required")
    assert(media_path, "peak_cache.ensure_peaks: media_path required")
    assert(source_mtime, "peak_cache.ensure_peaks: source_mtime required")
    assert(EMP, "peak_cache.ensure_peaks: not initialized")

    if peak_handles[media_id] then return end

    if generation_status[media_id] == "generating" then
        try_finalize_generating(media_id)
        return
    end

    if try_load_existing(media_id, source_mtime) then return end

    request_generation(media_id, media_path)
end

--- Get peak data for the visible region of a clip.
--- source_start/source_end are absolute TC samples (as stored in clip.source_in/source_out).
--- Converts to file-relative samples by subtracting media's audio TC origin.
--- Returns: peaks_ptr, count, actual_abs_start, actual_abs_end
--- The actual range is tagged with absolute TC so the caller can verify alignment.
function M.get_visible_peaks(media_id, source_start, source_end, pixel_width)
    assert(media_id, "peak_cache.get_visible_peaks: media_id required")
    assert(type(source_start) == "number", "peak_cache.get_visible_peaks: source_start must be number")
    assert(type(source_end) == "number", "peak_cache.get_visible_peaks: source_end must be number")
    assert(type(pixel_width) == "number", "peak_cache.get_visible_peaks: pixel_width must be number")

    if pixel_width <= 0 or source_end <= source_start then return nil, 0, 0, 0 end

    -- Convert absolute TC → file-relative by subtracting media's audio TC origin.
    -- No TC origin: init hasn't run yet or media not in audio scan.
    if media_tc_origins[media_id] == nil then return nil, 0, 0, 0 end
    local tc_origin = media_tc_origins[media_id]
    local file_start = source_start - tc_origin
    local file_end = source_end - tc_origin
    if file_start < 0 then file_start = 0 end
    if file_end <= file_start then return nil, 0, 0, 0 end

    -- Completed peak file — query mmap'd data (full mipmap support)
    local handle = peak_handles[media_id]
    if handle then
        local peaks, count, actual_file_start, actual_file_end =
            EMP.PEAK_QUERY(handle, file_start, file_end, pixel_width)

        if not peaks or count <= 0 then return nil, 0, 0, 0 end

        local actual_abs_start = actual_file_start + tc_origin
        local actual_abs_end = actual_file_end + tc_origin
        return peaks, count, actual_abs_start, actual_abs_end
    end

    -- In-progress generation — query live buffer (level 0 only, progressive)
    if generation_status[media_id] == "generating" then
        local peaks, count, actual_file_start, actual_file_end =
            EMP.PEAK_QUERY_PROGRESS(media_id, file_start, file_end, pixel_width)

        if not peaks or count <= 0 then return nil, 0, 0, 0 end

        local actual_abs_start = actual_file_start + tc_origin
        local actual_abs_end = actual_file_end + tc_origin
        return peaks, count, actual_abs_start, actual_abs_end
    end

    return nil, 0, 0, 0
end

--- Get generation status for a media file.
function M.get_status(media_id)
    if peak_handles[media_id] then return "complete" end
    return generation_status[media_id] or "none"
end

--- Invalidate peaks for a media file (relink, mtime change).
function M.invalidate(media_id)
    assert(media_id, "peak_cache.invalidate: media_id required")

    if peak_handles[media_id] then
        EMP.PEAK_RELEASE(peak_handles[media_id])
        peak_handles[media_id] = nil
    end

    if EMP then
        EMP.PEAK_CANCEL(media_id)
    end

    os.remove(peak_file_path(media_id))
    generation_status[media_id] = nil
    log.event("peak_cache: invalidated %s", media_id)
end

--- Cleanup orphaned peak files.
function M.cleanup_orphans(active_media_ids)
    assert(cache_dir, "peak_cache.cleanup_orphans: not initialized")
    assert(type(active_media_ids) == "table",
        "peak_cache.cleanup_orphans: active_media_ids table required")

    for _, filename in ipairs(fs_utils.list_dir(cache_dir)) do
        local media_id = filename:match("^(.+)%.peaks$")
        if media_id and not active_media_ids[media_id] then
            os.remove(cache_dir .. "/" .. filename)
            log.event("peak_cache: cleaned orphan %s", filename)
        end
    end
end

--- Release all cached data (project close).
function M.clear()
    for _, handle in pairs(peak_handles) do
        if EMP then
            EMP.PEAK_RELEASE(handle)
        end
    end
    peak_handles = {}
    generation_status = {}
    media_tc_origins = {}

    if EMP then
        EMP.PEAK_CANCEL_ALL()
    end

    cache_dir = nil
    poll_timer_active = false
    log.event("peak_cache: cleared")
end

-- Clear cache when switching projects (priority 15, alongside offline_frame_cache).
Signals.connect("project_changed", function()
    M.clear()
end, 15)

return M
