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
-- - Batch orchestration + result classification (relink_media_batch)
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
    local results = {}

    -- Use find command for efficiency (Lua's directory traversal is slow)
    local ext_list = {}
    for ext, _ in pairs(extensions) do
        table.insert(ext_list, string.format("-iname '*.%s'", ext))
    end
    local ext_pattern = table.concat(ext_list, " -o ")

    local cmd = string.format('find "%s" -type f \\( %s \\)', root_dir, ext_pattern)
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
                result.duration_frames = math.floor(
                    info.duration_us * info.fps_num
                        / (info.fps_den * 1000000) + 0.5)
            end
        end
    elseif has_audio_only then
        local sr = info.audio_sample_rate
        result.fps_num = sr
        result.fps_den = 1
        -- Same presence-flag semantics as video: report start_tc only
        -- when a real source (BWF time_reference or sufficient stream
        -- start_time) was found. Plain MP3s and non-BWF WAVs report no TC.
        if info.has_audio_tc_origin then
            result.start_tc_value = info.first_sample_tc
            result.start_tc_rate = sr
        end
        if info.has_duration and info.duration_us and info.duration_us > 0 then
            result.duration_frames = math.floor(
                info.duration_us * sr / 1000000 + 0.5)
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
                end
            end
        end
    end

    -- Extract TC: Strategy 2 — BWF time_reference (audio files without video TC)
    if not result.start_tc_value and data.format and data.format.tags then
        local time_ref = tonumber(data.format.tags.time_reference)
        if time_ref then
            local sample_rate = result.fps_num
            if sample_rate and sample_rate > 0 then
                result.start_tc_value = time_ref
                result.start_tc_rate = sample_rate
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

--- Find unique media records for a set of clip IDs (excludes proxy).
-- Deduplicates: multiple clips sharing the same media → one media record.
-- Two SQL round-trips total: one SELECT DISTINCT media_id over the clip ids,
-- one chunked SELECT hydrating those media rows. Old code did 2×N queries.
-- @param db table Database connection (used for the clips→media_id query)
-- @param clip_ids table Array of clip ID strings
-- @return table Array of unique Media instances
function M.find_media_for_clips(db, clip_ids)
    assert(db, "find_media_for_clips: db required")
    assert(type(clip_ids) == "table" and #clip_ids > 0,
        "find_media_for_clips: clip_ids must be non-empty array")

    -- One query: collect distinct media_ids across every clip.
    local phs = {}
    for i = 1, #clip_ids do phs[i] = "?" end
    local sql = string.format(
        "SELECT id, media_id FROM clips WHERE id IN (%s)",
        table.concat(phs, ","))

    local stmt = assert(db:prepare(sql),
        "find_media_for_clips: failed to prepare clips query")
    for i, clip_id in ipairs(clip_ids) do
        stmt:bind_value(i, clip_id)
    end
    assert(stmt:exec(), "find_media_for_clips: clips query exec failed")

    local seen = {}
    local distinct_ids = {}
    local found_clip_ids = {}
    while stmt:next() do
        local cid = stmt:value(0)
        local mid = stmt:value(1)
        assert(mid, string.format("find_media_for_clips: clip %s has no media_id", cid))
        found_clip_ids[cid] = true
        if not seen[mid] then
            seen[mid] = true
            distinct_ids[#distinct_ids + 1] = mid
        end
    end
    stmt:finalize()

    -- Preserve fail-fast: every requested clip_id must have returned a row.
    for _, clip_id in ipairs(clip_ids) do
        assert(found_clip_ids[clip_id],
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
function M.check_extent_containment(extent_start, extent_end, probe_result, stored_rate, tc_remap_offset)
    assert(extent_start and extent_end, "check_extent_containment: extent_start and extent_end required")
    assert(type(probe_result) == "table", "check_extent_containment: probe_result required")
    assert(type(stored_rate) == "number" and stored_rate > 0,
        "check_extent_containment: stored_rate must be positive")

    if not probe_result.start_tc_value or not probe_result.start_tc_rate then
        return false
    end
    if not probe_result.duration_frames then
        return false
    end

    -- Remap source extent to file TC space if override offset is provided.
    local abs_start = extent_start + (tc_remap_offset or 0)
    local abs_end = extent_end + (tc_remap_offset or 0)

    -- Candidate range at stored_rate
    local cand_start = probe_result.start_tc_value
    if stored_rate ~= probe_result.start_tc_rate then
        cand_start = math.floor(probe_result.start_tc_value * stored_rate / probe_result.start_tc_rate + 0.5)
    end

    local cand_dur = probe_result.duration_frames
    if probe_result.fps_num and probe_result.fps_den then
        local probe_rate = probe_result.fps_num / probe_result.fps_den
        if math.abs(probe_rate - stored_rate) > 0.01 then
            cand_dur = math.floor(probe_result.duration_frames * stored_rate * probe_result.fps_den / probe_result.fps_num + 0.5)
        end
    end

    local cand_end = cand_start + cand_dur

    return abs_start >= cand_start and abs_end <= cand_end
end

-- Backward compat shim: check_clip_containment delegates to check_extent_containment
-- using the clip's source_in/source_out as the extent.
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
function M.find_candidates_for_media(media_info, candidate_index, matching_rules, probe_fn)
    assert(type(media_info) == "table", "find_candidates_for_media: media_info required")
    assert(type(candidate_index) == "table", "find_candidates_for_media: candidate_index required")
    assert(type(matching_rules) == "table", "find_candidates_for_media: matching_rules required")

    local results = {}

    -- Step 1: Collect initial candidate paths
    local paths_to_check = {}

    if matching_rules.match_filename then
        local basename = get_filename(media_info.media_path)
        local lookup_key = basename and basename:lower() or nil
        if lookup_key and candidate_index[lookup_key] then
            for _, path in ipairs(candidate_index[lookup_key]) do
                paths_to_check[#paths_to_check + 1] = path
            end
        end
    else
        for _, paths in pairs(candidate_index) do
            for _, path in ipairs(paths) do
                paths_to_check[#paths_to_check + 1] = path
            end
        end
    end

    -- Step 2: Filter each candidate through enabled criteria
    for _, cand_path in ipairs(paths_to_check) do
        local passed = true
        local cand_tc_value, cand_tc_rate
        local tc_mismatch = false
        local probe_result = nil

        -- TC matching
        if passed and matching_rules.match_timecode then
            local stored_value = media_info.media_start_tc_value
            local stored_rate = media_info.media_start_tc_rate

            if stored_value and stored_rate then
                probe_result = probe_result or probe_fn(cand_path)
                if probe_result then
                    cand_tc_value = probe_result.start_tc_value
                    cand_tc_rate = probe_result.start_tc_rate
                end

                if cand_tc_value and cand_tc_rate then
                    local offset = M.compute_tc_offset(stored_value, stored_rate, cand_tc_value, cand_tc_rate)

                    if math.abs(offset) > 1 then
                        -- Primary TC mismatch — check file_original_timecode (FR-008)
                        local file_orig_tc = media_info.media_file_original_tc
                        if file_orig_tc then
                            local orig_offset = M.compute_tc_offset(
                                file_orig_tc, stored_rate, cand_tc_value, cand_tc_rate)
                            if math.abs(orig_offset) <= 1 then
                                -- Candidate matches file_original_timecode: clean accept (FR-009)
                                log.event("  %s: TC matches file_original_timecode (offset=%.1f)",
                                    get_filename(cand_path), orig_offset)
                                -- tc_mismatch stays false — no containment fallback needed
                            elseif matching_rules.accept_trimmed_media then
                                tc_mismatch = true
                            else
                                passed = false
                            end
                        elseif matching_rules.accept_trimmed_media then
                            -- No file_original_tc → existing trimmed-media containment fallback
                            tc_mismatch = true
                        else
                            passed = false
                        end
                    end
                else
                    log.detail("  %s: no candidate TC — accepting on non-TC criteria",
                        get_filename(cand_path))
                end
            else
                log.detail("  %s: no stored TC — accepting on non-TC criteria",
                    get_filename(cand_path))
            end
        end

        -- Resolution + frame rate matching
        if passed and (matching_rules.match_resolution or matching_rules.match_frame_rate) then
            probe_result = probe_result or probe_fn(cand_path)
            if probe_result then
                if matching_rules.match_resolution then
                    if probe_result.width ~= media_info.width or probe_result.height ~= media_info.height then
                        passed = false
                    end
                end
                if passed and matching_rules.match_frame_rate then
                    if probe_result.fps_num and probe_result.fps_den then
                        if probe_result.fps_num ~= media_info.fps_num or probe_result.fps_den ~= media_info.fps_den then
                            passed = false
                        end
                    end
                end
            end
        end

        if passed then
            results[#results + 1] = {
                path = cand_path,
                start_tc_value = cand_tc_value,
                start_tc_rate = cand_tc_rate,
                probe_result = probe_result,
                tc_mismatch = tc_mismatch,
            }
        end
    end

    return results
end

-- =============================================================================
-- Batch orchestration: fan out per-media matching + classification
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

-- Partition candidates into full-extent matches and TC-offset trimmed-fit
-- candidates. Rules:
--   * A candidate without tc_mismatch (or without stored_rate context) is
--     treated as a full match and goes into `viable`.
--   * A tc_mismatch whose probe range covers the full source_extent also
--     goes into `viable` — extent-containment wins over the TC flag.
--   * A tc_mismatch that fails extent but starts at/after the original
--     file's TC and within a plausible trim window is a partial_fit
--     candidate (tried lazily against per-clip ranges).
--   * A tc_mismatch that fails both is dropped.
local function partition_candidates(media_info, candidates, stored_rate, tc_remap_offset)
    local viable, partial_fit = {}, {}
    for _, cand in ipairs(candidates) do
        if not (cand.tc_mismatch and stored_rate) then
            viable[#viable + 1] = cand
        elseif media_info.source_extent_start and media_info.source_extent_end
            and cand.probe_result
            and M.check_extent_containment(
                media_info.source_extent_start, media_info.source_extent_end,
                cand.probe_result, stored_rate, tc_remap_offset) then
            viable[#viable + 1] = cand
        elseif cand.probe_result then
            local ref_tc = media_info.media_file_original_tc
                or media_info.media_start_tc_value
            if ref_tc and cand.probe_result.start_tc_value then
                local cand_tc = cand.probe_result.start_tc_value
                if cand.probe_result.start_tc_rate ~= stored_rate then
                    cand_tc = math.floor(cand_tc * stored_rate
                        / cand.probe_result.start_tc_rate + 0.5)
                end
                local offset = cand_tc - ref_tc
                -- Plausible trim: candidate starts at/after the original file,
                -- within ~24h (reject random unrelated TC space).
                if offset >= 0 and offset < 90000 * 24 then
                    partial_fit[#partial_fit + 1] = cand
                end
            end
        end
    end
    return viable, partial_fit
end

-- Pack the TC fields a Media row's metadata needs to be synced with the
-- newly-linked file. Returns nil when the probe yielded no authoritative TC
-- (plain MP3, non-BWF WAV, etc.) — Media metadata is left untouched in that
-- case so the pre-relink values aren't overwritten with blanks.
local function probed_tc_for_metadata(probe_result)
    if not probe_result then return nil end
    if not probe_result.start_tc_value or not probe_result.start_tc_rate then
        return nil
    end
    return {
        start_tc_value = probe_result.start_tc_value,
        start_tc_rate = probe_result.start_tc_rate,
        start_tc_audio_samples = probe_result.start_tc_audio_samples,
        start_tc_audio_rate = probe_result.start_tc_audio_rate,
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
    local cand_start = pr.start_tc_value or 0
    if stored_rate and pr.start_tc_rate and pr.start_tc_rate ~= stored_rate then
        cand_start = math.floor(cand_start * stored_rate / pr.start_tc_rate + 0.5)
    end
    local cand_dur = pr.duration_frames or 0
    if pr.fps_num and pr.fps_den then
        local probe_rate = pr.fps_num / pr.fps_den
        if math.abs(probe_rate - stored_rate) > 0.01 then
            cand_dur = math.floor(
                cand_dur * stored_rate * pr.fps_den / pr.fps_num + 0.5)
        end
    end
    local c0 = clips[1]
    log.event(
        "  0-clips detail: cand=[%d,%d]@%s remap=%s first_clip=[%d,%d] "
        .. "(%d clips total) file=%s",
        cand_start, cand_start + cand_dur, tostring(stored_rate),
        tostring(tc_remap_offset),
        c0.source_in, c0.source_out, #clips,
        get_filename(cand.path))
end

-- Rescale clip source range into stored_rate units and drop master clips.
-- check_clip_containment compares against probe ranges at stored_rate, so
-- audio clips at 48kHz must be down-converted or they look ~1920× too large.
local function normalize_clips_to_stored_rate(raw_clips, stored_rate)
    local out = {}
    for _, clip in ipairs(raw_clips) do
        if clip.clip_kind ~= "master" then
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
    end
    return out
end

-- Compute the partial_coverage note for the widest partial candidate — the
-- candidate carrying the most frames wins; its covered TC range drives the
-- per-clip shortfall diagnostic downstream.
local function compute_partial_coverage(partial_fit, stored_rate)
    if not stored_rate or #partial_fit == 0 then return nil end
    local best, best_dur = nil, -1
    for _, c in ipairs(partial_fit) do
        local pr = c.probe_result
        if pr and pr.duration_frames then
            local dur = pr.duration_frames
            if pr.fps_num and pr.fps_den then
                local probe_rate = pr.fps_num / pr.fps_den
                if math.abs(probe_rate - stored_rate) > 0.01 then
                    dur = math.floor(
                        dur * stored_rate * pr.fps_den / pr.fps_num + 0.5)
                end
            end
            if dur > best_dur then best, best_dur = c, dur end
        end
    end
    if not best then return nil end

    local pr = best.probe_result
    local cov_start = pr.start_tc_value or 0
    if pr.start_tc_rate and pr.start_tc_rate ~= stored_rate then
        cov_start = math.floor(cov_start * stored_rate / pr.start_tc_rate + 0.5)
    end
    return {
        candidate_path = best.path,
        probe_result = pr,
        coverage = {
            kind = "partial_coverage",
            candidate_path = best.path,
            covered_start_tc = cov_start,
            covered_end_tc = cov_start + best_dur,
            rate = stored_rate,
        },
    }
end

-- Derive a human-readable reason string for why a media failed to relink.
local function failure_reason(candidates, viable, partial_fit)
    if #candidates == 0 then
        return "no filename match in search directory"
    end
    if #partial_fit == 0 and #viable == 0 then
        return string.format(
            "%d candidate(s) found but all rejected by TC/extent filter",
            #candidates)
    end
    return "no matching candidate found"
end

--- Classify a media into relinked/failed/ambiguous/split based on candidates.
-- Media-level: uses source_extent for containment, not per-clip iteration.
-- When extent containment fails but some individual clips fit (partial-fit),
-- produces a needs_split entry with the fitting clip_ids.
-- @param media_info table Media info with source_extent_start/end
-- @param candidates table Array from find_candidates_for_media
-- @param clip_loader function(media_id) → array of {clip_id, source_in, source_out, fps_num, fps_den}
-- @return table {relinked = [...], failed = [...], ambiguous = [...]}
local function classify_media(media_info, candidates, clip_loader)
    local stored_rate = media_info.media_start_tc_rate
    local tc_remap_offset = compute_tc_remap_offset(media_info)
    local out = { relinked = {}, failed = {}, ambiguous = {} }

    local viable, partial_fit_candidates =
        partition_candidates(media_info, candidates, stored_rate, tc_remap_offset)

    if #viable > 0 then
        classify_viable(out, media_info, viable)
        return out
    end

    -- No full-fit candidates. Try partial fit via per-clip containment (lazy clip load).
    if #partial_fit_candidates > 0 and clip_loader then
        local raw_clips = clip_loader(media_info.media_id)
        if raw_clips and #raw_clips > 0 then
            local clips = normalize_clips_to_stored_rate(raw_clips, stored_rate)

            -- Pick the candidate that covers the largest subset of this
            -- media's clips.
            local best_cand, best_fits, best_count = nil, nil, 0
            for _, cand in ipairs(partial_fit_candidates) do
                if cand.probe_result then
                    local fits = {}
                    for _, clip in ipairs(clips) do
                        if M.check_clip_containment(
                            clip, cand.probe_result, stored_rate, tc_remap_offset) then
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

            if best_count > 0 and best_count == #clips then
                -- All clips fit — extent check was overly conservative
                -- (usually rate conversion rounding). Treat as full relink.
                out.relinked[#out.relinked + 1] = {
                    media_id = media_info.media_id,
                    new_path = best_cand.path,
                    strategy = best_cand.is_segment and "segment" or "filename",
                    probed_tc = probed_tc_for_metadata(best_cand.probe_result),
                }
                return out
            elseif best_count > 0 then
                out.relinked[#out.relinked + 1] = {
                    media_id = media_info.media_id,
                    new_path = best_cand.path,
                    strategy = best_cand.is_segment and "segment" or "filename",
                    needs_split = true,
                    split_clip_ids = best_fits,
                    probed_tc = probed_tc_for_metadata(best_cand.probe_result),
                }
                log.event("  partial fit: %d/%d clips fit in %s → needs split",
                    best_count, #clips, get_filename(best_cand.path))
                return out
            end
        end
    end

    -- Partial-coverage relink: the user's intent is "this file is clearly
    -- my media — just missing a few frames at the boundaries." Promote
    -- the best partial candidate so media.file_path points at the real
    -- (short) file; clips whose source range fits within coverage render
    -- online, clips extending past it render offline with a shortfall
    -- note. Shift+F, playback for covered frames, and probing all work
    -- against the real file; boundary frames produce offline output per
    -- C++ TMB EOF handling.
    local pc = compute_partial_coverage(partial_fit_candidates, stored_rate)
    if pc then
        log.event("  PARTIAL: %s → %s (covers %d..%d @%d)",
            media_info.media_name, get_filename(pc.candidate_path),
            pc.coverage.covered_start_tc, pc.coverage.covered_end_tc,
            pc.coverage.rate)
        out.relinked[#out.relinked + 1] = {
            media_id = media_info.media_id,
            new_path = pc.candidate_path,
            strategy = "partial_coverage",
            coverage = pc.coverage,
            probed_tc = probed_tc_for_metadata(pc.probe_result),
        }
        return out
    end

    local reason = failure_reason(candidates, viable, partial_fit_candidates)
    log.event("  FAILED: %s — %s", media_info.media_name, reason)

    out.failed[#out.failed + 1] = {
        media_id = media_info.media_id,
        reason = reason,
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
function M.relink_media_batch(media_infos, options, progress_cb)
    assert(type(media_infos) == "table", "relink_media_batch: media_infos required")
    assert(type(options) == "table", "relink_media_batch: options required")
    assert(type(options.search_paths) == "table" and #options.search_paths > 0,
        "relink_media_batch: options.search_paths must be a non-empty array")
    assert(type(options.matching_rules) == "table",
        "relink_media_batch: options.matching_rules required")

    local matching_rules = options.matching_rules

    local results = {
        relinked = {},
        failed = {},
        ambiguous = {},
        new_media = {},
    }

    local total_media = #media_infos
    if total_media == 0 then return results end

    -- Each media_info must carry the required fields used by the pipeline.
    for i, mi in ipairs(media_infos) do
        assert(type(mi.media_path) == "string" and mi.media_path ~= "",
            string.format("relink_media_batch: media_infos[%d].media_path required", i))
    end

    log.event("relink_media_batch: %d media, search=%s, rules: fn=%s tc=%s res=%s fps=%s trim=%s seg=%s",
        total_media, table.concat(options.search_paths, ","),
        tostring(matching_rules.match_filename), tostring(matching_rules.match_timecode),
        tostring(matching_rules.match_resolution), tostring(matching_rules.match_frame_rate),
        tostring(matching_rules.accept_trimmed_media), tostring(matching_rules.accept_filename_suffixes))

    -- Step 1: Scan search directories and build candidate index
    if progress_cb then progress_cb(0, "Scanning search directory...") end
    local t_scan = qt_monotonic_s()

    local extensions = {}
    for _, media_info in ipairs(media_infos) do
        local ext = media_info.media_path:match("%.([^%.]+)$")
        if ext then extensions[ext:lower()] = true end
    end
    assert(next(extensions) ~= nil,
        "relink_media_batch: no media_info has a parseable file extension; cannot scan for candidates")

    local ext_list = {}
    for ext in pairs(extensions) do ext_list[#ext_list + 1] = ext end
    log.detail("relink_media_batch: scanning for extensions: %s", table.concat(ext_list, ", "))

    local candidate_index = build_candidate_index(options.search_paths, extensions)

    local cand_count = 0
    for _, paths in pairs(candidate_index) do cand_count = cand_count + #paths end
    log.event("relink_media_batch: scan complete — %d candidate files in %.1fs",
        cand_count, qt_monotonic_s() - t_scan)

    -- Build segment index if enabled
    local segment_index
    if matching_rules.accept_filename_suffixes then
        segment_index = M.build_segment_index(candidate_index)
    end

    -- Unified probe cache. cache[path] tri-state:
    --   nil   = not yet probed  (triggers single-shot cached_probe)
    --   false = probed, unsupported / open failed  (cached_probe returns nil)
    --   table = probe_result shape (see probe_result_from_emp_info)
    local probe_cache = {}
    local probe_count = 0
    local probe_total_seconds = 0  -- wall-clock spent inside single-shot probe_file calls

    -- Step 1.5: Pre-probe every candidate that could ever be consulted, in
    -- parallel. Serial single-shot probes were the dominant Phase 2 cost
    -- (72.5 ms × 562 calls = 40s observed). MEDIA_PROBE_BATCH dispatches
    -- hardware_concurrency workers through emp::MediaFile::ProbeMetadata,
    -- each of which skips avformat_find_stream_info (~5× faster per probe).
    -- Combined expectation: ~40s → ~1s on 8-core hardware.
    --
    -- We only need to probe when a matching rule actually consults probe
    -- output (TC, resolution, frame rate). If none are enabled, matching is
    -- filename-only and probes are never read — skip the prefetch entirely.
    local needs_probe = matching_rules.match_timecode
        or matching_rules.match_resolution
        or matching_rules.match_frame_rate

    if needs_probe then
        local paths_to_preprobe = {}
        local seen = {}

        if matching_rules.match_filename then
            -- Only paths whose basename maps back to at least one media
            -- in the batch can ever be consulted. Narrower prefetch set.
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
            -- Without filename filter, every candidate is a potential match.
            for _, bucket in pairs(candidate_index) do
                for _, path in ipairs(bucket) do
                    if not seen[path] then
                        seen[path] = true
                        paths_to_preprobe[#paths_to_preprobe + 1] = path
                    end
                end
            end
        end

        -- Bulk prefetch runs only under the editor, where both native
        -- bindings (EMP.MEDIA_PROBE_BATCH and qt_file_stat_batch, via
        -- the disk cache) are loaded. Under plain luajit tests those
        -- bindings aren't available; we skip the prefetch and let the
        -- per-candidate cached_probe fall through to probe_file_ffprobe
        -- during the match loop. Same correctness, slower wall clock
        -- for tests — which is fine because tests use small fixtures.
        local EMP = qt_constants and qt_constants.EMP
        local bindings_ready = EMP and EMP.MEDIA_PROBE_BATCH
            and rawget(_G, "qt_file_stat_batch") ~= nil
        if bindings_ready and #paths_to_preprobe > 0 then
            if progress_cb then
                progress_cb(10, string.format("Probing %d candidate(s)...",
                    #paths_to_preprobe))
            end
            local n, dt = preprobe_batch(probe_cache, paths_to_preprobe)
            log.event("relink_media_batch: pre-probed %d candidates "
                .. "in parallel in %.2fs (%.1f ms/probe effective)",
                n, dt, n > 0 and (dt * 1000 / n) or 0)
        end
    end

    local function cached_probe(path)
        local cached = probe_cache[path]
        if cached ~= nil then
            return cached ~= false and cached or nil
        end
        probe_count = probe_count + 1
        log.detail("probe[%d]: %s", probe_count, get_filename(path))
        local t_probe = qt_monotonic_s()
        local result = probe_file(path)
        probe_total_seconds = probe_total_seconds + (qt_monotonic_s() - t_probe)
        probe_cache[path] = result or false
        if result then
            log.detail("  → tc=%s@%s res=%sx%s dur=%s",
                tostring(result.start_tc_value), tostring(result.start_tc_rate),
                tostring(result.width), tostring(result.height),
                tostring(result.duration_frames))
        end
        return result
    end

    -- Step 2: Process each media — find candidates, classify, merge
    local t_match = qt_monotonic_s()
    local classify_total_seconds = 0
    for i, media_info in ipairs(media_infos) do
        log.detail("media %d/%d: %s",
            i, total_media, media_info.media_name)

        local candidates = M.find_candidates_for_media(
            media_info, candidate_index, matching_rules, cached_probe)

        log.detail("  → %d candidate(s)", #candidates)
        for ci, c in ipairs(candidates) do
            log.detail("    [%d] %s (tc=%s@%s%s)", ci, c.path,
                tostring(c.start_tc_value), tostring(c.start_tc_rate),
                c.tc_mismatch and " TC-MISMATCH" or "")
        end

        if matching_rules.accept_filename_suffixes and segment_index then
            inject_segment_candidates(media_info, candidates, segment_index, cached_probe)
        end

        local t_classify = qt_monotonic_s()
        local media_results = classify_media(media_info, candidates, options.clip_loader)
        classify_total_seconds = classify_total_seconds + (qt_monotonic_s() - t_classify)
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

    local match_total = qt_monotonic_s() - t_match
    local other_seconds = match_total - probe_total_seconds - classify_total_seconds
    log.event("relink_media_batch: done in %.1fs — %d relinked, %d failed, %d ambiguous",
        match_total, #results.relinked, #results.failed, #results.ambiguous)
    log.detail("relink_media_batch: match breakdown — probes=%.2fs (%d calls, %.1f ms/call), "
        .. "classify=%.2fs, other=%.2fs",
        probe_total_seconds, probe_count,
        probe_count > 0 and (probe_total_seconds * 1000 / probe_count) or 0,
        classify_total_seconds, other_seconds)

    return results
end

-- Testing hook. classify_media is file-local because it's an internal
-- orchestration step, but tests need to exercise its partial-coverage /
-- containment branches without constructing a full search-path-backed
-- relink invocation (which would require real files on disk). Keep
-- the underscored name so callers understand it's internal surface.
M._classify_media = classify_media

return M
