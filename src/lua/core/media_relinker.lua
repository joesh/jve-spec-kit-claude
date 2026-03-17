--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~417 LOC
-- Volatility: unknown
--
-- @file media_relinker.lua
-- Original intent (unreviewed):
-- Media Relinking System
-- Reconnects offline media files to clips after files have been moved/renamed
-- Supports three strategies: path-based, filename-based, metadata-based
--
-- Architecture: Command-based relinking for full undo/redo support
-- All relinking operations create RelinkClips commands that can be undone
local M = {}
local log = require("core.logger").for_area("media")

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

    local cmd = string.format('find "%s" -type f \\( %s \\) 2>/dev/null',
        root_dir, ext_pattern)
    log.event("scan_directory: %s", cmd)

    local handle = io.popen(cmd)
    if handle then
        for line in handle:lines() do
            if line and line ~= "" then
                table.insert(results, line)
            end
        end
        handle:close()
    end

    log.event("scan_directory: found %d files", #results)
    return results
end

local function build_candidate_cache(search_paths, extensions)
    local candidate_files = {}
    local candidate_index = {}

    if not search_paths or not extensions or next(extensions) == nil then
        return candidate_files, candidate_index
    end

    for _, search_path in ipairs(search_paths) do
        local files = scan_directory(search_path, extensions)
        for _, file_path in ipairs(files) do
            table.insert(candidate_files, file_path)
            local filename = get_filename(file_path)
            if filename then
                local key = filename:lower()
                local bucket = candidate_index[key]
                if not bucket then
                    bucket = {}
                    candidate_index[key] = bucket
                end
                table.insert(bucket, file_path)
            end
        end
    end

    return candidate_files, candidate_index
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

--- Probe a candidate file's start TC via ffprobe.
-- Returns (start_frames, rate) — same representation as stored start_tc.
-- For video: reads timecode tag, converts to frames at video fps.
-- For audio (BWF): reads time_reference (samples), returns at sample_rate.
-- @param file_path string
-- @return number|nil start_frames
-- @return number|nil rate
local function probe_start_tc(file_path)
    local escaped = string.format('"%s"', file_path:gsub('"', '\\"'))
    local cmd = string.format(
        'ffprobe -v error -print_format json -show_format -show_streams %s 2>/dev/null',
        escaped)
    local handle = io.popen(cmd)
    if not handle then return nil, nil end
    local output = handle:read("*a")
    handle:close()
    if not output or output == "" then return nil, nil end

    local json = require("dkjson")
    local data = json.decode(output)
    if not data then return nil, nil end

    -- Strategy 1: Video TC tag — "HH:MM:SS:FF" in format or stream tags
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

    if tc_str then
        -- Get fps from video stream to convert TC string to frames
        local fps = nil
        if data.streams then
            for _, stream in ipairs(data.streams) do
                if stream.codec_type == "video" then
                    if stream.r_frame_rate then
                        local num, den = stream.r_frame_rate:match("(%d+)/(%d+)")
                        if num and den then
                            fps = math.floor(tonumber(num) / tonumber(den) + 0.5)
                        end
                    end
                    break
                end
            end
        end
        if fps and fps > 0 then
            local frames = tc_to_frames(tc_str, fps)
            if frames then return frames, fps end
        end
    end

    -- Strategy 2: BWF time_reference — sample offset since midnight (audio files)
    if data.format and data.format.tags then
        local time_ref = tonumber(data.format.tags.time_reference)
        if time_ref then
            -- Find audio sample rate
            local sample_rate = nil
            if data.streams then
                for _, stream in ipairs(data.streams) do
                    if stream.codec_type == "audio" then
                        sample_rate = tonumber(stream.sample_rate)
                        break
                    end
                end
            end
            if sample_rate and sample_rate > 0 then
                return time_ref, sample_rate
            end
        end
    end

    return nil, nil
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
    local Media = require("models.media")

    local stmt = db:prepare([[
        SELECT id FROM media
        WHERE project_id = ?
    ]])

    if not stmt then
        return {}
    end

    local offline = {}
    local proxy_count = 0
    stmt:bind_value(1, project_id)
    if stmt:exec() then
        while stmt:next() do
            local media_id = stmt:value(0)
            local media = Media.load(media_id)
            if media and not file_exists(media.file_path) then
                if is_proxy_path(media.file_path) then
                    proxy_count = proxy_count + 1
                else
                    table.insert(offline, media)
                end
            end
        end
    end

    stmt:finalize()

    if proxy_count > 0 then
        log.event("find_offline_media: skipped %d proxy media (ProxyMedia/)", proxy_count)
    end

    return offline
end


-- =============================================================================
-- RelinkClips: Pure Algorithm Functions (T006-T008)
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

    -- Rescale candidate to stored_rate for comparison
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

--- Adjust source_in/source_out by a TC offset.
-- Offset is in the same rate as source_in/source_out (caller must rescale).
-- If the adjusted source_in would be negative, returns nil, nil.
-- @param source_in number Current source_in
-- @param source_out number Current source_out
-- @param offset number TC offset (positive = candidate starts later)
-- @param clip_rate number Clip's native rate (for documentation, not used in math)
-- @return number|nil new_source_in, number|nil new_source_out
function M.adjust_source_range(source_in, source_out, offset, _clip_rate)
    assert(type(source_in) == "number", "adjust_source_range: source_in required")
    assert(type(source_out) == "number", "adjust_source_range: source_out required")
    assert(type(offset) == "number", "adjust_source_range: offset required")

    local new_in = source_in - offset
    local new_out = source_out - offset

    if new_in < 0 then
        return nil, nil
    end

    return new_in, new_out
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

--- Find candidate files for a clip based on matching rules.
-- Pure function: uses injectable probe functions instead of real ffprobe.
-- @param clip_info table Clip info struct (see contract)
-- @param candidate_index table {basename_lower → [paths]}
-- @param matching_rules table Matching criteria
-- @param probe_tc_fn function(path) → (value, rate) or (nil, nil)
-- @param probe_media_fn function(path) → {width, height, fps_num, fps_den, duration_frames} or nil
-- @return table Array of {path, start_tc_value, start_tc_rate}
function M.find_candidates_for_clip(clip_info, candidate_index, matching_rules, probe_tc_fn, probe_media_fn)
    assert(type(clip_info) == "table", "find_candidates_for_clip: clip_info required")
    assert(type(candidate_index) == "table", "find_candidates_for_clip: candidate_index required")
    assert(type(matching_rules) == "table", "find_candidates_for_clip: matching_rules required")

    local results = {}

    -- Step 1: Collect initial candidate paths
    local paths_to_check = {}

    if matching_rules.match_filename then
        -- Match by basename from the index
        local basename = get_filename(clip_info.media_path)
        local lookup_key = basename and basename:lower() or nil
        if lookup_key and candidate_index[lookup_key] then
            for _, path in ipairs(candidate_index[lookup_key]) do
                paths_to_check[#paths_to_check + 1] = path
            end
        end
    else
        -- No filename matching — check ALL candidates in the index
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

        -- TC matching
        if passed and matching_rules.match_timecode then
            local stored_value = clip_info.media_start_tc_value
            local stored_rate = clip_info.media_start_tc_rate

            if stored_value and stored_rate then
                cand_tc_value, cand_tc_rate = probe_tc_fn(cand_path)

                if cand_tc_value and cand_tc_rate then
                    -- Check if TC matches (±1 frame tolerance)
                    local offset = M.compute_tc_offset(stored_value, stored_rate, cand_tc_value, cand_tc_rate)

                    if math.abs(offset) > 1 then
                        -- TC doesn't match exactly
                        if matching_rules.accept_trimmed_media then
                            -- Check containment: clip's absolute TC range must fit in candidate
                            -- source_in/source_out are in clip rate; stored_value is in stored_rate
                            -- Must rescale source coords to stored_rate for addition
                            local clip_rate = clip_info.fps_num / clip_info.fps_den
                            local src_in_rescaled = clip_info.source_in
                            local src_out_rescaled = clip_info.source_out
                            if math.abs(clip_rate - stored_rate) > 0.01 then
                                src_in_rescaled = math.floor(clip_info.source_in * stored_rate / clip_rate + 0.5)
                                src_out_rescaled = math.floor(clip_info.source_out * stored_rate / clip_rate + 0.5)
                            end
                            local abs_start = stored_value + src_in_rescaled
                            local abs_end = stored_value + src_out_rescaled

                            -- Candidate range at stored_rate
                            local cand_start_rescaled = cand_tc_value
                            if stored_rate ~= cand_tc_rate then
                                cand_start_rescaled = math.floor(cand_tc_value * stored_rate / cand_tc_rate + 0.5)
                            end

                            local media_info = probe_media_fn(cand_path)
                            if media_info and media_info.duration_frames then
                                local cand_dur_rescaled = media_info.duration_frames
                                if media_info.fps_num and media_info.fps_den and stored_rate ~= media_info.fps_num / media_info.fps_den then
                                    cand_dur_rescaled = math.floor(media_info.duration_frames * stored_rate * media_info.fps_den / media_info.fps_num + 0.5)
                                end
                                local cand_end = cand_start_rescaled + cand_dur_rescaled

                                if abs_start < cand_start_rescaled or abs_end > cand_end then
                                    passed = false  -- clip range not contained
                                end
                            else
                                passed = false  -- can't verify containment without duration
                            end
                        else
                            passed = false  -- TC mismatch and trimmed not accepted
                        end
                    end
                end
                -- If candidate has no TC → accept on other criteria (TC check not applicable)
            end
            -- If stored TC is nil → can't verify, accept on other criteria
        end

        -- Resolution + frame rate matching (single probe call)
        if passed and (matching_rules.match_resolution or matching_rules.match_frame_rate) then
            local media_info = probe_media_fn(cand_path)
            if media_info then
                if matching_rules.match_resolution then
                    if media_info.width ~= clip_info.width or media_info.height ~= clip_info.height then
                        passed = false
                    end
                end
                if passed and matching_rules.match_frame_rate then
                    if media_info.fps_num and media_info.fps_den then
                        if media_info.fps_num ~= clip_info.fps_num or media_info.fps_den ~= clip_info.fps_den then
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
            }
        end
    end

    return results
end

-- =============================================================================
-- RelinkClips: Batch Relink (T008)
-- =============================================================================

--- Batch relink clips to candidate files using matching rules.
-- Scans search directories, builds candidate index, matches each clip.
-- @param clips table Array of clip_info structs (see contract)
-- @param options table {search_paths, matching_rules}
-- @param progress_cb function|nil progress_cb(pct, status, log_line)
-- @return table {relinked, failed, ambiguous, new_media}
function M.relink_clips_batch(clips, options, progress_cb)
    assert(type(clips) == "table", "relink_clips_batch: clips required")
    assert(type(options) == "table", "relink_clips_batch: options required")
    assert(options.search_paths, "relink_clips_batch: search_paths required")

    local matching_rules = options.matching_rules or {
        match_filename = true, match_timecode = true,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }

    local results = {
        relinked = {},
        failed = {},
        ambiguous = {},
        new_media = {},
    }

    local total = #clips
    if total == 0 then return results end

    log.event("relink_clips_batch: %d clips, search=%s, rules: fn=%s tc=%s res=%s fps=%s trim=%s seg=%s",
        total, table.concat(options.search_paths, ","),
        tostring(matching_rules.match_filename), tostring(matching_rules.match_timecode),
        tostring(matching_rules.match_resolution), tostring(matching_rules.match_frame_rate),
        tostring(matching_rules.accept_trimmed_media), tostring(matching_rules.accept_filename_suffixes))

    -- Step 1: Scan search directories and build candidate index
    if progress_cb then progress_cb(0, "Scanning search directory...") end
    local t_scan = os.clock()

    -- Collect all extensions from clips
    local extensions = {}
    for _, clip_info in ipairs(clips) do
        local ext = clip_info.media_path and clip_info.media_path:match("%.([^%.]+)$")
        if ext then extensions[ext:lower()] = true end
    end

    local ext_list = {}
    for ext in pairs(extensions) do ext_list[#ext_list+1] = ext end
    log.detail("relink_clips_batch: scanning for extensions: %s", table.concat(ext_list, ", "))

    local _, candidate_index = build_candidate_cache(options.search_paths, extensions)

    local cand_count = 0
    for _, paths in pairs(candidate_index) do cand_count = cand_count + #paths end
    log.event("relink_clips_batch: scan complete — %d candidate files in %.1fs",
        cand_count, os.clock() - t_scan)

    -- Build segment index if enabled
    local segment_index
    if matching_rules.accept_filename_suffixes then
        segment_index = M.build_segment_index(candidate_index)
    end

    -- Probe caches: each file probed at most once across all clips
    local tc_cache = {}    -- path → {value, rate} or {nil, nil}
    local media_cache = {} -- path → info table or false

    local tc_probe_count = 0
    local media_probe_count = 0

    local function cached_probe_tc(path)
        local cached = tc_cache[path]
        if cached ~= nil then
            return cached[1], cached[2]
        end
        tc_probe_count = tc_probe_count + 1
        log.detail("probe_tc[%d]: %s", tc_probe_count, get_filename(path))
        local val, rate = probe_start_tc(path)
        tc_cache[path] = {val, rate}
        log.detail("  → tc=%s @ %s", tostring(val), tostring(rate))
        return val, rate
    end

    local function cached_probe_media(path)
        local cached = media_cache[path]
        if cached ~= nil then
            return cached ~= false and cached or nil
        end
        media_probe_count = media_probe_count + 1
        log.detail("probe_media[%d]: %s", media_probe_count, get_filename(path))
        local escaped = string.format('"%s"', path:gsub('"', '\\"'))
        local cmd = string.format(
            'ffprobe -v error -print_format json -show_streams %s 2>/dev/null', escaped)
        local handle = io.popen(cmd)
        if not handle then media_cache[path] = false; return nil end
        local output = handle:read("*a")
        handle:close()
        if not output or output == "" then media_cache[path] = false; return nil end
        local json_mod = require("dkjson")
        local data = json_mod.decode(output)
        if not data or not data.streams then media_cache[path] = false; return nil end
        local info = {}
        for _, stream in ipairs(data.streams) do
            if stream.codec_type == "video" then
                info.width = tonumber(stream.width)
                info.height = tonumber(stream.height)
                if stream.r_frame_rate then
                    local num, den = stream.r_frame_rate:match("(%d+)/(%d+)")
                    if num and den then
                        info.fps_num = tonumber(num)
                        info.fps_den = tonumber(den)
                    end
                end
                if stream.nb_frames then
                    info.duration_frames = tonumber(stream.nb_frames)
                elseif stream.duration and info.fps_num and info.fps_den then
                    info.duration_frames = math.floor(
                        tonumber(stream.duration) * info.fps_num / info.fps_den + 0.5)
                end
            elseif stream.codec_type == "audio" and not info.width then
                -- Audio-only file: extract duration in samples at sample_rate
                local sample_rate = tonumber(stream.sample_rate)
                if sample_rate and sample_rate > 0 then
                    info.fps_num = sample_rate
                    info.fps_den = 1
                    if stream.duration then
                        info.duration_frames = math.floor(
                            tonumber(stream.duration) * sample_rate + 0.5)
                    elseif stream.nb_frames then
                        info.duration_frames = tonumber(stream.nb_frames)
                    end
                end
            end
        end
        -- Valid if we got either video dimensions or audio duration
        local result = (info.width or info.duration_frames) and info or nil
        media_cache[path] = result or false
        return result
    end

    -- Step 2: Process each clip
    local t_match = os.clock()
    for i, clip_info in ipairs(clips) do
        local clip_name = clip_info.clip_name or clip_info.clip_id:sub(1, 8)

        log.detail("clip %d/%d: %s (media=%s src=%d..%d)",
            i, total, clip_name, clip_info.media_name,
            clip_info.source_in, clip_info.source_out)

        -- Find candidates using the pure algorithm function
        local candidates = M.find_candidates_for_clip(
            clip_info, candidate_index, matching_rules,
            cached_probe_tc,
            cached_probe_media
        )

        log.detail("  → %d candidate(s)", #candidates)
        for ci, c in ipairs(candidates) do
            log.detail("    [%d] %s (tc=%s@%s)", ci, c.path, tostring(c.start_tc_value), tostring(c.start_tc_rate))
        end

        -- Also check segment files if enabled
        if matching_rules.accept_filename_suffixes and segment_index then
            local basename = get_filename(clip_info.media_path)
            local seg_key = basename and basename:lower() or nil
            if seg_key and segment_index[seg_key] then
                local seen = {}
                for _, c in ipairs(candidates) do seen[c.path] = true end

                for _, seg_path in ipairs(segment_index[seg_key]) do
                    if not seen[seg_path] then
                        seen[seg_path] = true
                        local seg_tc_val, seg_tc_rate = cached_probe_tc(seg_path)
                        candidates[#candidates + 1] = {
                            path = seg_path,
                            start_tc_value = seg_tc_val,
                            start_tc_rate = seg_tc_rate,
                            is_segment = true,
                        }
                    end
                end
            end
        end

        -- Evaluate results
        if #candidates == 0 then
            results.failed[#results.failed + 1] = {
                clip_id = clip_info.clip_id,
                reason = "no matching candidate found",
            }
            if progress_cb then
                progress_cb(math.floor(i / total * 100), nil,
                    string.format("[--] %s", clip_name))
            end
        elseif #candidates == 1 then
            local cand = candidates[1]
            local new_source_in = clip_info.source_in
            local new_source_out = clip_info.source_out

            -- Compute TC offset if candidate has different TC
            if cand.start_tc_value and clip_info.media_start_tc_value then
                local offset = M.compute_tc_offset(
                    clip_info.media_start_tc_value, clip_info.media_start_tc_rate,
                    cand.start_tc_value, cand.start_tc_rate)

                if math.abs(offset) > 1 then
                    -- Rescale offset to clip rate
                    local offset_at_clip_rate = offset
                    if clip_info.media_start_tc_rate ~= clip_info.fps_num / clip_info.fps_den then
                        offset_at_clip_rate = math.floor(
                            offset * (clip_info.fps_num / clip_info.fps_den) /
                            clip_info.media_start_tc_rate + 0.5)
                    end

                    local adj_in, adj_out = M.adjust_source_range(
                        clip_info.source_in, clip_info.source_out, offset_at_clip_rate, clip_info.fps_num)

                    if adj_in then
                        new_source_in = adj_in
                        new_source_out = adj_out
                    else
                        -- Clip falls outside candidate range
                        results.failed[#results.failed + 1] = {
                            clip_id = clip_info.clip_id,
                            reason = "clip source range falls outside candidate after TC offset",
                        }
                        if progress_cb then
                            progress_cb(math.floor(i / total * 100), nil,
                                string.format("[--] %s (out of range after TC offset)", clip_name))
                        end
                        goto continue
                    end
                end
            end

            results.relinked[#results.relinked + 1] = {
                clip_id = clip_info.clip_id,
                original_media_id = clip_info.media_id,
                new_media_id = nil,  -- reuse existing unless segment
                new_source_in = new_source_in,
                new_source_out = new_source_out,
                new_path = cand.path,
                strategy = cand.is_segment and "segment" or "filename",
            }

            if progress_cb then
                progress_cb(math.floor(i / total * 100),
                    string.format("Processing %d of %d...", i, total),
                    string.format("[OK] %s → %s", clip_name, get_filename(cand.path)))
            end
        else
            -- Multiple candidates — mark ambiguous
            local cand_info = {}
            for _, c in ipairs(candidates) do
                cand_info[#cand_info + 1] = {
                    path = c.path,
                    start_tc = c.start_tc_value,
                    start_tc_rate = c.start_tc_rate,
                }
            end
            results.ambiguous[#results.ambiguous + 1] = {
                clip_id = clip_info.clip_id,
                candidates = cand_info,
            }
            if progress_cb then
                progress_cb(math.floor(i / total * 100), nil,
                    string.format("[??] %s (%d candidates)", clip_name, #candidates))
            end
        end

        ::continue::
    end

    if progress_cb then
        progress_cb(100, string.format("Done: %d relinked, %d failed, %d ambiguous",
            #results.relinked, #results.failed, #results.ambiguous))
    end

    log.event("relink_clips_batch: done in %.1fs — %d relinked, %d failed, %d ambiguous (probes: %d tc, %d media)",
        os.clock() - t_match, #results.relinked, #results.failed, #results.ambiguous,
        tc_probe_count, media_probe_count)

    return results
end

return M
