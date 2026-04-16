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

--- Probe a candidate file for TC and media properties in a single ffprobe call.
-- Returns a unified result table, or nil on failure.
-- For video: reads timecode tag → TC in frames at video fps; extracts resolution, fps, duration.
-- For audio (BWF): reads time_reference → TC in samples at sample_rate; extracts duration.
-- @param file_path string
-- @return table|nil {start_tc_value, start_tc_rate, width, height, fps_num, fps_den, duration_frames}
local function probe_file(file_path)
    local escaped = string.format('"%s"', file_path:gsub('"', '\\"'))
    local cmd = string.format(
        'ffprobe -v error -print_format json -show_format -show_streams %s',
        escaped)
    local ok, output = pcall(shell_capture, cmd, "probe_file")
    if not ok or not output or output == "" then
        log.detail("probe_file: ffprobe failed for %s", file_path)
        return nil
    end

    local json_mod = require("dkjson")
    local data = json_mod.decode(output)
    if not data then
        log.detail("probe_file: JSON decode failed for %s", file_path)
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
                -- Convert TC string using this stream's fps
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
                -- Audio-only file: extract duration in samples at sample_rate
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
            local sample_rate = result.fps_num  -- already extracted from audio stream
            if sample_rate and sample_rate > 0 then
                result.start_tc_value = time_ref
                result.start_tc_rate = sample_rate
            end
        end
    end

    -- Valid if we got either video dimensions or audio duration
    if not result.width and not result.duration_frames then
        log.detail("probe_file: no video dims or audio duration in %s", file_path)
        return nil
    end

    return result
end



--- Check if a media path is a proxy (Resolve ProxyMedia directory).
-- Proxy media should not be relinked — they're derivative copies.
-- @param path string File path
-- @return boolean True if path is a proxy
local function is_proxy_path(path)
    return path:find("/ProxyMedia/") ~= nil
end

--- Find offline media in project (excludes proxy media).
-- @param db table Database connection
-- @param project_id string Project ID to check
-- @return table Array of offline media records
function M.find_offline_media(db, project_id)
    assert(db, "find_offline_media: db required")
    assert(project_id, "find_offline_media: project_id required")

    local Media = require("models.media")

    local stmt = db:prepare([[
        SELECT id FROM media
        WHERE project_id = ?
    ]])

    assert(stmt, "find_offline_media: failed to prepare query")

    local offline = {}
    local proxy_count = 0
    stmt:bind_value(1, project_id)
    assert(stmt:exec(), "find_offline_media: query exec failed")
    while stmt:next() do
        local media_id = stmt:value(0)
        local media = Media.load(media_id)
        assert(media, string.format("find_offline_media: failed to load media %s", media_id))
        if not file_exists(media.file_path) then
            if is_proxy_path(media.file_path) then
                proxy_count = proxy_count + 1
            else
                offline[#offline + 1] = media
            end
        end
    end

    stmt:finalize()

    if proxy_count > 0 then
        log.event("find_offline_media: skipped %d proxy media (ProxyMedia/)", proxy_count)
    end

    return offline
end

--- Find ALL non-proxy media in project (online + offline).
-- @param db table Database connection
-- @param project_id string Project ID
-- @return table Array of media records
function M.find_project_media(db, project_id)
    assert(db, "find_project_media: db required")
    assert(project_id, "find_project_media: project_id required")

    local Media = require("models.media")

    local stmt = db:prepare([[
        SELECT id, file_path FROM media
        WHERE project_id = ?
    ]])

    assert(stmt, "find_project_media: failed to prepare query")

    local results = {}
    local proxy_count = 0
    stmt:bind_value(1, project_id)
    assert(stmt:exec(), "find_project_media: query exec failed")
    while stmt:next() do
        local media_id = stmt:value(0)
        local file_path = stmt:value(1)
        if is_proxy_path(file_path) then
            proxy_count = proxy_count + 1
        else
            local media = Media.load(media_id)
            assert(media, string.format("find_project_media: failed to load media %s", media_id))
            results[#results + 1] = media
        end
    end
    stmt:finalize()

    if proxy_count > 0 then
        log.event("find_project_media: skipped %d proxy media (ProxyMedia/)", proxy_count)
    end
    log.event("find_project_media: %d media in project %s", #results, project_id)
    return results
end

--- Find unique media records for a set of clip IDs (excludes proxy).
-- Deduplicates: multiple clips sharing the same media → one media record.
-- @param db table Database connection
-- @param clip_ids table Array of clip ID strings
-- @return table Array of unique media records
function M.find_media_for_clips(db, clip_ids)
    assert(db, "find_media_for_clips: db required")
    assert(type(clip_ids) == "table" and #clip_ids > 0,
        "find_media_for_clips: clip_ids must be non-empty array")

    local Media = require("models.media")

    local seen = {}  -- media_id → true
    local results = {}
    local stmt = db:prepare("SELECT media_id FROM clips WHERE id = ?")
    assert(stmt, "find_media_for_clips: failed to prepare query")

    for _, clip_id in ipairs(clip_ids) do
        stmt:bind_value(1, clip_id)
        assert(stmt:exec(), string.format("find_media_for_clips: query failed for clip %s", clip_id))
        assert(stmt:next(), string.format("find_media_for_clips: clip not found: %s", clip_id))
        local media_id = stmt:value(0)
        assert(media_id, string.format("find_media_for_clips: clip %s has no media_id", clip_id))
        stmt:reset()

        if not seen[media_id] then
            seen[media_id] = true
            local media = Media.load(media_id)
            assert(media, string.format("find_media_for_clips: media not found: %s", media_id))
            if not is_proxy_path(media.file_path) then
                results[#results + 1] = media
            end
        end
    end
    stmt:finalize()

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
    local out = { relinked = {}, failed = {}, ambiguous = {} }

    -- Compute TC remap offset for override clips
    local tc_remap_offset = nil
    if media_info.media_file_original_tc and media_info.media_start_tc_value then
        local delta = media_info.media_file_original_tc - media_info.media_start_tc_value
        if delta ~= 0 then
            tc_remap_offset = delta
        end
    end

    -- Filter candidates: non-tc_mismatch pass through, tc_mismatch need containment
    local viable = {}
    local partial_fit_candidates = {}  -- tc_mismatch candidates that failed extent but may fit some clips

    for _, cand in ipairs(candidates) do
        if cand.tc_mismatch and stored_rate then
            if media_info.source_extent_start and media_info.source_extent_end
                and cand.probe_result
                and M.check_extent_containment(
                    media_info.source_extent_start, media_info.source_extent_end,
                    cand.probe_result, stored_rate, tc_remap_offset) then
                -- Full extent fit — all clips covered
                viable[#viable + 1] = cand
            elseif cand.probe_result then
                -- Extent doesn't fit — check if this is plausibly a trimmed version
                -- of the same file (TC offset positive and within source extent range).
                -- Don't waste the clip_loader on completely unrelated TC mismatches.
                local ref_tc = media_info.media_file_original_tc or media_info.media_start_tc_value
                if ref_tc and cand.probe_result.start_tc_value then
                    local cand_tc = cand.probe_result.start_tc_value
                    if cand.probe_result.start_tc_rate ~= stored_rate then
                        cand_tc = math.floor(cand_tc * stored_rate / cand.probe_result.start_tc_rate + 0.5)
                    end
                    local offset = cand_tc - ref_tc
                    -- Trimmed file: candidate starts at or after the original file's TC.
                    -- Plausible if offset is positive and within ~24h (not random TC space).
                    if offset >= 0 and offset < 90000 * 24 then
                        partial_fit_candidates[#partial_fit_candidates + 1] = cand
                    end
                end
            end
        else
            viable[#viable + 1] = cand
        end
    end

    -- If we have viable candidates (full fit or clean TC match), classify normally
    if #viable > 0 then
        if #viable == 1 then
            out.relinked[#out.relinked + 1] = {
                media_id = media_info.media_id,
                new_path = viable[1].path,
                strategy = viable[1].is_segment and "segment" or "filename",
            }
        else
            local cand_info = {}
            for _, c in ipairs(viable) do
                cand_info[#cand_info + 1] = {
                    path = c.path, start_tc = c.start_tc_value, start_tc_rate = c.start_tc_rate,
                }
            end
            out.ambiguous[#out.ambiguous + 1] = { media_id = media_info.media_id, candidates = cand_info }
        end
        return out
    end

    -- No full-fit candidates. Try partial fit via per-clip containment (lazy clip load).
    if #partial_fit_candidates > 0 and clip_loader then
        local raw_clips = clip_loader(media_info.media_id)
        if raw_clips and #raw_clips > 0 then
            -- Normalize clip source ranges to stored_rate and exclude master clips.
            -- clip_loader returns clips in their native rate (48kHz audio, 25fps video, etc.);
            -- check_extent_containment compares against the candidate range at stored_rate.
            -- Without normalization, audio clips' sample-based source_in/out are ~1920x larger
            -- than the frame-based candidate range, so they always fail containment.
            local clips = {}
            for _, clip in ipairs(raw_clips) do
                if clip.clip_kind ~= "master" then
                    local clip_rate = clip.fps_num / (clip.fps_den or 1)
                    local src_in = clip.source_in
                    local src_out = clip.source_out
                    if clip_rate > 0 and math.abs(clip_rate - stored_rate) > 0.01 then
                        src_in = math.floor(src_in * stored_rate / clip_rate + 0.5)
                        src_out = math.floor(src_out * stored_rate / clip_rate + 0.5)
                    end
                    clips[#clips + 1] = {
                        clip_id = clip.clip_id,
                        source_in = src_in,
                        source_out = src_out,
                    }
                end
            end

            -- Try each partial candidate — pick the one that covers the most clips
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
                        -- Log why zero clips fit: show clip range vs candidate range
                        local pr = cand.probe_result
                        local cand_start = pr.start_tc_value or 0
                        if stored_rate and pr.start_tc_rate and pr.start_tc_rate ~= stored_rate then
                            cand_start = math.floor(cand_start * stored_rate / pr.start_tc_rate + 0.5)
                        end
                        local cand_dur = pr.duration_frames or 0
                        if pr.fps_num and pr.fps_den then
                            local probe_rate = pr.fps_num / pr.fps_den
                            if math.abs(probe_rate - stored_rate) > 0.01 then
                                cand_dur = math.floor(cand_dur * stored_rate * pr.fps_den / pr.fps_num + 0.5)
                            end
                        end
                        local c0 = clips[1]
                        log.event("  0-clips detail: cand=[%d,%d]@%s remap=%s first_clip=[%d,%d] (%d clips total) file=%s",
                            cand_start, cand_start + cand_dur, tostring(stored_rate),
                            tostring(tc_remap_offset),
                            c0.source_in, c0.source_out, #clips,
                            get_filename(cand.path))
                    end
                    if #fits > best_count then
                        best_cand = cand
                        best_fits = fits
                        best_count = #fits
                    end
                end
            end

            if best_count > 0 and best_count == #clips then
                -- Actually ALL clips fit — extent check was overly conservative
                -- (can happen with rate conversion rounding). Full relink.
                out.relinked[#out.relinked + 1] = {
                    media_id = media_info.media_id,
                    new_path = best_cand.path,
                    strategy = best_cand.is_segment and "segment" or "filename",
                }
                return out
            elseif best_count > 0 then
                -- Partial fit: some clips fit, some don't → needs split
                out.relinked[#out.relinked + 1] = {
                    media_id = media_info.media_id,
                    new_path = best_cand.path,
                    strategy = best_cand.is_segment and "segment" or "filename",
                    needs_split = true,
                    split_clip_ids = best_fits,
                }
                log.event("  partial fit: %d/%d clips fit in %s → needs split",
                    best_count, #clips, get_filename(best_cand.path))
                return out
            end
        end
    end

    -- Nothing viable — log why at event level so failures are diagnosable
    local reason
    if #candidates == 0 then
        reason = "no filename match in search directory"
    elseif #partial_fit_candidates == 0 and #viable == 0 then
        reason = string.format("%d candidate(s) found but all rejected by TC/extent filter", #candidates)
    elseif #partial_fit_candidates > 0 then
        reason = string.format("%d partial candidate(s) but 0 clips passed containment", #partial_fit_candidates)
    else
        reason = "no matching candidate found"
    end
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
    local t_scan = os.clock()

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
        cand_count, os.clock() - t_scan)

    -- Build segment index if enabled
    local segment_index
    if matching_rules.accept_filename_suffixes then
        segment_index = M.build_segment_index(candidate_index)
    end

    -- Unified probe cache: one ffprobe call per file for both TC and media properties
    local probe_cache = {}
    local probe_count = 0

    local function cached_probe(path)
        local cached = probe_cache[path]
        if cached ~= nil then
            return cached ~= false and cached or nil
        end
        probe_count = probe_count + 1
        log.detail("probe[%d]: %s", probe_count, get_filename(path))
        local result = probe_file(path)
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
    local t_match = os.clock()
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

        local media_results = classify_media(media_info, candidates, options.clip_loader)
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

    log.event("relink_media_batch: done in %.1fs — %d relinked, %d failed, %d ambiguous (probes: %d)",
        os.clock() - t_match, #results.relinked, #results.failed, #results.ambiguous,
        probe_count)

    return results
end

return M
