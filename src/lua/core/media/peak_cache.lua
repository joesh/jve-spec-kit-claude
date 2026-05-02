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

-- Minimum fraction of the media's expected audio sample count that a peak
-- file must cover to be trusted. Legacy/transient truncated peak files
-- (see PeakGenerator::FinalizeJob) are rejected here and regenerated.
-- The 95% threshold tolerates normal AAC-priming / container-duration
-- rounding while catching the ~50% truncations we've observed in the wild.
-- The cause of those truncations is not understood — the only repro is
-- "sometimes, on first project-open after a Resolve Media-Manage export,
-- peak gen's decoder returns zero frames mid-file and we accept it as
-- EOF". Left as a TODO; this check makes it self-healing across opens.
local PEAK_COVERAGE_MIN_FRACTION = 0.95

--- Try loading an existing peak file and validate it against the media
--- it claims to describe.
---
--- Two checks must pass for a peak file to be trusted:
---   1. Header mtime matches the media's current mtime at second resolution.
---      (Header stores int64_t source_mtime from st.st_mtime; fs_utils
---      returns nanosecond-precision float, so we floor.)
---   2. Header's level-0 bin count covers at least PEAK_COVERAGE_MIN_FRACTION
---      of the media's expected audio sample count. expected_samples nil
---      means "caller doesn't know"; coverage check is skipped in that
---      case (preserves callers outside init_for_project).
---
--- On failure, releases the handle, deletes the file, returns false so
--- the caller triggers regeneration.
--- @return boolean true if loaded and valid
local function try_load_existing(media_id, source_mtime, expected_samples)
    local path = peak_file_path(media_id)
    local handle = EMP.PEAK_LOAD(path)
    if not handle then return false end

    local hdr = EMP.PEAK_HEADER(handle)
    assert(hdr, string.format(
        "peak_cache: PEAK_HEADER returned nil for valid handle (media_id=%s)", media_id))

    local mtime_matches = (hdr.source_mtime == math.floor(source_mtime))
    local coverage_ok = true
    if expected_samples and expected_samples > 0 then
        -- bins_per_level[1] is level 0 (Lua 1-indexed); covered samples
        -- ≈ bins × base_spp. Last bin may be partial, so this overstates
        -- coverage slightly — conservative for the <95% rejection test.
        -- Assert >0 rather than truthy: 0 is truthy in Lua, and a
        -- corrupt header with bins=0 or spp=0 would silently classify
        -- every peak file as truncated.
        assert(hdr.bins_per_level and hdr.bins_per_level[1]
                and hdr.bins_per_level[1] > 0,
            string.format("peak_cache: header bins_per_level[1] invalid for %s (got %s)",
                media_id, tostring(hdr.bins_per_level and hdr.bins_per_level[1])))
        assert(hdr.base_spp and hdr.base_spp > 0,
            string.format("peak_cache: header base_spp invalid for %s (got %s)",
                media_id, tostring(hdr.base_spp)))
        local peak_samples = hdr.bins_per_level[1] * hdr.base_spp
        if peak_samples < expected_samples * PEAK_COVERAGE_MIN_FRACTION then
            coverage_ok = false
            log.warn("peak_cache: truncated peaks for %s — "
                .. "peak covers %d samples, media has %d (%.1f%%); regenerating",
                media_id, peak_samples, expected_samples,
                100.0 * peak_samples / expected_samples)
        end
    end

    if mtime_matches and coverage_ok then
        peak_handles[media_id] = handle
        generation_status[media_id] = "complete"
        return true
    end

    -- Stale or truncated — release, delete, and let caller regenerate
    EMP.PEAK_RELEASE(handle)
    os.remove(path)
    if not mtime_matches then
        log.event("peak_cache: stale peaks for %s (mtime %d vs %s), regenerating",
            media_id, hdr.source_mtime, tostring(source_mtime))
    end
    return false
end

--- Test hook: exposes try_load_existing for integration tests that
--- install hand-crafted peak files and verify load-time rejection.
--- Not part of the public API; production callers go through ensure_peaks.
function M._try_load_existing_for_test(media_id, source_mtime, expected_samples)
    return try_load_existing(media_id, source_mtime, expected_samples)
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

local function expected_samples_from_probe(info)
    if not info then return nil end
    if not info.duration_us or info.duration_us <= 0 then return nil end
    if not info.audio_sample_rate or info.audio_sample_rate <= 0 then return nil end
    return math.floor(info.duration_us / 1e6 * info.audio_sample_rate)
end

-- Pull the media's audio TC origin (in samples) into the cache.
-- 0 means "file at TC origin" (no embedded TC) — the same sentinel the
-- get_visible_peaks consumer keys off. Returns true when the value came
-- from already-parsed metadata, false when get_audio_start_tc had to
-- open the file via EMP to extract it.
local function set_tc_origin(media_obj)
    local pre_meta = media_obj:_parsed_metadata()
    local had_tc = pre_meta and pre_meta.start_tc_value ~= nil
    local tc_samples = media_obj:get_audio_start_tc()
    media_tc_origins[media_obj.id] = (tc_samples ~= nil) and tc_samples or 0
    return had_tc
end

-- init_for_project wrapper: same TC pull + bump cache-vs-extract counters.
local function cache_tc_origin(media_obj, counters)
    if set_tc_origin(media_obj) then
        counters.tc_cached = counters.tc_cached + 1
    else
        counters.tc_extracted = counters.tc_extracted + 1
    end
end

-- Trigger peak load (or generation) for one online media file. mtime is
-- already available — file_mtime returning nil means "file disappeared
-- between our existence check and the stat", which is rare but real.
local function ensure_peaks_for_online(rec, expected_samples, counters)
    local mtime = fs_utils.file_mtime(rec.file_path)
    if not mtime then
        log.warn("peak_cache: could not stat %s — skipping peak gen", rec.file_path)
        return
    end
    local was_loaded = peak_handles[rec.id] ~= nil
    local was_generating = generation_status[rec.id] == "generating"
    M.ensure_peaks(rec.id, rec.file_path, mtime, expected_samples)
    if peak_handles[rec.id] and not was_loaded then
        counters.peaks_loaded = counters.peaks_loaded + 1
    elseif generation_status[rec.id] == "generating" and not was_generating then
        counters.peaks_requested = counters.peaks_requested + 1
    end
end

-- Per-media body of init_for_project. Pulled out so init_for_project
-- itself reads as a four-step algorithm (fetch list → batch-probe →
-- iterate → log) rather than mixing the loop body inline.
local function init_one_media(rec, info, counters, Media)
    assert(rec.file_path and rec.file_path ~= "",
        string.format("peak_cache: media %s has nil/empty file_path", tostring(rec.id)))

    local media_obj = Media.load(rec.id)
    assert(media_obj, string.format(
        "peak_cache: Media.load returned nil for media_id=%s", tostring(rec.id)))

    cache_tc_origin(media_obj, counters)

    if not fs_utils.file_exists(rec.file_path) then
        log.detail("peak_cache: skipping offline %s", rec.file_path)
        counters.offline = counters.offline + 1
        return
    end

    ensure_peaks_for_online(rec, expected_samples_from_probe(info), counters)
end

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

    local t_start = qt_monotonic_s()  -- luacheck: globals qt_monotonic_s

    local Media = require("models.media")
    local audio_media = Media.get_audio_for_project(project_id)
    local t_query = qt_monotonic_s()

    -- Batch-probe every audio media's file to get the authoritative
    -- audio sample count. We can't trust media.duration_frames — after
    -- a Resolve Media-Manage, the row still carries the DRP's original
    -- duration while the on-disk file is trimmed (no back-compat path
    -- updates duration). The probe cache makes this cheap on reopen.
    local probe_cache = require("core.media_probe_cache")
    local media_paths = {}
    for i, rec in ipairs(audio_media) do media_paths[i] = rec.file_path end
    local probes = probe_cache.probe_batch(media_paths)
    local t_probe = qt_monotonic_s()

    local counters = {
        tc_cached      = 0,
        tc_extracted   = 0,
        peaks_loaded   = 0,
        peaks_requested = 0,
        offline        = 0,
    }

    for i, rec in ipairs(audio_media) do
        init_one_media(rec, probes[i], counters, Media)
    end

    local t_done = qt_monotonic_s()
    log.event("peak_cache.init_for_project: %d audio "
        .. "(tc_cached=%d tc_extracted=%d peaks_loaded=%d peaks_requested=%d offline=%d) "
        .. "query=%.2fs probe=%.2fs loop=%.2fs total=%.2fs",
        #audio_media,
        counters.tc_cached, counters.tc_extracted,
        counters.peaks_loaded, counters.peaks_requested, counters.offline,
        t_query - t_start, t_probe - t_query, t_done - t_probe, t_done - t_start)

    start_completion_poll()
end

--- Ensure peaks exist for a media file. Triggers background generation if needed.
--- Idempotent — safe to call on every render frame.
--- expected_samples is the media's audio sample count from a fresh probe;
--- when supplied, try_load_existing rejects peak files that cover less
--- than PEAK_COVERAGE_MIN_FRACTION of it. Nil preserves the pre-coverage
--- behavior (mtime check only) for callers outside init_for_project.
function M.ensure_peaks(media_id, media_path, source_mtime, expected_samples)
    assert(media_id, "peak_cache.ensure_peaks: media_id required")
    assert(media_path, "peak_cache.ensure_peaks: media_path required")
    assert(source_mtime, "peak_cache.ensure_peaks: source_mtime required")
    assert(EMP, "peak_cache.ensure_peaks: not initialized")

    if peak_handles[media_id] then return end

    if generation_status[media_id] == "generating" then
        try_finalize_generating(media_id)
        return
    end

    if try_load_existing(media_id, source_mtime, expected_samples) then return end

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

-- Drop in-memory state (handle, pending gen, cached TC) for a media id
-- without touching the on-disk peak file. Caller decides whether to also
-- delete the disk file (full invalidate) or leave it for try_load_existing
-- to re-validate (relink refresh).
local function release_in_memory_state(media_id)
    if peak_handles[media_id] then
        EMP.PEAK_RELEASE(peak_handles[media_id])
        peak_handles[media_id] = nil
    end
    EMP.PEAK_CANCEL(media_id)
    generation_status[media_id] = nil
    media_tc_origins[media_id] = nil
end

--- Invalidate peaks for a media file (relink, mtime change). Drops in-
--- memory state and removes the on-disk peak file. No-op when the cache
--- hasn't been initialized — invalidate guarantees the cache no longer
--- holds this media; if there's no cache, that's already true.
function M.invalidate(media_id)
    assert(media_id, "peak_cache.invalidate: media_id required")
    if not cache_dir then return end
    release_in_memory_state(media_id)
    os.remove(peak_file_path(media_id))
    log.event("peak_cache: invalidated %s", media_id)
end

-- Refresh peak state for one media row that changed (path, TC, etc).
-- Re-fetches the now-current row, repopulates the cached TC origin, and
-- calls ensure_peaks against the new file. Caller has already released
-- in-memory state. Media.load returns nil for deleted rows (e.g. the
-- RelinkClips undo path) and there's nothing further to do for those.
local function refresh_one_media(media_id, Media)
    local media = Media.load(media_id)
    if not media then return end

    set_tc_origin(media)

    local file_path = media:get_file_path()
    local has_audio = media.audio_sample_rate and media.audio_sample_rate > 0
    if not (file_path and file_path ~= "" and has_audio
        and fs_utils.file_exists(file_path)) then
        return
    end
    local mtime = fs_utils.file_mtime(file_path)
    if not mtime then
        log.warn("peak_cache: could not stat %s — skipping peak gen", file_path)
        return
    end
    M.ensure_peaks(media_id, file_path, mtime, nil)
end

--- Re-evaluate peaks for media whose rows changed. Wired to the
--- `media_changed` signal so RelinkClips, importers, and future
--- mutating commands refresh downstream waveforms automatically.
--- ensure_peaks → try_load_existing's mtime + coverage cross-check
--- decides whether the on-disk peak file is still authoritative, so
--- a relink to a byte-identical file (same mtime) reuses the existing
--- peaks instead of triggering needless re-generation. No-op when the
--- cache isn't initialized (no project open yet).
--- @param media_ids table {[media_id]=true} — payload shape from
---        Media.end_batch / Media.mark_dirty.
function M.handle_media_changed(media_ids)
    assert(type(media_ids) == "table",
        "peak_cache.handle_media_changed: media_ids must be a table")
    if not cache_dir then return end

    local Media = require("models.media")
    for media_id in pairs(media_ids) do
        release_in_memory_state(media_id)
        refresh_one_media(media_id, Media)
    end
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

-- Refresh peaks for any media whose row changed (path, TC, etc).
-- Priority 35 puts us after media_status (30) so its offline-status
-- cache is fresh before we decide whether to request new peak gen.
Signals.connect("media_changed", M.handle_media_changed, 35)

return M
