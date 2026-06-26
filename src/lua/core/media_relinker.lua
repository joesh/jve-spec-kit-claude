--- Media relinker: reconnect offline media files to project clips.
--
-- Responsibilities:
-- - Enumerate project media (find_offline_media, find_project_media,
--   find_media_for_clips)
-- - Scan search directories for candidate files (scan_directory,
--   build_candidate_index)
-- - Probe candidates via ffprobe for TC + media properties (probe_file)
-- - Per-media candidate matching: filename, TC, resolution, fps
--   (find_candidates_for_media)
-- - Per-clip containment check for trimmed media (check_clip_containment)
-- - Segment-file fan-out for split recordings (build_segment_index,
--   match_segment_filename)
-- - Batch dispatch + result classification (relink_media_batch)
--
-- Non-goals:
-- - Database mutation — handled by the RelinkClips command
-- - UI — handled by media_relink_dialog
-- - Adjusting source_in/source_out — source ranges are absolute TC and are
--   never mutated on relink. The C++ decoder computes
--   file_pos = source_in - file_tc_origin at decode time.
--
-- Invariants:
-- - One ffprobe call per candidate file across an entire batch (probe_cache
--   in relink_media_batch). Matching is per-media, not per-clip, so a file
--   shared by N clips is probed once, not N times.
-- - Media-level matching runs once per media_info; per-clip containment
--   only runs when a candidate has a TC mismatch and accept_trimmed_media
--   is enabled.
-- - Proxy media (files under ProxyMedia/) are never relinked.
--
-- @file media_relinker.lua
local M = {}
local log = require("core.logger").for_area("media")
local shell_capture = require("core.fs_utils").shell_capture
local dir_exists = require("core.fs_utils").dir_exists
local frame_utils = require("core.frame_utils")

--- Check if file exists at given path
-- @param file_path string Absolute path to check
-- @return boolean True if file exists and is readable
local function file_exists(file_path)
    local file = io.open(file_path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

--- Extract filename from full path
-- @param file_path string Full path like "/path/to/file.mov"
-- @return string Just the filename "file.mov"
local function get_filename(file_path)
    return file_path:match("([^/\\]+)$") or file_path
end

--- Search directory recursively for media files
-- @param root_dir string Directory to search
-- @param extensions table Set of extensions to include (e.g., {mov=true, mp4=true})
-- @return table Array of absolute file paths
local function scan_directory(root_dir, extensions)
    assert(dir_exists(root_dir), string.format(
        "scan_directory: search directory does not exist: %s", root_dir))

    local results = {}

    -- Use find command for efficiency (Lua's directory traversal is slow)
    local ext_list = {}
    for ext, _ in pairs(extensions) do
        table.insert(ext_list, string.format("-iname '*.%s'", ext))
    end
    local ext_pattern = table.concat(ext_list, " -o ")

    local cmd = string.format('find -L "%s" -type f \\( %s \\)', root_dir, ext_pattern)
    log.event("scan_directory: %s", cmd)

    local output = shell_capture(cmd, "scan_directory")
    for line in output:gmatch("[^\n]+") do
        if line ~= "" then
            results[#results + 1] = line
        end
    end

    log.event("scan_directory: found %d files", #results)
    return results
end

--- Scan every search path and build a basename-lower → [absolute paths] index.
-- The index is the only thing the matcher needs; a flat file list is not built.
-- @param search_paths table Non-empty array of directories to scan
-- @param extensions table Non-empty set of extensions (e.g., {mov=true, wav=true})
-- @return table {basename_lower → [path, ...]}
local function build_candidate_index(search_paths, extensions)
    assert(type(search_paths) == "table" and #search_paths > 0,
        "build_candidate_index: search_paths must be a non-empty array")
    assert(type(extensions) == "table" and next(extensions) ~= nil,
        "build_candidate_index: extensions must be a non-empty set")

    local candidate_index = {}

    for _, search_path in ipairs(search_paths) do
        local files = scan_directory(search_path, extensions)
        for _, file_path in ipairs(files) do
            local filename = get_filename(file_path)
            local key = filename:lower()
            local bucket = candidate_index[key]
            if not bucket then
                bucket = {}
                candidate_index[key] = bucket
            end
            bucket[#bucket + 1] = file_path
        end
    end

    return candidate_index
end

--- Convert TC string "HH:MM:SS:FF" to total frames.
-- @param tc string Timecode like "00:40:33:02"
-- @param fps number Frames per second (integer)
-- @return number|nil Total frames
local function tc_to_frames(tc, fps)
    if not tc or not fps or fps <= 0 then return nil end
    local h, m, s, f = tc:match("(%d+):(%d+):(%d+):(%d+)")
    if not h then return nil end
    return tonumber(h) * 3600 * fps + tonumber(m) * 60 * fps + tonumber(s) * fps + tonumber(f)
end

--- Convert an EMP MediaFileInfo table into the probe_file result shape.
-- Extracted so both the single-shot probe and the bulk-probe prefetch path
-- share exactly one place where EMP → relinker field mapping lives.
-- Returns nil when the info has neither video dimensions nor a discoverable
-- audio duration (caller decides whether to log).
--
-- PRESENCE-FLAG CONTRACT: this function reads `has_video_tc_origin`,
-- `has_audio_tc_origin`, and `has_duration` to decide whether to
-- populate start_tc_value / duration_frames. Any new presence flag
-- added here MUST also be added to REQUIRED_INFO_FIELDS in
-- core/media_probe_cache.lua AND the CACHE_VERSION bumped — otherwise
-- stale caches written before the flag existed will silently serve
-- entries where the new flag is nil/falsy, producing wrong downstream
-- behavior (TSO 2026-04-21: 477 of 562 clips appeared offline after
-- relink because has_duration was missing from pre-c2b2b505 cache
-- entries, collapsing cand_dur to 0).
local function probe_result_from_emp_info(info)
    if not info then return nil end

    local result = {}
    local has_video = info.has_video and info.width and info.width > 0
    local has_audio_only = (not has_video) and info.has_audio
        and info.audio_sample_rate and info.audio_sample_rate > 0

    if has_video then
        result.width = info.width
        result.height = info.height
        result.fps_num = info.fps_num
        result.fps_den = info.fps_den
        if info.fps_num and info.fps_den and info.fps_den > 0 then
            local fps_int = math.floor(info.fps_num / info.fps_den + 0.5)
            -- Only report a TC value when EMP confirms an authoritative
            -- source (MOV tmcd, MXF start_time, BRAW metadata). Otherwise
            -- leave start_tc_value nil so the matcher accepts the candidate
            -- on non-TC criteria — this matches the old ffprobe behavior
            -- (nil when no tmcd tag present) and keeps files without TC
            -- from being wrongly rejected against a nonzero stored TC.
            if fps_int > 0 and info.has_video_tc_origin then
                result.start_tc_value = info.first_frame_tc
                result.start_tc_rate = fps_int
                -- Surface every distinct video TC the container holds
                -- (multi-tmcd files: render TC + original TC). Primary
                -- equals start_tc_value (vec[0] by EMP contract). Matchers
                -- that need to consider alternative TCs walk this list.
                assert(info.all_video_tc_origins
                    and #info.all_video_tc_origins > 0
                    and info.all_video_tc_origins[1] == info.first_frame_tc,
                    "probe_result_from_emp_info: all_video_tc_origins[1] "
                    .. "must equal first_frame_tc (primary)")
                result.all_video_tc_origins = info.all_video_tc_origins
            end
            -- Audio TC for video-with-audio files. EMP derives this from
            -- video_tc on the shared-clock assumption when the audio stream
            -- lacks its own authoritative TC. Carried alongside video TC so
            -- downstream metadata writes don't need a second probe.
            -- Invariant: has_audio_tc_origin implies has_audio AND a valid
            -- audio_sample_rate — EMP only flips has_audio_tc_origin after
            -- a successful extract/derive against a >0 rate. Assert rather
            -- than silently skip so a future EMP regression surfaces here.
            if info.has_audio_tc_origin then
                assert(info.has_audio, "probe_result_from_emp_info: "
                    .. "has_audio_tc_origin without has_audio for " .. tostring(info.path))
                assert(info.audio_sample_rate and info.audio_sample_rate > 0,
                    "probe_result_from_emp_info: has_audio_tc_origin requires "
                    .. "audio_sample_rate > 0, got " .. tostring(info.audio_sample_rate)
                    .. " for " .. tostring(info.path))
                result.start_tc_audio_samples = info.first_sample_tc
                result.start_tc_audio_rate = info.audio_sample_rate
                assert(info.all_audio_tc_origins
                    and #info.all_audio_tc_origins > 0
                    and info.all_audio_tc_origins[1] == info.first_sample_tc,
                    "probe_result_from_emp_info: all_audio_tc_origins[1] "
                    .. "must equal first_sample_tc (primary)")
                result.all_audio_tc_origins = info.all_audio_tc_origins
            end
            -- Only derive duration_frames when EMP reports an
            -- authoritative duration source (has_duration). A
            -- duration_us=0 without has_duration means "unknown" (no
            -- container-level duration found); computing 0 frames for
            -- that case would silently feed the matcher wrong data.
            -- With has_duration=true and duration_us=0 (single-frame
            -- stills), we still skip — a 0-frame extent can't contain
            -- anything for containment checks.
            if info.has_duration and info.duration_us and info.duration_us > 0 then
                -- Prefer the container's authoritative video_frame_count
                -- when the demuxer exposes it (BRAW SDK). The
                -- duration_us round-trip is lossy at non-integer fps;
                -- on 23.976 BRAW the audio derivation in particular
                -- overshoots by ~1‰ because the container records audio
                -- at the nominal 24fps rate, not the pulldown rate.
                if info.video_frame_count and info.video_frame_count > 0 then
                    result.duration_frames = info.video_frame_count
                else
                    result.duration_frames = math.floor(
                        info.duration_us * info.fps_num
                            / (info.fps_den * 1000000) + 0.5)
                end
                -- For V+A files, also surface the audio-sample extent so
                -- the relink path can sync audio media_refs (their
                -- duration_frames are in samples). Same authority order:
                -- container's audio_sample_count wins over derivation.
                if info.has_audio and info.audio_sample_rate
                    and info.audio_sample_rate > 0
                then
                    if info.audio_sample_count and info.audio_sample_count > 0 then
                        result.audio_duration_samples = info.audio_sample_count
                    else
                        result.audio_duration_samples = math.floor(
                            info.duration_us * info.audio_sample_rate / 1000000 + 0.5)
                    end
                end
            end
        end
        -- A video stream with no temporal duration IS a still image (EMP
        -- reports has_video with has_duration=false / duration_us=0 for
        -- TIFF/PNG/JPEG/…). The model represents a still as a single-frame
        -- media — Media.classify_is_still keys on duration_frames == 1 — so
        -- mirror that here. Without it the still has no duration_frames and
        -- check_extent_containment drops it as "duration unreadable",
        -- leaving the still permanently unrelinkable.
        if not result.duration_frames then
            result.duration_frames = 1
        end
    elseif has_audio_only then
        local sr = info.audio_sample_rate
        result.fps_num = sr
        result.fps_den = 1
        -- Audio-only files: write the audio TC pair only. The pre-
        -- normalization convention also wrote start_tc_value with rate=sr
        -- (the overload), which produced the 4-second-late playback bug
        -- on DRP audio masters when start_tc_value (DRP claim) drifted
        -- from start_tc_audio_samples (BWF time_reference). Leaving
        -- start_tc_value nil is the post-normalization invariant: V
        -- fields are V-only, audio TC lives only on start_tc_audio_*.
        if info.has_audio_tc_origin then
            result.start_tc_audio_samples = info.first_sample_tc
            result.start_tc_audio_rate    = sr
            assert(info.all_audio_tc_origins
                and #info.all_audio_tc_origins > 0
                and info.all_audio_tc_origins[1] == info.first_sample_tc,
                "probe_result_from_emp_info (audio-only): all_audio_tc_origins[1] "
                .. "must equal first_sample_tc (primary)")
            result.all_audio_tc_origins = info.all_audio_tc_origins
        end
        if info.has_duration and info.duration_us and info.duration_us > 0 then
            local samples = math.floor(
                info.duration_us * sr / 1000000 + 0.5)
            -- Convention for A-only files: duration_frames carries the
            -- sample count (matches Media.create / media_refs).
            -- Mirror to audio_duration_samples so the relink-duration
            -- update can sync A media_refs in their sample units.
            result.duration_frames = samples
            result.audio_duration_samples = samples
        end
    end

    if not result.width and not result.duration_frames then
        return nil
    end
    return result
end

--- Single-shot probe via EMP (in-process libavformat, full stream analysis).
-- Used for paths not in the bulk pre-probe set — specifically segment
-- candidates injected after the initial prefetch. The heavy lifting
-- happens in MEDIA_PROBE_BATCH; this path covers the rare single file.
-- @param file_path string
-- @return table|nil probe result shape (see probe_result_from_emp_info),
--                   nil on EMP open failure or unprobable content
local function probe_file_emp(file_path)
    local EMP = qt_constants and qt_constants.EMP
    assert(EMP and EMP.MEDIA_PROBE,
        "probe_file_emp: EMP.MEDIA_PROBE binding required but not loaded")

    local info, err = EMP.MEDIA_PROBE(file_path)
    if not info then
        log.detail("probe_file_emp: EMP probe failed for %s: %s",
            file_path, tostring(err))
        return nil
    end

    local result = probe_result_from_emp_info(info)
    if not result then
        log.detail("probe_file_emp: no video dims or audio duration in %s",
            file_path)
    end
    return result
end

-- Single-file probe is the public seam for callers (and tests) that need to
-- interpret one file the same way the batch relink path does.
M.probe_file_emp = probe_file_emp

--- Pre-probe a set of candidate paths in parallel and populate a probe cache.
-- Uses EMP.MEDIA_PROBE_BATCH with default parallelism (hardware_concurrency).
-- cache[path] is set to a result table on success or `false` on failure, so
-- cached_probe can distinguish "not yet probed" (nil) from "probed, got nothing"
-- (false).
-- @param cache table mutated in place
-- @param paths table array of absolute paths to probe
-- @return number probes performed (always #paths), number wall seconds
local function preprobe_batch(cache, paths)
    if #paths == 0 then return 0, 0 end

    -- Route through the disk-backed probe cache rather than calling
    -- EMP directly. First invocation still pays the EMP parallel probe
    -- cost (~3s for this project's 562 candidates) and writes results
    -- to ~/.jve/probe_cache.json keyed by (path, mtime, size).
    -- Subsequent invocations on unchanged files return the cached info
    -- instantly — matches the iterative workflow where the user tweaks
    -- rules / search dirs and re-runs relink several times per session.
    local probe_cache_module = require("core.media_probe_cache")
    local t0 = qt_monotonic_s()
    local results = probe_cache_module.probe_batch(paths)
    for i = 1, #paths do
        local info = results[i]
        if info then
            cache[paths[i]] = probe_result_from_emp_info(info) or false
        else
            cache[paths[i]] = false
        end
    end
    return #paths, qt_monotonic_s() - t0
end

--- Probe via ffprobe subprocess (fallback for unit-test contexts where C++
-- bindings aren't loaded). Reads MOV `timecode` tag for video TC, BWF
-- `time_reference` for audio TC. Each call forks + waits + parses JSON.
-- Returns same shape as probe_file_emp.
-- @param file_path string
-- @return table|nil
local function probe_file_ffprobe(file_path)
    local escaped = string.format('"%s"', file_path:gsub('"', '\\"'))
    local cmd = string.format(
        'ffprobe -v error -print_format json -show_format -show_streams %s',
        escaped)
    local ok, output = pcall(shell_capture, cmd, "probe_file")
    if not ok or not output or output == "" then
        log.detail("probe_file_ffprobe: ffprobe failed for %s", file_path)
        return nil
    end

    local json_mod = require("dkjson")
    local data = json_mod.decode(output)
    if not data then
        log.detail("probe_file_ffprobe: JSON decode failed for %s", file_path)
        return nil
    end

    local result = {}

    -- Extract TC: Strategy 1 — Video TC tag "HH:MM:SS:FF"
    local tc_str = nil
    if data.format and data.format.tags then
        tc_str = data.format.tags.timecode or data.format.tags.TIMECODE
    end
    if not tc_str and data.streams then
        for _, stream in ipairs(data.streams) do
            if stream.tags then
                tc_str = stream.tags.timecode or stream.tags.TIMECODE
                if tc_str then break end
            end
        end
    end

    -- Extract media properties from streams
    if data.streams then
        for _, stream in ipairs(data.streams) do
            if stream.codec_type == "video" then
                result.width = tonumber(stream.width)
                result.height = tonumber(stream.height)
                if stream.r_frame_rate then
                    local num, den = stream.r_frame_rate:match("(%d+)/(%d+)")
                    if num and den then
                        result.fps_num = tonumber(num)
                        result.fps_den = tonumber(den)
                    end
                end
                if stream.nb_frames then
                    result.duration_frames = tonumber(stream.nb_frames)
                elseif stream.duration and result.fps_num and result.fps_den then
                    result.duration_frames = math.floor(
                        tonumber(stream.duration) * result.fps_num / result.fps_den + 0.5)
                end
                if tc_str and result.fps_num and result.fps_den then
                    local fps = math.floor(result.fps_num / result.fps_den + 0.5)
                    if fps > 0 then
                        local frames = tc_to_frames(tc_str, fps)
                        if frames then
                            result.start_tc_value = frames
                            result.start_tc_rate = fps
                            -- Walk every stream + format-level timecode tag,
                            -- collect distinct frame values. Primary (vec[1])
                            -- equals start_tc_value to mirror EMP contract.
                            local origins = { frames }
                            local seen = { [frames] = true }
                            local function try_add(s)
                                if not s then return end
                                local f = tc_to_frames(s, fps)
                                if f and not seen[f] then
                                    seen[f] = true
                                    origins[#origins + 1] = f
                                end
                            end
                            if data.format and data.format.tags then
                                try_add(data.format.tags.timecode
                                    or data.format.tags.TIMECODE)
                            end
                            if data.streams then
                                for _, s in ipairs(data.streams) do
                                    if s.tags then
                                        try_add(s.tags.timecode or s.tags.TIMECODE)
                                    end
                                end
                            end
                            result.all_video_tc_origins = origins
                        end
                    end
                end
            elseif stream.codec_type == "audio" and not result.width then
                local sample_rate = tonumber(stream.sample_rate)
                if sample_rate and sample_rate > 0 then
                    result.fps_num = sample_rate
                    result.fps_den = 1
                    if stream.duration then
                        result.duration_frames = math.floor(
                            tonumber(stream.duration) * sample_rate + 0.5)
                    elseif stream.nb_frames then
                        result.duration_frames = tonumber(stream.nb_frames)
                    end
                    -- A-only convention (mirrors probe_result_from_emp_info):
                    -- duration_frames here IS the sample count. Surface the
                    -- same value as audio_duration_samples so the relink
                    -- duration-update path can sync A media_refs.
                    result.audio_duration_samples = result.duration_frames
                end
            elseif stream.codec_type == "audio" and result.width
                and not result.audio_duration_samples
            then
                -- V+A file: mirror EMP path — derive audio sample extent
                -- from the audio stream's own duration so A media_refs
                -- can be synced in sample units.
                local sample_rate = tonumber(stream.sample_rate)
                if sample_rate and sample_rate > 0 and stream.duration then
                    result.audio_duration_samples = math.floor(
                        tonumber(stream.duration) * sample_rate + 0.5)
                end
            end
        end
    end

    -- Extract TC: Strategy 2 — BWF time_reference (audio files without
    -- video TC). Writes the A pair only; the V pair stays nil for audio-
    -- only files (post-normalization, retires the overload).
    if not result.start_tc_audio_samples and data.format and data.format.tags then
        local time_ref = tonumber(data.format.tags.time_reference)
        if time_ref then
            local sample_rate = result.fps_num
            if sample_rate and sample_rate > 0 and not result.width then
                result.start_tc_audio_samples = time_ref
                result.start_tc_audio_rate    = sample_rate
                -- Audio TC sources are exclusive (BWF is the only source
                -- here). Single-entry array preserves shape uniformity
                -- with the video side.
                result.all_audio_tc_origins = { time_ref }
            end
        end
    end

    if not result.width and not result.duration_frames then
        log.detail("probe_file_ffprobe: no video dims or audio duration in %s", file_path)
        return nil
    end

    return result
end

--- Resolve the probe implementation once per process based on capability.
-- Under the editor process, EMP bindings are loaded → in-process libavformat
-- probe (100–1000× faster than ffprobe fork). Under plain luajit tests, EMP
-- isn't registered → fall through to ffprobe so the test suite still runs.
-- The choice is logged so it's obvious in logs which path served a batch.
local _probe_impl = nil
local function probe_file(file_path)
    if _probe_impl == nil then
        local EMP = qt_constants and qt_constants.EMP
        if EMP and EMP.MEDIA_FILE_OPEN then
            log.event("probe: using EMP in-process libavformat")
            _probe_impl = probe_file_emp
        else
            log.event("probe: EMP unavailable, using ffprobe subprocess")
            _probe_impl = probe_file_ffprobe
        end
    end
    return _probe_impl(file_path)
end



--- Check if a media path is a proxy (Resolve ProxyMedia directory).
-- Proxy media should not be relinked — they're derivative copies.
-- @param path string File path
-- @return boolean True if path is a proxy
local function is_proxy_path(path)
    return path:find("/ProxyMedia/") ~= nil
end

--- Find offline media in project (excludes proxy media).
-- Single SELECT hydrates every row — no per-media Media.load round-trip.
-- @param db table Database connection (unused; Media.load_for_project uses
--          the shared database connection module — kept for API compat)
-- @param project_id string Project ID to check
-- @return table Array of offline Media instances
function M.find_offline_media(db, project_id)
    assert(db, "find_offline_media: db required")
    assert(project_id, "find_offline_media: project_id required")

    local Media = require("models.media")
    local all_media = Media.load_for_project(project_id)

    local offline = {}
    local proxy_count = 0
    for _, media in ipairs(all_media) do
        local path = media:get_file_path()
        if not file_exists(path) then
            if is_proxy_path(path) then
                proxy_count = proxy_count + 1
            else
                offline[#offline + 1] = media
            end
        end
    end

    if proxy_count > 0 then
        log.event("find_offline_media: skipped %d proxy media (ProxyMedia/)", proxy_count)
    end

    return offline
end

--- Find ALL non-proxy media in project (online + offline).
-- @param db table Database connection (unused; see find_offline_media)
-- @param project_id string Project ID
-- @return table Array of Media instances
function M.find_project_media(db, project_id)
    assert(db, "find_project_media: db required")
    assert(project_id, "find_project_media: project_id required")

    local Media = require("models.media")
    local all_media = Media.load_for_project(project_id)

    local results = {}
    local proxy_count = 0
    for _, media in ipairs(all_media) do
        if is_proxy_path(media:get_file_path()) then
            proxy_count = proxy_count + 1
        else
            results[#results + 1] = media
        end
    end

    if proxy_count > 0 then
        log.event("find_project_media: skipped %d proxy media (ProxyMedia/)", proxy_count)
    end
    log.event("find_project_media: %d media in project %s", #results, project_id)
    return results
end

--- Run a prepared IN(...) query and feed each (col0, col1) result pair to consume.
local function for_each_in_query(db, sql, bind_values, what, consume)
    local stmt = assert(db:prepare(sql),
        string.format("find_media_for_clips: failed to prepare %s query", what))
    for i, v in ipairs(bind_values) do stmt:bind_value(i, v) end
    assert(stmt:exec(),
        string.format("find_media_for_clips: %s query exec failed", what))
    while stmt:next() do
        consume(stmt:value(0), stmt:value(1))
    end
    stmt:finalize()
end

--- Find unique media records for a set of clip IDs (excludes proxy).
-- Deduplicates: multiple clips sharing the same media → one media record.
--
-- Two id kinds are accepted, because a selection may hold either:
--   * real clips — rows in `clips`; resolve media via the clips→media_refs JOIN.
--   * master virtual clips — synthesized by database.load_master_virtual_clips,
--     id = MASTER_VIRTUAL_CLIP_PREFIX .. media_ref_id, NOT rows in `clips`;
--     resolve media directly from media_refs by id (e.g. relinking from a
--     master shown in the Source viewer).
-- @param db table Database connection
-- @param clip_ids table Array of clip ID strings (real and/or virtual)
-- @return table Array of unique Media instances
function M.find_media_for_clips(db, clip_ids)
    assert(db, "find_media_for_clips: db required")
    assert(type(clip_ids) == "table" and #clip_ids > 0,
        "find_media_for_clips: clip_ids must be non-empty array")

    local database = require("core.database")
    local prefix = database.MASTER_VIRTUAL_CLIP_PREFIX

    -- Partition the request by id kind.
    local real_clip_ids = {}
    local mref_ids = {}            -- bare media_ref ids (prefix stripped)
    for _, id in ipairs(clip_ids) do
        if id:sub(1, #prefix) == prefix then
            mref_ids[#mref_ids + 1] = id:sub(#prefix + 1)
        else
            real_clip_ids[#real_clip_ids + 1] = id
        end
    end

    -- Accumulate distinct media ids; mark which requested ids resolved.
    local seen = {}
    local distinct_ids = {}
    local found = {}
    local function record_media(requested_id, media_id)
        assert(media_id, string.format(
            "find_media_for_clips: %s has no media_id", requested_id))
        found[requested_id] = true
        if not seen[media_id] then
            seen[media_id] = true
            distinct_ids[#distinct_ids + 1] = media_id
        end
    end

    if #real_clip_ids > 0 then
        -- V13: clips reference master sequences via sequence_id; the master
        -- holds media_refs that point at media. JOIN through both.
        local sql = string.format([[
            SELECT c.id, mr.media_id
              FROM clips c
              JOIN media_refs mr ON mr.owner_sequence_id = c.sequence_id
             WHERE c.id IN (%s)
        ]], database.in_placeholders(#real_clip_ids))
        for_each_in_query(db, sql, real_clip_ids, "clips", record_media)
    end

    if #mref_ids > 0 then
        -- Master virtual clips map one-to-one to a media_ref.
        local sql = string.format([[
            SELECT mr.id, mr.media_id
              FROM media_refs mr
             WHERE mr.id IN (%s)
        ]], database.in_placeholders(#mref_ids))
        for_each_in_query(db, sql, mref_ids, "media_refs", function(ref_id, media_id)
            record_media(prefix .. ref_id, media_id)
        end)
    end

    -- Preserve fail-fast: every requested clip id must have resolved to media.
    for _, clip_id in ipairs(clip_ids) do
        assert(found[clip_id],
            string.format("find_media_for_clips: clip not found: %s", clip_id))
    end

    -- One batched query to hydrate every distinct media.
    local Media = require("models.media")
    local media_list = Media.load_many(distinct_ids)
    assert(#media_list == #distinct_ids, string.format(
        "find_media_for_clips: loaded %d media but expected %d distinct ids "
        .. "(some clips reference missing media rows)",
        #media_list, #distinct_ids))

    -- Filter proxies.
    local results = {}
    for _, media in ipairs(media_list) do
        if not is_proxy_path(media:get_file_path()) then
            results[#results + 1] = media
        end
    end

    log.event("find_media_for_clips: %d unique media from %d clips", #results, #clip_ids)
    return results
end

-- =============================================================================
-- Pure algorithm functions (TC math, containment, segment matching, filtering)
-- =============================================================================

--- Compute TC offset between stored and candidate start timecodes.
-- Returns offset in frames at stored_rate.
-- Offset = candidate_tc - stored_tc (both rescaled to stored_rate).
-- @param stored_value number Stored start TC (frames at stored_rate)
-- @param stored_rate number Rate of stored value
-- @param candidate_value number Candidate start TC (frames at candidate_rate)
-- @param candidate_rate number Rate of candidate value
-- @return number Offset in frames at stored_rate
function M.compute_tc_offset(stored_value, stored_rate, candidate_value, candidate_rate)
    assert(type(stored_value) == "number", "compute_tc_offset: stored_value required")
    assert(type(stored_rate) == "number" and stored_rate > 0, "compute_tc_offset: stored_rate must be positive")
    assert(type(candidate_value) == "number", "compute_tc_offset: candidate_value required")
    assert(type(candidate_rate) == "number" and candidate_rate > 0, "compute_tc_offset: candidate_rate must be positive")

    -- Rescale candidate to stored_rate for comparison.
    -- TODO(relink): rational-rate rounding. Converting via integer frames at
    -- NTSC fractional pairs (e.g. 23.976 vs 24, 29.97 vs 30) introduces ±1
    -- frame drift over long durations. The caller's `math.abs(offset) > 1`
    -- tolerance in find_candidates_for_media absorbs this in practice, but a
    -- proper fix would use the Rational library directly instead of going
    -- through math.floor. Flag if users report off-by-one TC mismatches at
    -- rational rates. Tracked in TODO.md under "Still Open".
    local candidate_rescaled
    if stored_rate == candidate_rate then
        candidate_rescaled = candidate_value
    else
        -- Convert via seconds: candidate_seconds = candidate_value / candidate_rate
        -- Then: candidate_at_stored_rate = candidate_seconds * stored_rate
        candidate_rescaled = math.floor(candidate_value * stored_rate / candidate_rate + 0.5)
    end

    return candidate_rescaled - stored_value
end

--- Check if a candidate file's TC range contains a clip's absolute source range.
-- Pure arithmetic — no I/O. Used after per-media matching to verify trimmed candidates.
-- @param clip table {source_in, source_out, fps_num, fps_den}
-- @param probe_result table {start_tc_value, start_tc_rate, duration_frames, fps_num, fps_den}
-- @param stored_rate number The media's stored TC rate (for rescaling)
-- @param tc_remap_offset number|nil Optional offset to remap source coordinates to file TC space.
--   When a Set Timecode override exists, source_in is in override TC space but
--   the candidate file is in file TC space. Pass (file_original_timecode - start_tc_value)
--   to remap. Nil = no remap (camera footage).
-- @return boolean True if candidate range fully contains the source extent
-- Pick the candidate's TC (value, rate) for matcher comparisons. Returns the
-- V pair when the probed file has a video stream with TC; otherwise the A
-- pair (sample TC at sample rate) for audio-only files. nil,nil when neither
-- is present. This mirrors media_relink_dialog's media_start_tc selection so
-- both sides of the comparison live in the same TC space — sample TC for
-- audio-only, video TC for V/V+A.
local function probe_candidate_tc(probe_result)
    if not probe_result then return nil, nil end
    if probe_result.start_tc_value and probe_result.start_tc_rate then
        return probe_result.start_tc_value, probe_result.start_tc_rate
    end
    if probe_result.start_tc_audio_samples and probe_result.start_tc_audio_rate then
        return probe_result.start_tc_audio_samples, probe_result.start_tc_audio_rate
    end
    return nil, nil
end

-- Project a probe's duration into stored_rate frame units. When the
-- probe's native rate matches stored_rate (or rate info is absent), the
-- duration passes through. Otherwise rescale by (stored / probe). Every
-- matcher comparison happens in stored_rate units, so all four callsites
-- need this rescaling; centralizing it keeps the rounding policy
-- consistent.
local function probe_duration_in_stored_rate(probe_result, stored_rate)
    local dur = probe_result.duration_frames
    if not (probe_result.fps_num and probe_result.fps_den) then return dur end
    local probe_rate = probe_result.fps_num / probe_result.fps_den
    if math.abs(probe_rate - stored_rate) <= 0.01 then return dur end
    return math.floor(dur * stored_rate
        * probe_result.fps_den / probe_result.fps_num + 0.5)
end

function M.check_extent_containment(extent_start, extent_end, probe_result, stored_rate, tc_remap_offset)
    assert(extent_start and extent_end, "check_extent_containment: extent_start and extent_end required")
    assert(type(probe_result) == "table", "check_extent_containment: probe_result required")
    assert(type(stored_rate) == "number" and stored_rate > 0,
        "check_extent_containment: stored_rate must be positive")

    local cand_tc_value, cand_tc_rate = probe_candidate_tc(probe_result)
    if not cand_tc_value or not cand_tc_rate then
        -- Files without embedded TC have origin 00:00:00:00 — the decoder
        -- computes file_pos = source_in - file_tc_origin with origin 0 for
        -- TC-less files, so containment is evaluated against [0, duration).
        cand_tc_value, cand_tc_rate = 0, stored_rate
    end
    if not probe_result.duration_frames then
        return false
    end

    -- Remap source extent to file TC space if override offset is provided.
    local abs_start = extent_start + (tc_remap_offset or 0)
    local abs_end = extent_end + (tc_remap_offset or 0)

    -- Candidate range at stored_rate
    local cand_start = cand_tc_value
    if stored_rate ~= cand_tc_rate then
        cand_start = math.floor(cand_tc_value * stored_rate / cand_tc_rate + 0.5)
    end

    local cand_end = cand_start + probe_duration_in_stored_rate(probe_result, stored_rate)

    return abs_start >= cand_start and abs_end <= cand_end
end

-- Clip-shaped adapter over check_extent_containment: unpacks source_in/source_out.
function M.check_clip_containment(clip, probe_result, stored_rate, tc_remap_offset)
    return M.check_extent_containment(
        clip.source_in, clip.source_out, probe_result, stored_rate, tc_remap_offset)
end

--- Check if a candidate filename is a segment variant of an original filename.
-- Segments have a numeric suffix after an underscore (e.g., _001, _002).
-- Case-insensitive. Extensions must match.
-- @param original_basename string Original filename (e.g., "A026_C007.mov")
-- @param candidate_basename string Candidate filename (e.g., "A026_C007_001.mov")
-- @return boolean True if candidate is a segment of original
function M.match_segment_filename(original_basename, candidate_basename)
    assert(type(original_basename) == "string", "match_segment_filename: original_basename required")
    assert(type(candidate_basename) == "string", "match_segment_filename: candidate_basename required")

    local orig_lower = original_basename:lower()
    local cand_lower = candidate_basename:lower()

    -- Must not be exact match (segments have suffixes)
    if orig_lower == cand_lower then
        return false
    end

    -- Split into name and extension
    local orig_name, orig_ext = orig_lower:match("^(.+)%.([^%.]+)$")
    local cand_name, cand_ext = cand_lower:match("^(.+)%.([^%.]+)$")

    if not orig_name or not cand_name then return false end
    if orig_ext ~= cand_ext then return false end

    -- Candidate name must be original name + underscore + digits
    local expected_prefix = orig_name .. "_"
    if cand_name:sub(1, #expected_prefix) ~= expected_prefix then
        return false
    end

    local suffix = cand_name:sub(#expected_prefix + 1)
    -- Suffix must be all digits (at least one)
    if not suffix:match("^%d+$") then
        return false
    end

    return true
end

--- Build a segment index from a candidate index.
-- Groups segment files under their original basename.
-- @param candidate_index table {basename_lower → [paths]}
-- @return table {original_basename → [segment_paths]}
function M.build_segment_index(candidate_index)
    assert(type(candidate_index) == "table", "build_segment_index: candidate_index required")

    local seg_index = {}

    -- O(n): parse each basename, strip _NNN suffix, hash-lookup the original
    for cand_basename, cand_paths in pairs(candidate_index) do
        local name, ext = cand_basename:match("^(.+)%.([^%.]+)$")
        if name then
            local base = name:match("^(.+)_%d+$")
            if base then
                local orig_key = base .. "." .. ext
                if candidate_index[orig_key] then
                    seg_index[orig_key] = seg_index[orig_key] or {}
                    local bucket = seg_index[orig_key]
                    for _, path in ipairs(cand_paths) do
                        bucket[#bucket + 1] = path
                    end
                end
            end
        end
    end

    return seg_index
end

--- Find candidate files for a media record based on matching rules.
-- Pure function: uses injectable probe function instead of real ffprobe.
-- Media-level matching only — containment (clip-level) is done by caller.
-- When TC mismatches and accept_trimmed_media is on, candidates are returned
-- with tc_mismatch=true so the caller can run per-clip containment checks.
-- @param media_info table {media_path, media_name, media_start_tc_value, media_start_tc_rate, width, height}
-- @param candidate_index table {basename_lower → [paths]}
-- @param matching_rules table Matching criteria
-- @param probe_fn function(path) → {start_tc_value, start_tc_rate, width, height, fps_num, fps_den, duration_frames} or nil
-- @return table Array of {path, start_tc_value, start_tc_rate, probe_result, tc_mismatch}
-- Build the initial set of candidate paths to consider. With
-- match_filename enabled we narrow to paths whose basename matches the
-- media's basename; without it every indexed path is in scope.
local function collect_paths_to_check(candidate_index, matching_rules, media_path)
    local paths = {}
    if matching_rules.match_filename then
        local basename = get_filename(media_path)
        local lookup_key = basename and basename:lower() or nil
        if lookup_key and candidate_index[lookup_key] then
            for _, p in ipairs(candidate_index[lookup_key]) do
                paths[#paths + 1] = p
            end
        end
    else
        for _, list in pairs(candidate_index) do
            for _, p in ipairs(list) do
                paths[#paths + 1] = p
            end
        end
    end
    return paths
end

-- Format frames-at-rate as HH:MM:SS:FF for failure diagnostics. Rate is
-- the TC pair's own rate: video fps for V/V+A files, sample rate for
-- audio-only TC (FF then counts samples within the second).
local function format_tc(value, rate)
    return frame_utils.format_timecode(value, rate)
end

local function format_fps(num, den)
    if den == 1 then return tostring(num) end
    return string.format("%.3f", num / den)
end

-- One user-readable line for "the file is there but its TC is wrong".
-- Both sides render as HH:MM:SS:FF, each at its own rate.
local function tc_mismatch_reason(cand_path, cand_tc_value, cand_tc_rate,
                                  stored_value, stored_rate)
    return string.format("found %s: timecode %s does not match stored %s",
        get_filename(cand_path),
        format_tc(cand_tc_value, cand_tc_rate),
        format_tc(stored_value, stored_rate))
end

-- TC-matching pass for one candidate. Returns
--   passed         — whether this candidate survives the TC criterion
--   tc_value, rate — candidate's container TC (when probed)
--   tc_mismatch    — true when accepted only via the trimmed-media
--                    containment fallback (FR-008/FR-009)
--   probe_result   — cached probe (passed back so the caller doesn't
--                    re-probe in the next pass)
--   reason         — user-readable rejection reason (only when not passed)
--   relinkable_if_trimmed — true when the ONLY thing blocking this candidate
--                    is that accept_trimmed_media is off (a TC-shifted trim
--                    that would be accepted if the rule were enabled)
local function check_candidate_tc(cand_path, media_info, matching_rules, probe_fn)
    if not matching_rules.match_timecode then
        return true, nil, nil, false, nil
    end
    local stored_value = media_info.media_start_tc_value
    local stored_rate  = media_info.media_start_tc_rate
    if not (stored_value and stored_rate) then
        log.detail("  %s: no stored TC — accepting on non-TC criteria",
            get_filename(cand_path))
        return true, nil, nil, false, nil
    end

    local probe_result = probe_fn(cand_path)
    local cand_tc_value, cand_tc_rate = probe_candidate_tc(probe_result)

    if not (cand_tc_value and cand_tc_rate) then
        log.detail("  %s: no candidate TC — accepting on non-TC criteria",
            get_filename(cand_path))
        return true, cand_tc_value, cand_tc_rate, false, probe_result
    end

    local offset = M.compute_tc_offset(stored_value, stored_rate, cand_tc_value, cand_tc_rate)
    if math.abs(offset) <= 1 then
        return true, cand_tc_value, cand_tc_rate, false, probe_result
    end

    local reason = tc_mismatch_reason(
        cand_path, cand_tc_value, cand_tc_rate, stored_value, stored_rate)

    -- Primary TC mismatch — check file_original_timecode (FR-008).
    local file_orig_tc = media_info.media_file_original_tc
    if file_orig_tc then
        local orig_offset = M.compute_tc_offset(
            file_orig_tc, stored_rate, cand_tc_value, cand_tc_rate)
        if math.abs(orig_offset) <= 1 then
            -- FR-009: clean accept (no containment fallback needed).
            log.event("  %s: TC matches file_original_timecode (offset=%.1f)",
                get_filename(cand_path), orig_offset)
            return true, cand_tc_value, cand_tc_rate, false, probe_result
        end
        if matching_rules.accept_trimmed_media then
            return true, cand_tc_value, cand_tc_rate, true, probe_result
        end
        -- Rejected ONLY because accept_trimmed_media is off — flag it so the
        -- summary can offer "enable Accept Trimmed Media to relink these".
        return false, cand_tc_value, cand_tc_rate, false, probe_result, reason, true
    end
    -- No file_original_tc → existing trimmed-media containment fallback.
    if matching_rules.accept_trimmed_media then
        return true, cand_tc_value, cand_tc_rate, true, probe_result
    end
    return false, cand_tc_value, cand_tc_rate, false, probe_result, reason, true
end

-- Resolution + frame-rate pass. probe_result is reused when the TC pass
-- already loaded it. Returns (passed, probe_result, reason) — reason is
-- the user-readable rejection line, only when not passed.
local function check_candidate_resolution_fps(cand_path, media_info, matching_rules,
                                               probe_fn, probe_result)
    if not (matching_rules.match_resolution or matching_rules.match_frame_rate) then
        return true, probe_result
    end
    probe_result = probe_result or probe_fn(cand_path)
    if not probe_result then return true, probe_result end
    if matching_rules.match_resolution then
        if probe_result.width ~= media_info.width
            or probe_result.height ~= media_info.height then
            return false, probe_result, string.format(
                "found %s: resolution %sx%s does not match stored %sx%s",
                get_filename(cand_path),
                tostring(probe_result.width), tostring(probe_result.height),
                tostring(media_info.width), tostring(media_info.height))
        end
    end
    if matching_rules.match_frame_rate
        and probe_result.fps_num and probe_result.fps_den then
        assert(media_info.fps_num and media_info.fps_den, string.format(
            "check_candidate_resolution_fps: match_frame_rate requires "
            .. "media_info.fps_num/fps_den for %s", media_info.media_path))
        if probe_result.fps_num ~= media_info.fps_num
            or probe_result.fps_den ~= media_info.fps_den then
            return false, probe_result, string.format(
                "found %s: frame rate %s does not match stored %s fps",
                get_filename(cand_path),
                format_fps(probe_result.fps_num, probe_result.fps_den),
                format_fps(media_info.fps_num, media_info.fps_den))
        end
    end
    return true, probe_result
end

-- Returns (candidates, rejected): candidates are the paths that passed
-- every enabled rule; rejected records each name-matched path a rule
-- turned down, as {path, reason} with the concrete mismatch — fuel for
-- the per-media failure diagnostics (a silently vanishing candidate is
-- indistinguishable from "file not found" to the user).
function M.find_candidates_for_media(media_info, candidate_index, matching_rules, probe_fn)
    assert(type(media_info) == "table", "find_candidates_for_media: media_info required")
    assert(type(candidate_index) == "table", "find_candidates_for_media: candidate_index required")
    assert(type(matching_rules) == "table", "find_candidates_for_media: matching_rules required")

    local results, rejected = {}, {}
    local paths_to_check = collect_paths_to_check(
        candidate_index, matching_rules, media_info.media_path)

    for _, cand_path in ipairs(paths_to_check) do
        local passed, cand_tc_value, cand_tc_rate, tc_mismatch, probe_result, reason,
              relinkable_if_trimmed =
            check_candidate_tc(cand_path, media_info, matching_rules, probe_fn)
        if passed then
            passed, probe_result, reason = check_candidate_resolution_fps(
                cand_path, media_info, matching_rules, probe_fn, probe_result)
        end
        if passed then
            results[#results + 1] = {
                path           = cand_path,
                start_tc_value = cand_tc_value,
                start_tc_rate  = cand_tc_rate,
                probe_result   = probe_result,
                tc_mismatch    = tc_mismatch,
            }
        else
            assert(reason, string.format(
                "find_candidates_for_media: rejection without a reason for %s "
                .. "— every reject path must explain itself", cand_path))
            rejected[#rejected + 1] = {
                path = cand_path,
                reason = reason,
                relinkable_if_trimmed = relinkable_if_trimmed,
            }
        end
    end
    return results, rejected
end

-- =============================================================================
-- Batch dispatch: fan out per-media matching + classification
-- =============================================================================

-- Delta between the media's displayed start-TC and the file's container
-- TC — populated only when the user has applied a Set Timecode override.
-- find_candidates_for_media already applies this when comparing TC; we
-- re-apply it here during containment checks.
local function compute_tc_remap_offset(media_info)
    local orig = media_info.media_file_original_tc
    local displayed = media_info.media_start_tc_value
    if not orig or not displayed then return nil end
    local delta = orig - displayed
    if delta == 0 then return nil end
    return delta
end

-- When a media file has no embedded TC anchor (no bext time_reference,
-- no tmcd) AND its candidate has none either, the trim's origin can't
-- be read from the file. The only signal is the project's own usage:
-- if the candidate is at least as long as the clips' used span but
-- can't cover the used range from origin 0, infer that the trim's
-- origin is min(source_in) = extent_start — exactly enough head was
-- cut to put the earliest used frame at file 0. The existing origin-0
-- convention is the degenerate case of this rule (used range starts at
-- 0); the inference is the general form.
--
-- Strictly additive: returns nil unless origin 0 fails AND the used
-- span fits. Risk (user trimmed past project usage → wrong content) is
-- intrinsic to TC-less media; Joe acknowledged + accepted 2026-06-21.
-- Returns (inferred_value, inferred_rate) on success.
local function infer_no_tc_anchor(media_info, probe_result, stored_rate)
    if not (probe_result and probe_result.duration_frames and stored_rate) then
        return nil
    end
    -- start_tc_value=0 is the DRP "TC-less render" sentinel. >0 is a
    -- real anchor we must not override. Note the latent ambiguity:
    -- footage genuinely shot at TC 00:00:00:00 looks identical to the
    -- sentinel — both arrive as 0 here. The matcher has no field to
    -- distinguish them, so a Resolve-trimmed midnight-TC clip would
    -- (incorrectly) take the inference path. No reports of this in
    -- practice; tracked as a known edge case if it surfaces.
    local stored_value = media_info.media_start_tc_value
    if stored_value and stored_value > 0 then return nil end
    -- Candidate carrying TC (V or audio) is authoritative — the
    -- existing TC-clean / trimmed-media branches downstream handle it.
    if probe_candidate_tc(probe_result) then return nil end

    local s = media_info.source_extent_start
    local e = media_info.source_extent_end
    if not (s and e) then return nil end

    local dur = probe_duration_in_stored_rate(probe_result, stored_rate)
    if dur >= e then return nil end          -- origin 0 already works
    if dur < (e - s) then return nil end     -- file too short for any anchor

    return s, stored_rate
end

-- Return a copy of `cand` with the inferred TC stamped onto a fresh
-- probe_result. probe_result instances are caller-owned and may be
-- cached across passes — mutating the original would leak. The stamped
-- probe flows through every downstream consumer (check_extent_containment,
-- coverage_for_candidate, probed_tc_for_metadata) so the inferred origin
-- becomes the media_ref's persisted TC. Shallow copy is sufficient
-- because every probe_result field consumers read is scalar; assert it
-- so a future probe schema change that adds a nested table trips here
-- instead of silently aliasing the cache.
local function stamp_inferred_tc(cand, inferred_value, inferred_rate)
    local pr = {}
    for k, v in pairs(cand.probe_result) do
        assert(type(v) ~= "table", string.format(
            "stamp_inferred_tc: probe_result.%s is a table — shallow copy "
            .. "would alias the cached probe; deep-copy this field", k))
        pr[k] = v
    end
    pr.start_tc_value = inferred_value
    pr.start_tc_rate = inferred_rate
    local out = {}
    for k, v in pairs(cand) do out[k] = v end
    out.probe_result = pr
    return out
end

-- Partition candidates into full-extent matches and TC-offset trimmed-fit
-- candidates. Rules:
--   * A candidate without tc_mismatch (or without stored_rate context) is
--     treated as a full match and goes into `viable`.
--   * A tc_mismatch whose probe range covers the full source_extent also
--     goes into `viable` — extent-containment wins over the TC flag.
--   * A tc_mismatch that fails extent but starts at/after the original
--     file's TC and within a plausible trim window is a partial_fit
--     candidate (tried lazily against per-clip ranges).
--   * A tc_mismatch that fails both is dropped — recorded in the third
--     return value as {path, reason} so the failure diagnostics can tell
--     the user the file WAS found and why it didn't qualify.
--   * TC-less candidates whose project-side usage indicates a trimmed
--     interior region get an inferred TC anchor up front (see
--     infer_no_tc_anchor) before the above rules run.
local function partition_candidates(media_info, candidates, stored_rate, tc_remap_offset)
    local viable, partial_fit, dropped = {}, {}, {}

    -- Decide whether this candidate's probed extent contains the media's
    -- full source range. Returns true only when both the extent fields
    -- and the probe carry enough info to make the call; absence of either
    -- means "can't tell" and the candidate is treated as viable per the
    -- pre-extent legacy behavior.
    local function extent_known_insufficient(cand)
        if not (media_info.source_extent_start
            and media_info.source_extent_end
            and cand.probe_result) then
            return false
        end
        return not M.check_extent_containment(
            media_info.source_extent_start, media_info.source_extent_end,
            cand.probe_result, stored_rate, tc_remap_offset)
    end

    for _, cand in ipairs(candidates) do
        -- No-TC anchor inference: a TC-less candidate whose project-side
        -- usage points to an interior trim gets its TC stamped before
        -- containment runs, so the rest of the pipeline sees the anchor
        -- uniformly. infer_no_tc_anchor returns nil when origin 0 already
        -- works, leaving the cand unchanged.
        local iv, ir = infer_no_tc_anchor(media_info, cand.probe_result, stored_rate)
        if iv then
            log.event("  %s: no-TC anchor inferred at %d @%s "
                .. "(file dur < extent_end, fits used span)",
                get_filename(cand.path), iv, tostring(ir))
            cand = stamp_inferred_tc(cand, iv, ir)
        end

        if not (cand.tc_mismatch and stored_rate) then
            -- TC-clean candidate. Even a 1-frame extent shortfall must
            -- demote it to partial_fit so try_partial_fit / partial_coverage
            -- can attach the offline_note that surfaces the deficit. Skipping
            -- the extent check here was the bug: TC-matching candidates that
            -- didn't have enough frames for the clip's source range slipped
            -- through as a clean relink, and clips short of coverage rendered
            -- "File not found" against the now-stale-but-untouched original
            -- path with no diagnostic.
            if extent_known_insufficient(cand) then
                partial_fit[#partial_fit + 1] = cand
            else
                viable[#viable + 1] = cand
            end
        elseif media_info.source_extent_start and media_info.source_extent_end
            and cand.probe_result
            and M.check_extent_containment(
                media_info.source_extent_start, media_info.source_extent_end,
                cand.probe_result, stored_rate, tc_remap_offset) then
            viable[#viable + 1] = cand
        elseif cand.probe_result then
            local ref_tc = media_info.media_file_original_tc
                or media_info.media_start_tc_value
            local cand_tc_value, cand_tc_rate = probe_candidate_tc(cand.probe_result)
            if ref_tc and cand_tc_value then
                local cand_tc = cand_tc_value
                if cand_tc_rate ~= stored_rate then
                    cand_tc = math.floor(cand_tc * stored_rate
                        / cand_tc_rate + 0.5)
                end
                local offset = cand_tc - ref_tc
                -- Plausible trim: candidate starts at/after the original file,
                -- within ~24h (reject random unrelated TC space).
                if offset >= 0 and offset < 90000 * 24 then
                    partial_fit[#partial_fit + 1] = cand
                else
                    dropped[#dropped + 1] = {
                        path = cand.path,
                        reason = tc_mismatch_reason(cand.path,
                            cand_tc_value, cand_tc_rate, ref_tc, stored_rate)
                            .. " (not a trim of the original)",
                    }
                end
            else
                -- tc_mismatch implies both stored and candidate TC existed
                -- at the match pass; losing them here is an internal error.
                assert(false, string.format(
                    "partition_candidates: tc_mismatch candidate %s lost its "
                    .. "TC context (ref_tc=%s cand_tc=%s)",
                    cand.path, tostring(ref_tc), tostring(cand_tc_value)))
            end
        end
    end
    return viable, partial_fit, dropped
end

-- Pack the TC fields a Media row's metadata needs to be synced with the
-- newly-linked file. Returns nil when the probe yielded no authoritative TC
-- (plain MP3, non-BWF WAV, etc.) — Media metadata is left untouched in that
-- case so the pre-relink values aren't overwritten with blanks.
local function probed_tc_for_metadata(probe_result)
    if not probe_result then return nil end
    -- Post-normalization: accept V pair OR A pair (or both). Audio-only
    -- files have only the A pair; video-only / V+A with V TC have at
    -- least the V pair. Refuse only when neither is present (plain MP3,
    -- non-BWF WAV, video without tmcd) — nothing to sync into metadata.
    local has_v = probe_result.start_tc_value ~= nil
        and probe_result.start_tc_rate ~= nil
    local has_a = probe_result.start_tc_audio_samples ~= nil
        and probe_result.start_tc_audio_rate ~= nil
    if not has_v and not has_a then return nil end
    return {
        start_tc_value = probe_result.start_tc_value,
        start_tc_rate = probe_result.start_tc_rate,
        start_tc_audio_samples = probe_result.start_tc_audio_samples,
        start_tc_audio_rate = probe_result.start_tc_audio_rate,
    }
end

-- Build a media_duration_updates entry from the probe — the probed
-- file's extent is the source of truth for "how long is the linked
-- file" (the DRP's NumFrames went stale when the file was re-cut on
-- disk). nil when the probe carries no usable duration; the executor
-- then leaves duration_frames alone. duration_frames is in V frames @
-- the probed file's fps; audio_duration_samples is sample count.
local function probed_duration_for_update(probe_result)
    if not probe_result then return nil end
    local v = probe_result.duration_frames
    local a = probe_result.audio_duration_samples
    if not v and not a then return nil end
    return {
        duration_frames = v,
        audio_duration_samples = a,
    }
end

-- Emit a relinked or ambiguous entry for the full-fit case. Single candidate
-- → relinked; multiple → ambiguous (user must pick).
local function classify_viable(out, media_info, viable)
    if #viable == 1 then
        out.relinked[#out.relinked + 1] = {
            media_id = media_info.media_id,
            new_path = viable[1].path,
            strategy = viable[1].is_segment and "segment" or "filename",
            probed_tc = probed_tc_for_metadata(viable[1].probe_result),
            probed_duration = probed_duration_for_update(viable[1].probe_result),
        }
        return
    end
    local cand_info = {}
    for _, c in ipairs(viable) do
        cand_info[#cand_info + 1] = {
            path = c.path,
            start_tc = c.start_tc_value,
            start_tc_rate = c.start_tc_rate,
        }
    end
    out.ambiguous[#out.ambiguous + 1] = {
        media_id = media_info.media_id,
        candidates = cand_info,
    }
end

-- Log why a partial candidate covered zero clips. Purely diagnostic —
-- the caller continues looking at other candidates.
local function log_zero_fit_detail(cand, clips, stored_rate, tc_remap_offset)
    local pr = cand.probe_result
    local cand_tc_value, cand_tc_rate = probe_candidate_tc(pr)
    if not cand_tc_value then
        -- TC-less candidate: origin 0 (matches the containment math).
        cand_tc_value, cand_tc_rate = 0, stored_rate
    end
    -- Duration can be genuinely absent on probes that lacked metadata;
    -- this is a diagnostic-only path, so format "?" rather than fake-zero.
    local cand_start = cand_tc_value
    if stored_rate and cand_tc_rate and cand_tc_rate ~= stored_rate then
        cand_start = math.floor(cand_start * stored_rate / cand_tc_rate + 0.5)
    end
    local cand_start_str = tostring(cand_start)
    local cand_end_str = "?"
    if pr.duration_frames then
        cand_end_str = tostring(cand_start
            + probe_duration_in_stored_rate(pr, stored_rate))
    end
    local c0 = clips[1]
    log.event(
        "  0-clips detail: cand=[%s,%s]@%s remap=%s first_clip=[%d,%d] "
        .. "(%d clips total) file=%s",
        cand_start_str, cand_end_str, tostring(stored_rate),
        tostring(tc_remap_offset),
        c0.source_in, c0.source_out, #clips,
        get_filename(cand.path))
end

-- Rescale clip source range into stored_rate units. Under V13 every
-- `clips` row IS a timeline clip (masters live in `media_refs`), so
-- the V8 "drop master clips" filter is gone.
-- check_clip_containment compares against probe ranges at stored_rate, so
-- audio clips at 48kHz must be down-converted or they look ~1920× too large.
local function normalize_clips_to_stored_rate(raw_clips, stored_rate)
    local out = {}
    for _, clip in ipairs(raw_clips) do
        local clip_rate = clip.fps_num / (clip.fps_den or 1)
        local src_in, src_out = clip.source_in, clip.source_out
        if clip_rate > 0 and math.abs(clip_rate - stored_rate) > 0.01 then
            src_in = math.floor(src_in * stored_rate / clip_rate + 0.5)
            src_out = math.floor(src_out * stored_rate / clip_rate + 0.5)
        end
        out[#out + 1] = {
            clip_id = clip.clip_id,
            source_in = src_in,
            source_out = src_out,
        }
    end
    return out
end

-- Compute the {covered_start_tc, covered_end_tc} pair for one candidate,
-- in the media's stored_rate frame units. Returns nil when the candidate
-- doesn't carry enough probe info to describe coverage.
local function coverage_for_candidate(cand, stored_rate)
    if not stored_rate then return nil end
    local pr = cand.probe_result
    if not (pr and pr.duration_frames) then return nil end

    local dur = probe_duration_in_stored_rate(pr, stored_rate)

    local cov_value, cov_rate = probe_candidate_tc(pr)
    if not cov_value then
        -- TC-less candidate: anchored at origin 00:00:00:00, same
        -- convention as check_extent_containment / the decoder.
        cov_value, cov_rate = 0, stored_rate
    end
    local cov_start = cov_value
    if cov_rate and cov_rate ~= stored_rate then
        cov_start = math.floor(cov_start * stored_rate / cov_rate + 0.5)
    end
    return {
        kind = "partial_coverage",
        candidate_path = cand.path,
        covered_start_tc = cov_start,
        covered_end_tc = cov_start + dur,
        rate = stored_rate,
    }, dur
end

-- Compute the partial_coverage note for the widest partial candidate — the
-- candidate carrying the most frames wins; its covered TC range drives the
-- per-clip shortfall diagnostic downstream.
local function compute_partial_coverage(partial_fit, stored_rate)
    if not stored_rate or #partial_fit == 0 then return nil end
    local best, best_dur, best_cov = nil, -1, nil
    for _, c in ipairs(partial_fit) do
        local cov, dur = coverage_for_candidate(c, stored_rate)
        if cov and dur > best_dur then
            best, best_dur, best_cov = c, dur, cov
        end
    end
    if not best then return nil end
    return {
        candidate_path = best.path,
        probe_result = best.probe_result,
        coverage = best_cov,
    }
end

-- Derive the failure classification for a media nothing relinked.
-- Returns (kind, reason):
--   kind = "not_found" — no file with the media's basename anywhere in
--          the search tree; the user needs to locate the file.
--   kind = "rejected"  — name-matched file(s) exist but every one was
--          turned down; reason concatenates the per-candidate mismatches
--          so the user can fix rules or accept the file is different.
local function failure_reason(candidates, rejected, dropped, partial_fit)
    local notes = {}
    for _, r in ipairs(rejected) do notes[#notes + 1] = r.reason end
    for _, d in ipairs(dropped) do notes[#notes + 1] = d.reason end
    for _, c in ipairs(partial_fit) do
        -- Reaching failure with a partial_fit candidate means neither the
        -- split nor the coverage promotion could use it — with TC-less
        -- candidates anchored at origin 0, the only remaining cause is a
        -- probe that yielded no usable duration.
        notes[#notes + 1] = string.format(
            "found %s: file duration unreadable", get_filename(c.path))
    end
    if #notes == 0 then
        assert(#candidates == 0, string.format(
            "failure_reason: %d candidate(s) failed without any recorded "
            .. "rejection — a reject path is silently dropping candidates",
            #candidates))
        return "not_found", "no file with this name in search folder"
    end
    return "rejected", table.concat(notes, "; ")
end

--- Classify a media into relinked/failed/ambiguous/split based on candidates.
-- Media-level: uses source_extent for containment, not per-clip iteration.
-- When extent containment fails but some individual clips fit (partial-fit),
-- produces a needs_split entry with the fitting clip_ids.
-- @param media_info table Media info with source_extent_start/end
-- @param candidates table Array from find_candidates_for_media
-- @param clip_loader function(media_id) → array of {clip_id, source_in, source_out, fps_num, fps_den}
-- @return table {relinked = [...], failed = [...], ambiguous = [...]}
-- Try the per-clip-containment "partial fit" strategy. Returns true and
-- populates `out.relinked` when at least one clip fits a candidate;
-- false (caller falls through to the partial-coverage / failure paths)
-- otherwise. Lazy-loads the media's clip list via `clip_loader` (callers
-- skip this path when no loader is available).
local function try_partial_fit_relink(out, media_info, partial_fit_candidates,
                                      clip_loader, stored_rate, tc_remap_offset)
    if #partial_fit_candidates == 0 or not clip_loader then return false end
    local raw_clips = clip_loader(media_info.media_id)
    if not (raw_clips and #raw_clips > 0) then return false end
    local clips = normalize_clips_to_stored_rate(raw_clips, stored_rate)

    -- Pick the candidate that covers the largest subset of clips.
    local best_cand, best_fits, best_count = nil, nil, 0
    for _, cand in ipairs(partial_fit_candidates) do
        if cand.probe_result then
            local fits = {}
            for _, clip in ipairs(clips) do
                if M.check_clip_containment(clip, cand.probe_result, stored_rate, tc_remap_offset) then
                    fits[#fits + 1] = clip.clip_id
                end
            end
            if #fits == 0 and #clips > 0 then
                log_zero_fit_detail(cand, clips, stored_rate, tc_remap_offset)
            end
            if #fits > best_count then
                best_cand, best_fits, best_count = cand, fits, #fits
            end
        end
    end
    if best_count == 0 then return false end

    if best_count == #clips then
        -- All clips fit — the extent check was overly conservative
        -- (usually rate-conversion rounding). Treat as a full relink.
        out.relinked[#out.relinked + 1] = {
            media_id = media_info.media_id,
            new_path = best_cand.path,
            strategy = best_cand.is_segment and "segment" or "filename",
            probed_tc = probed_tc_for_metadata(best_cand.probe_result),
            probed_duration = probed_duration_for_update(best_cand.probe_result),
        }
    else
        -- Split: the fitting clips will retarget to a clone of media at
        -- best_cand's path. The non-fitting clips stay on the ORIGINAL
        -- media row, which we annotate with a partial_coverage note so
        -- the source viewer can render "Found <candidate>, missing Xf"
        -- instead of the misleading "File not found" against the now-
        -- stale original path. Coverage describes best_cand specifically
        -- (the file the fitting clips relink to) so the diagnostic
        -- references the same file the user can see is online for the
        -- adjacent clips.
        out.relinked[#out.relinked + 1] = {
            media_id      = media_info.media_id,
            new_path      = best_cand.path,
            strategy      = best_cand.is_segment and "segment" or "filename",
            needs_split   = true,
            split_clip_ids = best_fits,
            probed_tc     = probed_tc_for_metadata(best_cand.probe_result),
            coverage      = coverage_for_candidate(best_cand, stored_rate),
        }
        log.event("  partial fit: %d/%d clips fit in %s → needs split",
            best_count, #clips, get_filename(best_cand.path))
    end
    return true
end

-- Try the partial-coverage strategy. The user's intent is "this file is
-- clearly my media — just missing a few frames at the boundaries."
-- Promote the best partial candidate so media.file_path points at the
-- real (short) file; clips whose source range fits within coverage
-- render online, clips extending past it render offline with a
-- shortfall note. Shift+F, playback for covered frames, and probing
-- all work against the real file; boundary frames produce offline
-- output per C++ TMB EOF handling.
local function try_partial_coverage_relink(out, media_info, partial_fit_candidates, stored_rate)
    local pc = compute_partial_coverage(partial_fit_candidates, stored_rate)
    if not pc then return false end
    log.event("  PARTIAL: %s → %s (covers %d..%d @%d)",
        media_info.media_name, get_filename(pc.candidate_path),
        pc.coverage.covered_start_tc, pc.coverage.covered_end_tc,
        pc.coverage.rate)
    out.relinked[#out.relinked + 1] = {
        media_id  = media_info.media_id,
        new_path  = pc.candidate_path,
        strategy  = "partial_coverage",
        coverage  = pc.coverage,
        probed_tc = probed_tc_for_metadata(pc.probe_result),
        -- Update duration to match the (shorter) candidate. Clips that
        -- reference frames past the new file's end fall into C++ TMB
        -- EOF handling; the offline_note encodes the missing range.
        probed_duration = probed_duration_for_update(pc.probe_result),
    }
    return true
end

-- rejected: {path, reason} entries from find_candidates_for_media for
-- name-matched files the match rules turned down. nil = none (tests
-- exercising classification in isolation).
local function classify_media(media_info, candidates, clip_loader, rejected)
    local stored_rate = media_info.media_start_tc_rate
    local tc_remap_offset = compute_tc_remap_offset(media_info)
    local out = { relinked = {}, failed = {}, ambiguous = {} }

    local viable, partial_fit_candidates, dropped =
        partition_candidates(media_info, candidates, stored_rate, tc_remap_offset)

    if #viable > 0 then
        classify_viable(out, media_info, viable)
        return out
    end

    if try_partial_fit_relink(out, media_info, partial_fit_candidates,
                              clip_loader, stored_rate, tc_remap_offset) then
        return out
    end

    if try_partial_coverage_relink(out, media_info, partial_fit_candidates, stored_rate) then
        return out
    end

    local kind, reason = failure_reason(
        candidates, rejected or {}, dropped, partial_fit_candidates)
    log.event("  FAILED: %s — %s", media_info.media_name, reason)

    -- A name-matched candidate rejected ONLY because accept_trimmed_media is off
    -- means enabling that rule would relink this media. Surface it so the summary
    -- can prompt the user.
    local relinkable_if_trimmed = false
    for _, r in ipairs(rejected or {}) do
        if r.relinkable_if_trimmed then relinkable_if_trimmed = true break end
    end

    out.failed[#out.failed + 1] = {
        media_id = media_info.media_id,
        kind = kind,
        reason = reason,
        relinkable_if_trimmed = relinkable_if_trimmed,
    }
    return out
end

--- Merge one media's classification outputs into the batch accumulator.
local function merge_media_results(accumulator, media_results)
    for _, r in ipairs(media_results.relinked) do
        accumulator.relinked[#accumulator.relinked + 1] = r
    end
    for _, f in ipairs(media_results.failed) do
        accumulator.failed[#accumulator.failed + 1] = f
    end
    for _, a in ipairs(media_results.ambiguous) do
        accumulator.ambiguous[#accumulator.ambiguous + 1] = a
    end
end

--- Append segment-file candidates to an existing candidates array.
-- Segment files are numeric-suffixed variants of the original basename.
-- Mutates `candidates` in place. No-op if segment_index has no entry for this media.
local function inject_segment_candidates(media_info, candidates, segment_index, probe_fn)
    local basename = get_filename(media_info.media_path)
    local seg_key = basename and basename:lower() or nil
    if not seg_key or not segment_index[seg_key] then return end

    local seen = {}
    for _, c in ipairs(candidates) do seen[c.path] = true end

    for _, seg_path in ipairs(segment_index[seg_key]) do
        if not seen[seg_path] then
            seen[seg_path] = true
            local seg_probe = probe_fn(seg_path)
            candidates[#candidates + 1] = {
                path = seg_path,
                start_tc_value = seg_probe and seg_probe.start_tc_value,
                start_tc_rate = seg_probe and seg_probe.start_tc_rate,
                probe_result = seg_probe,
                is_segment = true,
            }
        end
    end
end

--- Report progress for one processed media to the caller's progress_cb.
-- Emits one log line per clip outcome so the user can see what happened:
--   [OK]    clip → file            (relinked)
--- Batch relink media to candidate files using matching rules.
-- Matches per-media (not per-clip). Output is per-media, not per-clip.
-- @param media_infos table Array of media_info structs with source_extent_start/end
-- @param options table {search_paths, matching_rules}
-- @param progress_cb function|nil progress_cb(pct, status, log_line)
-- @return table {relinked, failed, ambiguous, new_media}
-- Build the set of candidate paths to pre-probe. With match_filename
-- enabled we narrow to paths whose basename appears in the batch; without
-- it every candidate is potentially relevant. Returns a deduplicated list.
local function collect_paths_to_preprobe(media_infos, candidate_index, matching_rules)
    local paths_to_preprobe = {}
    local seen = {}
    if matching_rules.match_filename then
        for _, media_info in ipairs(media_infos) do
            local basename = get_filename(media_info.media_path)
            local key = basename and basename:lower() or nil
            if key and candidate_index[key] then
                for _, path in ipairs(candidate_index[key]) do
                    if not seen[path] then
                        seen[path] = true
                        paths_to_preprobe[#paths_to_preprobe + 1] = path
                    end
                end
            end
        end
    else
        for _, bucket in pairs(candidate_index) do
            for _, path in ipairs(bucket) do
                if not seen[path] then
                    seen[path] = true
                    paths_to_preprobe[#paths_to_preprobe + 1] = path
                end
            end
        end
    end
    return paths_to_preprobe
end

-- Pre-probe candidates in parallel. Serial single-shot probes were the
-- dominant cost (72.5 ms × 562 calls = 40s observed). MEDIA_PROBE_BATCH
-- dispatches hardware_concurrency workers through
-- emp::MediaFile::ProbeMetadata, each of which skips
-- avformat_find_stream_info (~5× faster per probe). Combined expectation:
-- ~40s → ~1s on 8-core hardware.
--
-- The native bindings (EMP.MEDIA_PROBE_BATCH + qt_file_stat_batch) are
-- editor-only. Under plain luajit tests they are absent and we let
-- per-candidate cached_probe fall through to probe_file_ffprobe during
-- the match loop. Same correctness, slower wall clock — fine for tests.
--
-- Probe every filename-matched candidate up front, as if all probe-consuming
-- rules (timecode/resolution/frame rate) were enabled. The relink dialog lets
-- the user toggle those rules and re-classify live; pre-probing here means a
-- toggle never triggers a probe pause — classification reads only cached
-- results. Under plain luajit (no EMP batch bindings) this is a no-op and the
-- cached_probe closure probes lazily during classification, same as before.
local function prefetch_all_probes(probe_cache, media_infos, candidate_index, progress_cb)
    local paths_to_preprobe = collect_paths_to_preprobe(
        media_infos, candidate_index, { match_filename = true })

    local EMP = qt_constants and qt_constants.EMP
    local bindings_ready = EMP and EMP.MEDIA_PROBE_BATCH
        and rawget(_G, "qt_file_stat_batch") ~= nil
    if not (bindings_ready and #paths_to_preprobe > 0) then return end

    if progress_cb then
        progress_cb(10, string.format("Probing %d candidate(s)...", #paths_to_preprobe))
    end
    local n, dt = preprobe_batch(probe_cache, paths_to_preprobe)
    log.event("scan_candidates: pre-probed %d candidates in parallel in %.2fs "
        .. "(%.1f ms/probe effective)", n, dt, n > 0 and (dt * 1000 / n) or 0)
end

--- Scan the search tree ONCE and pre-probe candidates, returning a reusable
--- context for classify_batch. The scan + probe is the expensive part and is
--- independent of the matching rules; separating it lets the relink dialog
--- re-classify instantly when the user toggles a rule (no rescan, no reprobe).
-- @param media_infos table Array of media_info structs (need .media_path)
-- @param search_paths table Non-empty array of directories to scan
-- @param progress_cb function|nil progress_cb(pct, status)
-- @return table context {candidate_index, segment_index, probe_cache,
--   cached_probe, stats} — pass verbatim to classify_batch.
function M.scan_candidates(media_infos, search_paths, progress_cb)
    assert(type(media_infos) == "table", "scan_candidates: media_infos required")
    assert(type(search_paths) == "table" and #search_paths > 0,
        "scan_candidates: search_paths must be a non-empty array")
    for i, mi in ipairs(media_infos) do
        assert(type(mi.media_path) == "string" and mi.media_path ~= "",
            string.format("scan_candidates: media_infos[%d].media_path required", i))
    end

    if progress_cb then progress_cb(0, "Scanning search directory...") end
    local t_scan = qt_monotonic_s()

    local extensions = {}
    for _, media_info in ipairs(media_infos) do
        local ext = media_info.media_path:match("%.([^%.]+)$")
        if ext then extensions[ext:lower()] = true end
    end
    assert(next(extensions) ~= nil,
        "scan_candidates: no media_info has a parseable file extension; cannot scan for candidates")

    local ext_list = {}
    for ext in pairs(extensions) do ext_list[#ext_list + 1] = ext end
    log.detail("scan_candidates: scanning for extensions: %s", table.concat(ext_list, ", "))

    local candidate_index = build_candidate_index(search_paths, extensions)
    local cand_count = 0
    for _, paths in pairs(candidate_index) do cand_count = cand_count + #paths end
    log.event("scan_candidates: scan complete — %d candidate files in %.1fs",
        cand_count, qt_monotonic_s() - t_scan)

    -- Segment index is built unconditionally so toggling Accept Filename
    -- Suffixes re-classifies live without a rescan. Building it is cheap
    -- (numeric-suffix grouping over the already-scanned index).
    local segment_index = M.build_segment_index(candidate_index)

    -- Unified probe cache. cache[path] tri-state:
    --   nil   = not yet probed  (triggers single-shot cached_probe)
    --   false = probed, unsupported / open failed  (cached_probe returns nil)
    --   table = probe_result shape (see probe_result_from_emp_info)
    local probe_cache = {}
    local stats = { probe_count = 0, probe_total_seconds = 0 }

    local function cached_probe(path)
        local cached = probe_cache[path]
        if cached ~= nil then
            return cached ~= false and cached or nil
        end
        stats.probe_count = stats.probe_count + 1
        log.detail("probe[%d]: %s", stats.probe_count, get_filename(path))
        local t_probe = qt_monotonic_s()
        local result = probe_file(path)
        stats.probe_total_seconds = stats.probe_total_seconds + (qt_monotonic_s() - t_probe)
        probe_cache[path] = result or false
        if result then
            log.detail("  → tc=%s@%s res=%sx%s dur=%s",
                tostring(result.start_tc_value), tostring(result.start_tc_rate),
                tostring(result.width), tostring(result.height),
                tostring(result.duration_frames))
        end
        return result
    end

    prefetch_all_probes(probe_cache, media_infos, candidate_index, progress_cb)

    return {
        candidate_index = candidate_index,
        segment_index   = segment_index,
        probe_cache     = probe_cache,
        cached_probe    = cached_probe,
        stats           = stats,
    }
end

--- Classify previously-scanned candidates under a set of matching rules.
--- Pure over the scan context (no filesystem I/O beyond lazy cache misses):
--- safe to re-run on every rule toggle. Returns the same shape as
--- relink_media_batch ({relinked, failed, ambiguous, new_media}).
-- @param media_infos table Array of media_info structs
-- @param context table The value returned by scan_candidates
-- @param matching_rules table Matching criteria
-- @param clip_loader function|nil function(media_id) → array of clip entries
-- @param progress_cb function|nil progress_cb(pct, status)
-- @return table {relinked, failed, ambiguous, new_media}
function M.classify_batch(media_infos, context, matching_rules, clip_loader, progress_cb)
    assert(type(media_infos) == "table", "classify_batch: media_infos required")
    assert(type(context) == "table" and context.candidate_index
        and type(context.cached_probe) == "function",
        "classify_batch: context from scan_candidates required")
    assert(type(matching_rules) == "table", "classify_batch: matching_rules required")

    local results = { relinked = {}, failed = {}, ambiguous = {}, new_media = {} }
    local total_media = #media_infos
    if total_media == 0 then return results end

    local candidate_index = context.candidate_index
    local cached_probe    = context.cached_probe
    local segment_index   = context.segment_index

    log.event("classify_batch: %d media, rules: fn=%s tc=%s res=%s fps=%s trim=%s seg=%s",
        total_media,
        tostring(matching_rules.match_filename), tostring(matching_rules.match_timecode),
        tostring(matching_rules.match_resolution), tostring(matching_rules.match_frame_rate),
        tostring(matching_rules.accept_trimmed_media), tostring(matching_rules.accept_filename_suffixes))

    local t_match = qt_monotonic_s()
    for i, media_info in ipairs(media_infos) do
        log.detail("media %d/%d: %s", i, total_media, media_info.media_name)

        local candidates, rejected = M.find_candidates_for_media(
            media_info, candidate_index, matching_rules, cached_probe)

        log.detail("  → %d candidate(s), %d rejected", #candidates, #rejected)
        for ci, c in ipairs(candidates) do
            log.detail("    [%d] %s (tc=%s@%s%s)", ci, c.path,
                tostring(c.start_tc_value), tostring(c.start_tc_rate),
                c.tc_mismatch and " TC-MISMATCH" or "")
        end

        if matching_rules.accept_filename_suffixes and segment_index then
            inject_segment_candidates(media_info, candidates, segment_index, cached_probe)
        end

        local media_results = classify_media(
            media_info, candidates, clip_loader, rejected)
        merge_media_results(results, media_results)

        if progress_cb then
            local pct = math.floor(20 + i / total_media * 80)
            if #media_results.relinked > 0 then
                progress_cb(pct, string.format("[%d/%d] %s → relinked",
                    i, total_media, media_info.media_name))
            elseif #media_results.failed > 0 then
                progress_cb(pct, string.format("[%d/%d] %s", i, total_media, media_info.media_name))
            end
        end
    end

    if progress_cb then
        progress_cb(100, string.format("Done: %d relinked, %d failed, %d ambiguous",
            #results.relinked, #results.failed, #results.ambiguous))
    end

    log.event("classify_batch: done in %.1fs — %d relinked, %d failed, %d ambiguous",
        qt_monotonic_s() - t_match, #results.relinked, #results.failed, #results.ambiguous)

    return results
end

--- Batch relink media to candidate files using matching rules.
-- Convenience composition of scan_candidates + classify_batch for callers
-- that classify under a single rule set. The relink dialog instead calls the
-- two phases separately so it can re-classify live as the user toggles rules.
-- Matches per-media (not per-clip). Output is per-media, not per-clip.
-- @param media_infos table Array of media_info structs with source_extent_start/end
-- @param options table {search_paths, matching_rules, clip_loader}
-- @param progress_cb function|nil progress_cb(pct, status, log_line)
-- @return table {relinked, failed, ambiguous, new_media}
function M.relink_media_batch(media_infos, options, progress_cb)
    assert(type(media_infos) == "table", "relink_media_batch: media_infos required")
    assert(type(options) == "table", "relink_media_batch: options required")
    assert(type(options.search_paths) == "table" and #options.search_paths > 0,
        "relink_media_batch: options.search_paths must be a non-empty array")
    assert(type(options.matching_rules) == "table",
        "relink_media_batch: options.matching_rules required")

    local context = M.scan_candidates(media_infos, options.search_paths, progress_cb)
    return M.classify_batch(
        media_infos, context, options.matching_rules, options.clip_loader, progress_cb)
end

-- Testing hook. classify_media is file-local because it's an internal step,
-- but tests need to exercise its partial-coverage / containment branches
-- without constructing a full search-path-backed relink invocation (which
-- would require real files on disk). Keep the underscored name so callers
-- understand it's internal surface.
M._classify_media = classify_media

return M
