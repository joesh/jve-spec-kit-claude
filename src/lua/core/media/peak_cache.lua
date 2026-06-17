--- Peak data cache — manages loading, generation, and querying of waveform peak data.
---
--- 023: peaks are per (media file, source channel). JVE models one audio clip
--- per stream, so each timeline audio clip plays ONE file channel and must show
--- THAT channel's waveform — not a composite fold. The cache is therefore keyed
--- by a JOB KEY: the bare media_id for the composite envelope (channel -1, the
--- historical layout) and "<media_id>__ch<N>" for a single 0-based file channel.
--- The job key doubles as the EMP job id and the `.peaks` filename stem, so
--- composite files stay "<media_id>.peaks" and per-channel files are
--- "<media_id>__ch<N>.peaks". Peak files live in
--- `~/Library/Caches/JVE/<project_name>_<project_id>/peaks/`.
--- (Pre-2026-06-08 lived sibling to the .jvp; that put them on iCloud-synced
--- storage and caused the relink slow path — see database.get_peak_cache_dir.)
---
--- @module peak_cache
local M = {}
local log = require("core.logger").for_area("media")
local fs_utils = require("core.fs_utils")
local Signals = require("core.signals")

-- EMP bindings (set during init)
local EMP = nil

-- Cache state. peak_handles / generation_status are keyed by JOB KEY (see
-- module doc); media_tc_origins is keyed by media_id because a file's audio
-- TC origin is channel-independent.
local cache_dir = nil          -- absolute path to peaks/ directory
local peak_handles = {}        -- job_key → peak_handle (from EMP.PEAK_LOAD)
local generation_status = {}   -- job_key → "generating" | "complete" | "failed"
local media_tc_origins = {}    -- media_id → audio TC origin in samples (absolute→file-relative)

-- Compose the job key for a (media, channel) pair. channel -1 = composite
-- (key is the bare media_id); channel >= 0 = single file channel.
local function job_key(media_id, channel)
    assert(media_id, "peak_cache.job_key: media_id required")
    assert(type(channel) == "number" and channel >= -1
            and channel == math.floor(channel),
        string.format("peak_cache.job_key: channel must be -1 (composite) or a "
            .. "0-based file channel, got %s", tostring(channel)))
    if channel == -1 then return media_id end
    assert(not tostring(media_id):match("__ch%d+$"), string.format(
        "peak_cache.job_key: media_id %q ends with the per-channel key suffix "
        .. "— would collide with channel peak files", tostring(media_id)))
    return string.format("%s__ch%d", media_id, channel)
end

-- Recover the media_id from a job key (inverse of job_key). Strips a trailing
-- "__ch<N>" if present; otherwise the key is the bare media_id (composite).
local function media_id_from_job_key(key)
    return key:match("^(.+)__ch%d+$") or key
end

--- Get the peak file path for a job key (media_id or media_id__chN).
local function peak_file_path(key)
    assert(cache_dir, "peak_cache: not initialized (call init_for_project first)")
    return cache_dir .. "/" .. key .. ".peaks"
end

-- ============================================================================
-- ensure_peaks subfunctions (rule 2.5)
-- ============================================================================

--- Check if a generating job has completed and load its peaks.
local function try_finalize_generating(key)
    local status = EMP.PEAK_STATUS(key)
    if not status then return end

    if status.state == "complete" then
        local handle, err = EMP.PEAK_LOAD(peak_file_path(key))
        if handle then
            peak_handles[key] = handle
            generation_status[key] = "complete"
            log.event("peak_cache: loaded peaks for %s", key)
        else
            log.warn("peak_cache: generation complete but load failed for %s: %s",
                key, tostring(err))
            generation_status[key] = "failed"
        end
    elseif status.state == "failed" then
        generation_status[key] = "failed"
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
--- Verification policy (v2 hybrid — 2026-06-03):
---   FAST: mtime matches header → accept (skip hash work).
---   SLOW: mtime mismatch + size matches → fingerprint check.
---           hash matches → bytes unchanged (cp/touch/fixture refresh) —
---             refresh stored mtime in place and accept.
---           hash mismatches → real edit — regenerate.
---   FAIL: size mismatch / coverage not ok / hash unavailable → regenerate.
---
--- Coverage check (independent): header's level-0 bin count must cover
--- at least PEAK_COVERAGE_MIN_FRACTION of the media's expected audio
--- sample count. expected_samples nil → coverage check skipped.
---
--- On verification failure, releases the handle, deletes the file,
--- returns false so the caller triggers regeneration.
--- @return boolean true if loaded and valid
local function try_load_existing(key, media_path, source_mtime, expected_samples)
    local path = peak_file_path(key)
    local handle = EMP.PEAK_LOAD(path)
    if not handle then return false end

    local hdr = EMP.PEAK_HEADER(handle)
    assert(hdr, string.format(
        "peak_cache: PEAK_HEADER returned nil for valid handle (key=%s)", key))

    local floored_mtime = math.floor(source_mtime)
    local mtime_matches = (hdr.source_mtime == floored_mtime)

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
                key, tostring(hdr.bins_per_level and hdr.bins_per_level[1])))
        assert(hdr.base_spp and hdr.base_spp > 0,
            string.format("peak_cache: header base_spp invalid for %s (got %s)",
                key, tostring(hdr.base_spp)))
        local peak_samples = hdr.bins_per_level[1] * hdr.base_spp
        if peak_samples < expected_samples * PEAK_COVERAGE_MIN_FRACTION then
            coverage_ok = false
            log.warn("peak_cache: truncated peaks for %s — "
                .. "peak covers %d samples, media has %d (%.1f%%); regenerating",
                key, peak_samples, expected_samples,
                100.0 * peak_samples / expected_samples)
        end
    end

    -- Hash-rescue path: mtime drifted but coverage ok and we have a
    -- media_path to fingerprint. If size + content hash both match the
    -- header, the bytes are unchanged — accept and refresh the stored
    -- mtime so next session's fast path takes effect.
    local hash_rescued = false
    if (not mtime_matches) and coverage_ok and media_path
            and hdr.source_size and hdr.content_hash then
        local fp, fp_err = EMP.MEDIA_CONTENT_HASH(media_path)
        if (not fp) and fp_err then
            -- Distinct failure variants per review HIGH E#5; the cache
            -- still falls through to regen, but logs the specific cause
            -- (stat_failed:<errno> | empty_file) so an unexpected stat
            -- failure on a file we just resolved is visible, not
            -- silently collapsed with "content didn't match".
            log.event("peak_cache: content-hash unavailable for %s (%s) — "
                .. "skipping hash-rescue, will regen",
                key, fp_err)
        end
        if fp and fp.size == hdr.source_size and fp.hash == hdr.content_hash then
            local ok = EMP.PEAK_REFRESH_HEADER_MTIME(path, floored_mtime)
            assert(ok, string.format(
                "peak_cache: PEAK_REFRESH_HEADER_MTIME failed for %s — "
                .. "content matched but in-place mtime rewrite refused", path))
            hash_rescued = true
            log.event("peak_cache: bytes unchanged for %s — refreshed stored "
                .. "mtime %d → %d (cp/touch absorbed, no regen)",
                key, hdr.source_mtime, floored_mtime)
        end
    end

    if (mtime_matches or hash_rescued) and coverage_ok then
        peak_handles[key] = handle
        generation_status[key] = "complete"
        return true
    end

    -- Stale or truncated — release, delete, and let caller regenerate
    EMP.PEAK_RELEASE(handle)
    os.remove(path)
    if not mtime_matches and not hash_rescued then
        log.event("peak_cache: stale peaks for %s (mtime %d vs %s, "
            .. "size %s vs ?, hash mismatch or unavailable), regenerating",
            key, hdr.source_mtime, tostring(source_mtime),
            tostring(hdr.source_size))
    end
    return false
end

--- Test hook: exposes try_load_existing for integration tests that
--- install hand-crafted peak files and verify load-time rejection.
--- Not part of the public API; production callers go through ensure_peaks.
--- media_path may be nil — disables the hash-rescue path for tests
--- that want to exercise the strict mtime-only behavior.
function M._try_load_existing_for_test(media_id, media_path, source_mtime, expected_samples)
    return try_load_existing(media_id, media_path, source_mtime, expected_samples)
end

-- ============================================================================
-- Completion poll timer — triggers timeline repaint as peaks finish generating
-- ============================================================================

local poll_timer_active = false

local function start_completion_poll()
    if poll_timer_active then return end
    if type(qt_create_single_shot_timer) ~= "function" then return end  -- lint-allow: R004 Qt binding may not be wired in pure-Lua test harnesses

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

--- Request background generation for one (media, channel) envelope.
local function request_generation(key, media_path, channel)
    generation_status[key] = "generating"
    EMP.PEAK_REQUEST(key, media_path, peak_file_path(key), channel)
    log.event("peak_cache: requested peak gen for %s (%s, ch=%d)", key, media_path, channel)
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

-- Per-media body of init_for_project's first pass. Caches the channel-
-- independent audio TC origin and records online state + expected sample
-- count keyed by media_id, for the per-channel pass to consume.
local function record_one_media(rec, info, counters, Media, state_by_media)
    assert(rec.file_path and rec.file_path ~= "",
        string.format("peak_cache: media %s has nil/empty file_path", tostring(rec.id)))

    local media_obj = Media.load(rec.id)
    assert(media_obj, string.format(
        "peak_cache: Media.load returned nil for media_id=%s", tostring(rec.id)))

    cache_tc_origin(media_obj, counters)

    local online = fs_utils.file_exists(rec.file_path)
    if not online then
        log.detail("peak_cache: skipping offline %s", rec.file_path)
        counters.offline = counters.offline + 1
    end

    state_by_media[rec.id] = {
        file_path = rec.file_path,
        online = online,
        expected_samples = expected_samples_from_probe(info),
    }
end

-- Trigger peak load (or generation) for one referenced (media, channel)
-- pair. mtime returning nil means "file disappeared between the existence
-- check and the stat", which is rare but real.
local function ensure_channel_peaks(pair, state_by_media, counters)
    local st = state_by_media[pair.media_id]
    -- Both the audio-media scan and the channel enumeration filter on
    -- audio_sample_rate > 0, so every referenced channel's media must have
    -- appeared in the first pass. A miss is a real invariant break.
    assert(st, string.format(
        "peak_cache: channel ref names media %s absent from the audio scan",
        tostring(pair.media_id)))
    if not st.online then return end

    local mtime = fs_utils.file_mtime(st.file_path)
    if not mtime then
        log.warn("peak_cache: could not stat %s — skipping peak gen", st.file_path)
        return
    end

    local key = job_key(pair.media_id, pair.channel)
    local was_loaded = peak_handles[key] ~= nil
    local was_generating = generation_status[key] == "generating"
    M.ensure_peaks(pair.media_id, st.file_path, mtime, st.expected_samples, pair.channel)
    if peak_handles[key] and not was_loaded then
        counters.peaks_loaded = counters.peaks_loaded + 1
    elseif generation_status[key] == "generating" and not was_generating then
        counters.peaks_requested = counters.peaks_requested + 1
    end
end

--- Initialize the peak cache for a project.
--- Two passes: (1) per media file — cache the audio TC origin and online
--- state; (2) per referenced (media, channel) — queue/load that channel's
--- waveform envelope. One audio clip plays one file channel, so the
--- channels enumerated in pass 2 are exactly the waveforms the timeline shows.
function M.init_for_project(project_id)
    assert(project_id and project_id ~= "",
        "peak_cache.init_for_project: project_id required")

    local database = require("core.database")
    cache_dir = database.get_peak_cache_dir(project_id)
    assert(cache_dir and cache_dir ~= "",
        "peak_cache.init_for_project: get_peak_cache_dir returned empty")

    EMP = qt_constants and qt_constants.EMP
    assert(EMP, "peak_cache.init_for_project: qt_constants.EMP not available")

    local t_start = qt_monotonic_s()  -- luacheck: globals qt_monotonic_s

    local Media = require("models.media")
    local audio_media = Media.get_audio_for_project(project_id)
    local channel_refs = Media.get_audio_channels_for_project(project_id)
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

    -- Pass 1: per media — TC origin + online/expected-samples state.
    local state_by_media = {}
    for i, rec in ipairs(audio_media) do
        record_one_media(rec, probes[i], counters, Media, state_by_media)
    end

    -- Pass 2: per referenced channel — generate/load the envelope.
    for _, pair in ipairs(channel_refs) do
        ensure_channel_peaks(pair, state_by_media, counters)
    end

    local t_done = qt_monotonic_s()
    log.event("peak_cache.init_for_project: %d audio media, %d channels "
        .. "(tc_cached=%d tc_extracted=%d peaks_loaded=%d peaks_requested=%d offline=%d) "
        .. "query=%.2fs probe=%.2fs loop=%.2fs total=%.2fs",
        #audio_media, #channel_refs,
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
--- channel: -1 = composite envelope; >= 0 = that file channel (per-channel
--- waveform). One audio clip plays one channel, so callers pass the clip's
--- source_channel.
function M.ensure_peaks(media_id, media_path, source_mtime, expected_samples, channel)
    assert(media_id, "peak_cache.ensure_peaks: media_id required")
    assert(media_path, "peak_cache.ensure_peaks: media_path required")
    assert(source_mtime, "peak_cache.ensure_peaks: source_mtime required")
    assert(EMP, "peak_cache.ensure_peaks: not initialized")

    local key = job_key(media_id, channel)

    if peak_handles[key] then return end

    if generation_status[key] == "generating" then
        try_finalize_generating(key)
        return
    end

    if try_load_existing(key, media_path, source_mtime, expected_samples) then return end

    request_generation(key, media_path, channel)
end

--- Get peak data for the visible region of a clip.
--- source_start/source_end are absolute TC samples (as stored in clip.source_in/source_out).
--- Converts to file-relative samples by subtracting media's audio TC origin.
--- channel: -1 = composite envelope; >= 0 = that file channel (the clip's
--- source_channel). The TC origin is channel-independent (per file).
--- Returns: peaks_ptr, count, actual_abs_start, actual_abs_end
--- The actual range is tagged with absolute TC so the caller can verify alignment.
function M.get_visible_peaks(media_id, source_start, source_end, pixel_width, channel)
    assert(media_id, "peak_cache.get_visible_peaks: media_id required")
    assert(type(source_start) == "number", "peak_cache.get_visible_peaks: source_start must be number")
    assert(type(source_end) == "number", "peak_cache.get_visible_peaks: source_end must be number")
    assert(type(pixel_width) == "number", "peak_cache.get_visible_peaks: pixel_width must be number")

    if pixel_width <= 0 or source_end <= source_start then return nil, 0, 0, 0 end

    local key = job_key(media_id, channel)

    -- Convert absolute TC → file-relative by subtracting media's audio TC origin.
    -- No TC origin: init hasn't run yet or media not in audio scan.
    if media_tc_origins[media_id] == nil then return nil, 0, 0, 0 end
    local tc_origin = media_tc_origins[media_id]
    local file_start = source_start - tc_origin
    local file_end = source_end - tc_origin
    if file_start < 0 then file_start = 0 end
    if file_end <= file_start then return nil, 0, 0, 0 end

    -- Completed peak file — query mmap'd data (full mipmap support)
    local handle = peak_handles[key]
    if handle then
        local peaks, count, actual_file_start, actual_file_end =
            EMP.PEAK_QUERY(handle, file_start, file_end, pixel_width)

        if not peaks or count <= 0 then return nil, 0, 0, 0 end

        local actual_abs_start = actual_file_start + tc_origin
        local actual_abs_end = actual_file_end + tc_origin
        return peaks, count, actual_abs_start, actual_abs_end
    end

    -- In-progress generation — query live buffer (level 0 only, progressive)
    if generation_status[key] == "generating" then
        local peaks, count, actual_file_start, actual_file_end =
            EMP.PEAK_QUERY_PROGRESS(key, file_start, file_end, pixel_width)

        if not peaks or count <= 0 then return nil, 0, 0, 0 end

        local actual_abs_start = actual_file_start + tc_origin
        local actual_abs_end = actual_file_end + tc_origin
        return peaks, count, actual_abs_start, actual_abs_end
    end

    return nil, 0, 0, 0
end

--- Get a folded composite waveform for an Adaptive (composite) audio clip.
--- Such a clip is ONE timeline audio clip standing for a whole multi-channel
--- master whose channels live on N master tracks across possibly MULTIPLE media
--- files (e.g. a synced clip: camera scratch + N WAV channels). It has no single
--- per-channel source window, so we fold the per-channel envelopes on demand —
--- the per-channel .peaks are the single source of truth (no persisted composite).
---
--- refs: array of { media_id, source_channel, source_in_frame,
---       sequence_start_frame, audio_sample_rate } — one per master audio ref.
---       source_in_frame is the ref's absolute-TC sample origin in its file;
---       sequence_start_frame is the ref's position on the master timeline (frames).
--- vis_start_mf/vis_end_mf: visible window in MASTER-DOMAIN FRAMES (a composite
---       clip stores source_in/out in master frames, not samples).
--- fps_num/fps_den: master sequence frame rate (frames -> samples bridge).
--- Returns: peaks_ptr, count, actual_start_mf, actual_end_mf (master-frame domain;
--- full coverage — composite channels are loaded envelopes, not progressive).
function M.get_composite_peaks(refs, vis_start_mf, vis_end_mf, pixel_width, fps_num, fps_den)
    assert(type(refs) == "table", "peak_cache.get_composite_peaks: refs table required")
    assert(type(vis_start_mf) == "number" and type(vis_end_mf) == "number",
        "peak_cache.get_composite_peaks: vis window must be numbers")
    assert(type(pixel_width) == "number", "peak_cache.get_composite_peaks: pixel_width number")
    assert(type(fps_num) == "number" and fps_num > 0
            and type(fps_den) == "number" and fps_den > 0,
        "peak_cache.get_composite_peaks: fps_num/fps_den must be positive numbers")

    if pixel_width <= 0 or vis_end_mf <= vis_start_mf then return nil, 0, 0, 0 end

    -- Map the master-frame window to each ref's file-relative sample window
    -- (the same transform get_visible_peaks does per clip, applied per ref) and
    -- collect the loaded handles for the C-side per-pixel fold.
    local query_refs = {}
    for _, ref in ipairs(refs) do
        local tc_origin = media_tc_origins[ref.media_id]
        local handle = peak_handles[job_key(ref.media_id, ref.source_channel)]
        if tc_origin and handle then
            -- samples per master frame for this ref's media
            local spf = ref.audio_sample_rate * fps_den / fps_num
            local abs_start = ref.source_in_frame + (vis_start_mf - ref.sequence_start_frame) * spf
            local abs_end   = ref.source_in_frame + (vis_end_mf   - ref.sequence_start_frame) * spf
            local file_start = abs_start - tc_origin
            local file_end   = abs_end - tc_origin
            if file_start < 0 then file_start = 0 end
            if file_end > file_start then
                query_refs[#query_refs + 1] = {
                    handle = handle,
                    start  = math.floor(file_start),
                    ["end"] = math.floor(file_end),
                }
            end
        end
    end

    if #query_refs == 0 then return nil, 0, 0, 0 end

    local peaks, count = EMP.PEAK_QUERY_COMPOSITE(query_refs, pixel_width)
    if not peaks or count <= 0 then return nil, 0, 0, 0 end
    return peaks, count, vis_start_mf, vis_end_mf
end

--- Get generation status for one (media, channel) envelope.
function M.get_status(media_id, channel)
    local key = job_key(media_id, channel)
    if peak_handles[key] then return "complete" end
    return generation_status[key] or "none"
end

-- Drop the in-memory handle + pending-gen state for ONE job key without
-- touching the on-disk peak file. Does not touch the media's TC origin
-- (channel-independent — see release_all_for_media).
local function release_key_in_memory(key)
    if peak_handles[key] then
        EMP.PEAK_RELEASE(peak_handles[key])
        peak_handles[key] = nil
    end
    EMP.PEAK_CANCEL(key)
    generation_status[key] = nil
end

-- Collect every job key currently held (handle or pending gen) that belongs
-- to a media file — its composite key plus all per-channel keys.
local function job_keys_for_media(media_id)
    local keys = {}
    for key in pairs(peak_handles) do
        if media_id_from_job_key(key) == media_id then keys[key] = true end
    end
    for key in pairs(generation_status) do
        if media_id_from_job_key(key) == media_id then keys[key] = true end
    end
    return keys
end

-- Drop in-memory state (every channel's handle + pending gen, plus the
-- cached TC origin) for a media id without touching on-disk peak files.
local function release_all_for_media(media_id)
    for key in pairs(job_keys_for_media(media_id)) do
        release_key_in_memory(key)
    end
    media_tc_origins[media_id] = nil
end

-- Remove every on-disk peak file belonging to a media (composite +
-- per-channel). Caller has already released the in-memory state.
local function remove_peak_files_for_media(media_id)
    for _, filename in ipairs(fs_utils.list_dir(cache_dir)) do
        local stem = filename:match("^(.+)%.peaks$")
        if stem and media_id_from_job_key(stem) == media_id then
            os.remove(cache_dir .. "/" .. filename)
        end
    end
end

--- Invalidate peaks for a media file (relink, mtime change). Drops in-
--- memory state and removes the on-disk peak files for every channel. No-op
--- when the cache hasn't been initialized — invalidate guarantees the cache
--- no longer holds this media; if there's no cache, that's already true.
function M.invalidate(media_id)
    assert(media_id, "peak_cache.invalidate: media_id required")
    if not cache_dir then return end
    release_all_for_media(media_id)
    remove_peak_files_for_media(media_id)
    log.event("peak_cache: invalidated %s (all channels)", media_id)
end

-- Refresh peak state for one media row that changed (path, TC, etc).
-- Re-fetches the now-current row, repopulates the cached TC origin, and
-- re-requests each referenced channel against the new file. Caller has
-- already released in-memory state. Media.load returns nil for deleted rows
-- (e.g. the RelinkClips undo path) and there's nothing further to do.
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
    for _, channel in ipairs(Media.get_audio_channels_for_media(media_id)) do
        M.ensure_peaks(media_id, file_path, mtime, nil, channel)
    end
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
        release_all_for_media(media_id)
        refresh_one_media(media_id, Media)
    end
end

--- Cleanup orphaned peak files. A file is `<media_id>.peaks` (composite) or
--- `<media_id>__ch<N>.peaks` (per-channel); both map to the same media_id,
--- so a file is an orphan iff its media is no longer active.
function M.cleanup_orphans(active_media_ids)
    assert(cache_dir, "peak_cache.cleanup_orphans: not initialized")
    assert(type(active_media_ids) == "table",
        "peak_cache.cleanup_orphans: active_media_ids table required")

    for _, filename in ipairs(fs_utils.list_dir(cache_dir)) do
        local stem = filename:match("^(.+)%.peaks$")
        local media_id = stem and media_id_from_job_key(stem)
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
Signals.connect("media_changed", M.handle_media_changed, 35)  -- lint-allow: R009 process-lifetime peak-refresh listener

return M
