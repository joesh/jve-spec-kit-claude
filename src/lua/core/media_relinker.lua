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
-- All relinking operations create RelinkMedia commands that can be undone
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

--- Extract file extension
-- @param file_path string File path
-- @return string Extension like "mov" or "mp4" (lowercase)
local function get_extension(file_path)
    local ext = file_path:match("%.([^%.]+)$")
    return ext and ext:lower() or ""
end

--- Normalize path for comparison (handle case sensitivity, separators)
-- @param path string File path
-- @return string Normalized path
-- luacheck: ignore 211 (unused function reserved for future use)
local function _normalize_path(path)
    -- Convert backslashes to forward slashes
    local normalized = path:gsub("\\", "/")
    -- Remove trailing slashes
    normalized = normalized:gsub("/$", "")
    -- Case-insensitive on Windows/Mac (but not Linux - we'll assume case-insensitive for now)
    return normalized:lower()
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

local function ensure_candidate_cache(options, extensions)
    if not options or not options.search_paths then
        return
    end

    options._candidate_extensions = options._candidate_extensions or {}
    local pending = {}

    if type(extensions) == "table" then
        for ext, include in pairs(extensions) do
            if include and ext and ext ~= "" and not options._candidate_extensions[ext] then
                pending[ext] = true
            end
        end
    elseif type(extensions) == "string" and extensions ~= "" then
        if not options._candidate_extensions[extensions] then
            pending[extensions] = true
        end
    end

    if next(pending) == nil then
        return
    end

    local files, index = build_candidate_cache(options.search_paths, pending)
    options.candidate_files = options.candidate_files or {}
    options.candidate_index = options.candidate_index or {}

    for _, path in ipairs(files) do
        table.insert(options.candidate_files, path)
    end

    for key, paths in pairs(index) do
        local bucket = options.candidate_index[key]
        if not bucket then
            bucket = {}
            options.candidate_index[key] = bucket
        end
        for _, path in ipairs(paths) do
            table.insert(bucket, path)
        end
    end

    for ext in pairs(pending) do
        options._candidate_extensions[ext] = true
    end
end

--- Calculate similarity score between two strings (0-1)
-- Uses Levenshtein-like algorithm for fuzzy matching
-- @param str1 string First string
-- @param str2 string Second string
-- @return number Similarity score (1.0 = perfect match, 0.0 = no match)
local function string_similarity(str1, str2)
    if str1 == str2 then return 1.0 end

    local len1, len2 = #str1, #str2
    if len1 == 0 or len2 == 0 then return 0.0 end

    -- Simple character overlap score (not true Levenshtein but faster)
    local matches = 0
    local max_len = math.max(len1, len2)

    for i = 1, math.min(len1, len2) do
        if str1:sub(i, i):lower() == str2:sub(i, i):lower() then
            matches = matches + 1
        end
    end

    return matches / max_len
end

--- Strategy 1: Path-based relinking
-- Attempts to find files at same relative path under new root
-- @param media table Media record with old file_path
-- @param new_root string New root directory to search under
-- @return string|nil New absolute path if found, nil otherwise
local function relink_by_path(media, new_root)
    local old_path = media.file_path

    -- Try to extract relative path by finding common media folder names
    local common_roots = {"Media", "Footage", "Video", "Audio", "Assets", "Clips"}
    local relative_path = nil

    for _, root_name in ipairs(common_roots) do
        local pattern = "/" .. root_name .. "/(.+)$"
        relative_path = old_path:match(pattern)
        if relative_path then
            break
        end
    end

    if not relative_path then
        -- No common root found, just use filename
        relative_path = get_filename(old_path)
    end

    -- Try constructing new path
    local new_path = new_root .. "/" .. relative_path
    if file_exists(new_path) then
        return new_path
    end

    return nil
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

--- Get the media record's stored start TC as (frames, rate).
-- @param media table Media record
-- @return number|nil frames, number|nil rate
local function get_stored_start_tc(media)
    if not media.metadata or media.metadata == "" or media.metadata == "{}" then
        return nil, nil
    end
    local meta = media.metadata
    if type(meta) == "string" then
        local json = require("dkjson")
        meta = json.decode(meta)
    end
    if type(meta) == "table" and meta.start_tc_value then
        return meta.start_tc_value, meta.start_tc_rate
    end
    return nil, nil
end

--- Verify candidate file's start TC matches the media record's stored TC.
-- Both values compared as integer frames (rescaled to common rate if needed).
-- Rejects media-managed copies with different TC origins (would destroy the edit).
-- Files without TC (audio, stills) or media without stored TC accepted on filename.
-- @param media table Media record (with metadata.start_tc_value/start_tc_rate)
-- @param candidate_path string
-- @return boolean true if TC matches or check not applicable
local function verify_candidate_tc(media, candidate_path)
    local stored_frames, stored_rate = get_stored_start_tc(media)
    if not stored_frames or not stored_rate then
        return true  -- no stored TC (pre-fix import or native import)
    end

    local cand_frames, cand_rate = probe_start_tc(candidate_path)
    if not cand_frames or not cand_rate then
        return true  -- no TC in candidate (still image, no BWF)
    end

    -- Rescale to common rate for comparison (convert stored to candidate's rate)
    local stored_rescaled = stored_frames
    if stored_rate ~= cand_rate then
        stored_rescaled = math.floor(stored_frames * cand_rate / stored_rate + 0.5)
    end

    -- ±1 unit tolerance (1 frame for video, 1 sample for audio — effectively sub-frame)
    if math.abs(cand_frames - stored_rescaled) <= 1 then
        log.event("verify_tc: match %s (%d @ %d)",
            get_filename(candidate_path), cand_frames, cand_rate)
        return true
    end

    log.warn("verify_tc: REJECTED %s — probed %d @ %d != stored %d @ %d (media-managed copy?)",
        get_filename(candidate_path), cand_frames, cand_rate, stored_frames, stored_rate)
    return false
end

--- Strategy 2: Filename-based relinking
-- Searches directory tree for matching filename, verifies TC match
-- @param media table Media record with old file_path
-- @param search_paths table Array of directories to search
-- @param candidate_files table Pre-scanned file list (optional)
-- @return string|nil New absolute path if found, nil otherwise
local function relink_by_filename(media, search_paths, candidate_files, candidate_index)
    local old_filename = get_filename(media.file_path)
    local old_ext = get_extension(media.file_path)
    local lookup_key = old_filename and old_filename:lower() or nil
    log.event("relink_by_filename: looking for '%s' (ext=%s, candidates=%d, index_hit=%s)",
        old_filename or "?", old_ext or "?",
        candidate_files and #candidate_files or 0,
        tostring(candidate_index and lookup_key and candidate_index[lookup_key] ~= nil))

    -- Collect filename matches, then verify
    local matches = {}

    if candidate_index and lookup_key and candidate_index[lookup_key] then
        for _, file_path in ipairs(candidate_index[lookup_key]) do
            local ext = get_extension(file_path)
            if ext == old_ext and file_exists(file_path) then
                matches[#matches + 1] = file_path
            end
        end
    end

    if #matches == 0 and candidate_files then
        for _, file_path in ipairs(candidate_files) do
            local filename = get_filename(file_path)
            local ext = get_extension(file_path)
            if filename == old_filename and ext == old_ext and file_exists(file_path) then
                matches[#matches + 1] = file_path
            end
        end
    end

    if #matches == 0 and not candidate_files then
        local extensions = {[old_ext] = true}
        for _, search_path in ipairs(search_paths) do
            local files = scan_directory(search_path, extensions)
            for _, file_path in ipairs(files) do
                if get_filename(file_path) == old_filename and file_exists(file_path) then
                    matches[#matches + 1] = file_path
                end
            end
        end
    end

    -- Verify TC on each filename match
    for _, match_path in ipairs(matches) do
        if verify_candidate_tc(media, match_path) then
            return match_path
        end
    end

    if #matches > 0 then
        log.event("relink_by_filename: %d filename match(es) for '%s' but none passed TC verify",
            #matches, old_filename or "?")
    end

    return nil
end

--- Extract timecode from media metadata or filename
-- @param media table Media record
-- @param file_path string File path to extract from
-- @return string|nil Timecode string (HH:MM:SS:FF or similar)
local function extract_timecode(media, file_path)
    -- Check media metadata JSON for timecode field
    if media.metadata then
        local metadata = media.metadata
        if type(metadata) == "string" then
            -- Parse JSON if stored as string
            local json = require("dkjson")
            local parsed = json.decode(metadata)
            if parsed and parsed.timecode then
                return parsed.timecode
            end
        elseif type(metadata) == "table" and metadata.timecode then
            return metadata.timecode
        end
    end

    -- Try to extract from filename patterns
    -- Common patterns: A001C001_220830_R2EF.mov → timecode embedded
    -- BMPCC: BMPCC_A001_C001_220830.mov
    -- Sony: A001C001_220830_R2EF.mov (R2EF is reel)
    local filename = get_filename(file_path)

    -- Pattern 1: Standard timecode in filename (01:23:45:12)
    local tc = filename:match("(%d%d:%d%d:%d%d:%d%d)")
    if tc then return tc end

    -- Pattern 2: Compact format (01234512)
    local compact = filename:match("TC(%d%d%d%d%d%d%d%d)")
    if compact then
        -- Convert 01234512 → 01:23:45:12
        return string.format("%s:%s:%s:%s",
            compact:sub(1,2), compact:sub(3,4),
            compact:sub(5,6), compact:sub(7,8))
    end

    return nil
end

--- Extract reel name from media metadata or filename
-- @param media table Media record
-- @param file_path string File path to extract from
-- @return string|nil Reel name
local function extract_reel_name(media, file_path)
    -- Check media metadata for reel name
    if media.metadata then
        local metadata = media.metadata
        if type(metadata) == "string" then
            local json = require("dkjson")
            local parsed = json.decode(metadata)
            if parsed and parsed.reel_name then
                return parsed.reel_name
            end
        elseif type(metadata) == "table" and metadata.reel_name then
            return metadata.reel_name
        end
    end

    -- Try to extract from filename patterns
    local filename = get_filename(file_path)

    -- Pattern 1: Sony format with reel ID (A001C001_220830_R2EF.mov)
    local reel = filename:match("_([A-Z0-9]+)%.")
    if reel and #reel >= 3 and #reel <= 6 then
        return reel
    end

    -- Pattern 2: Explicit REEL_ prefix (REEL_A001_...)
    reel = filename:match("REEL_([A-Z0-9]+)")
    if reel then return reel end

    -- Pattern 3: Card/Magazine (CARD_001, MAG_A)
    reel = filename:match("CARD_([A-Z0-9]+)") or filename:match("MAG_([A-Z0-9]+)")
    if reel then return reel end

    return nil
end

--- Strategy 3: Metadata-based relinking with customizable matching criteria
-- Matches files by selected attributes with user-defined weights
-- @param media table Media record with metadata
-- @param search_paths table Array of directories to search
-- @param candidate_files table Pre-scanned file list (optional)
-- @param media_reader table MediaReader module
-- @param match_config table Configuration with weights for each attribute:
--   - use_duration: boolean (default true)
--   - use_resolution: boolean (default true)
--   - use_timecode: boolean (default false)
--   - use_reel_name: boolean (default false)
--   - use_filename: boolean (default false)
--   - weight_duration: number (default 0.3)
--   - weight_resolution: number (default 0.4)
--   - weight_timecode: number (default 0.2)
--   - weight_reel_name: number (default 0.1)
--   - weight_filename: number (default 0.0)
--   - duration_tolerance: number (default 0.05 = ±5%)
--   - min_score: number (minimum confidence 0-1, default 0.85)
-- @return string|nil New absolute path if found, nil otherwise
-- @return number|nil Confidence score (0-1)
-- @return table|nil Match details {attribute_scores = {...}}
local function relink_by_metadata(media, search_paths, candidate_files, media_reader, match_config)
    if not media_reader then
        return nil, 0, nil
    end

    -- Default configuration
    match_config = match_config or {}
    local config = {
        use_duration = match_config.use_duration ~= false,  -- Default true
        use_resolution = match_config.use_resolution ~= false,
        use_timecode = match_config.use_timecode or false,
        use_reel_name = match_config.use_reel_name or false,
        use_filename = match_config.use_filename or false,
        weight_duration = match_config.weight_duration or 0.3,
        weight_resolution = match_config.weight_resolution or 0.4,
        weight_timecode = match_config.weight_timecode or 0.2,
        weight_reel_name = match_config.weight_reel_name or 0.1,
        weight_filename = match_config.weight_filename or 0.0,
        duration_tolerance = match_config.duration_tolerance or 0.05,
        min_score = match_config.min_score or 0.85
    }

    local old_duration = media.duration
    local old_width = media.width
    local old_height = media.height
    local old_ext = get_extension(media.file_path)
    local old_timecode = extract_timecode(media, media.file_path)
    local old_reel = extract_reel_name(media, media.file_path)
    local old_filename = get_filename(media.file_path)

    local best_match = nil
    local best_score = 0.0
    local best_details = nil

    -- Get candidate files
    local files_to_check = candidate_files or {}
    if not candidate_files then
        local extensions = {[old_ext] = true}
        for _, search_path in ipairs(search_paths) do
            local files = scan_directory(search_path, extensions)
            for _, file_path in ipairs(files) do
                table.insert(files_to_check, file_path)
            end
        end
    end

    -- Check each candidate
    for _, file_path in ipairs(files_to_check) do
        if file_exists(file_path) then
            local new_metadata = media_reader.probe_file(file_path)

            -- Create temporary media record for extraction functions
            local temp_media = {
                file_path = file_path,
                metadata = nil
            }

            if new_metadata then
                local attribute_scores = {}
                local total_weight = 0.0
                local weighted_sum = 0.0

                -- Duration matching
                if config.use_duration and new_metadata.duration_ms then
                    local new_duration = new_metadata.duration_ms
                    local duration_match = 1.0

                    if old_duration > 0 and new_duration > 0 then
                        local duration_diff = math.abs(old_duration - new_duration) / old_duration
                        duration_match = math.max(0, 1.0 - (duration_diff / config.duration_tolerance))
                    end

                    attribute_scores.duration = duration_match
                    weighted_sum = weighted_sum + (duration_match * config.weight_duration)
                    total_weight = total_weight + config.weight_duration
                end

                -- Resolution matching
                if config.use_resolution and new_metadata.video then
                    local new_width = new_metadata.video.width
                    local new_height = new_metadata.video.height
                    local resolution_match = (old_width == new_width and old_height == new_height) and 1.0 or 0.0

                    attribute_scores.resolution = resolution_match
                    weighted_sum = weighted_sum + (resolution_match * config.weight_resolution)
                    total_weight = total_weight + config.weight_resolution
                end

                -- Timecode matching
                if config.use_timecode and old_timecode then
                    local new_timecode = extract_timecode(temp_media, file_path)
                    local timecode_match = 0.0

                    if new_timecode and old_timecode == new_timecode then
                        timecode_match = 1.0
                    elseif new_timecode then
                        -- Fuzzy match: allow small differences (1-2 frames)
                        timecode_match = string_similarity(old_timecode, new_timecode)
                    end

                    attribute_scores.timecode = timecode_match
                    weighted_sum = weighted_sum + (timecode_match * config.weight_timecode)
                    total_weight = total_weight + config.weight_timecode
                end

                -- Reel name matching
                if config.use_reel_name and old_reel then
                    local new_reel = extract_reel_name(temp_media, file_path)
                    local reel_match = 0.0

                    if new_reel and old_reel:lower() == new_reel:lower() then
                        reel_match = 1.0
                    end

                    attribute_scores.reel_name = reel_match
                    weighted_sum = weighted_sum + (reel_match * config.weight_reel_name)
                    total_weight = total_weight + config.weight_reel_name
                end

                -- Filename similarity matching
                if config.use_filename then
                    local new_filename = get_filename(file_path)
                    local filename_match = string_similarity(old_filename, new_filename)

                    attribute_scores.filename = filename_match
                    weighted_sum = weighted_sum + (filename_match * config.weight_filename)
                    total_weight = total_weight + config.weight_filename
                end

                -- Calculate final score
                local score = total_weight > 0 and (weighted_sum / total_weight) or 0.0

                if score > best_score and score >= config.min_score then
                    best_score = score
                    best_match = file_path
                    best_details = {
                        attribute_scores = attribute_scores,
                        config = config
                    }
                end
            end
        end
    end

    return best_match, best_score, best_details
end

--- Find offline media in project
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
    stmt:bind_value(1, project_id)
    if stmt:exec() then
        while stmt:next() do
            local media_id = stmt:value(0)
            local media = Media.load(media_id)
            if media and not file_exists(media.file_path) then
                table.insert(offline, media)
            end
        end
    end

    stmt:finalize()
    return offline
end

--- Attempt to relink a single media file
-- Tries all three strategies in order: path, filename, metadata
-- @param media table Media record
-- @param options table Relinking options
--   - search_paths: array of directories to search
--   - new_root: new root directory for path-based relinking
--   - candidate_files: pre-scanned file list (optional)
--   - media_reader: MediaReader module for metadata matching (optional)
-- @return string|nil New file path if found
-- @return string Strategy used ("path", "filename", "metadata")
-- @return number|nil Confidence score (for metadata strategy)
function M.relink_media(media, options)
    options = options or {}
    log.event("relink_media: trying '%s' (file_path=%s)",
        media.name or media.id or "?", media.file_path or "?")

    -- Strategy 1: Path-based (fastest, most reliable)
    if options.new_root then
        local new_path = relink_by_path(media, options.new_root)
        if new_path then
            return new_path, "path", 1.0
        end
    end

    -- Strategy 2: Filename-based (medium speed, good reliability)
    if options.search_paths then
        ensure_candidate_cache(options, {[get_extension(media.file_path)] = true})
        local new_path = relink_by_filename(
            media, options.search_paths, options.candidate_files, options.candidate_index)
        if new_path then
            return new_path, "filename", 0.95
        end
    end

    -- Strategy 3: Metadata-based (slowest, handles renames)
    if options.media_reader and options.search_paths then
        local new_path, confidence = relink_by_metadata(
            media, options.search_paths, options.candidate_files, options.media_reader)
        if new_path then
            return new_path, "metadata", confidence
        end
    end

    return nil, "none", 0.0
end

--- Batch relink multiple media files
-- @param media_list table Array of media records
-- @param options table Relinking options (see relink_media)
-- @param progress_cb function|nil: progress_cb(pct, status_text, log_line)
-- @return table Results {relinked = {{media, new_path, strategy, confidence}}, failed = {media}}
function M.batch_relink(media_list, options, progress_cb)
    local results = {
        relinked = {},
        failed = {}
    }
    local total = #media_list

    -- Pre-scan directories once per extension set
    if options.search_paths and total > 0 then
        if progress_cb then progress_cb(0, "Scanning search directory...") end
        local extensions = {}
        for _, media in ipairs(media_list) do
            local ext = get_extension(media.file_path)
            if ext and ext ~= "" then
                extensions[ext] = true
            end
        end
        ensure_candidate_cache(options, extensions)
    end

    -- Track claimed paths to prevent two media records mapping to the same file
    local claimed_paths = {}

    -- Attempt relinking for each media file
    for i, media in ipairs(media_list) do
        local name = media.name or media.id or "?"
        local new_path, strategy, confidence = M.relink_media(media, options)

        if new_path and not claimed_paths[new_path] then
            claimed_paths[new_path] = media.id
            table.insert(results.relinked, {
                media = media,
                new_path = new_path,
                strategy = strategy,
                confidence = confidence
            })
            if progress_cb then
                local pct = math.floor(i / total * 100)
                progress_cb(pct,
                    string.format("Verifying %d of %d...", i, total),
                    string.format("[OK] %s → %s", name, get_filename(new_path)))
            end
        elseif new_path then
            log.warn("batch_relink: path already claimed by %s, skipping %s → %s",
                claimed_paths[new_path], name, new_path)
            table.insert(results.failed, media)
            if progress_cb then
                local pct = math.floor(i / total * 100)
                progress_cb(pct, nil,
                    string.format("[DUP] %s (already claimed)", name))
            end
        else
            table.insert(results.failed, media)
            if progress_cb then
                local pct = math.floor(i / total * 100)
                progress_cb(pct, nil,
                    string.format("[--] %s", name))
            end
        end
    end

    if progress_cb then
        progress_cb(100, string.format("Done: %d of %d reconnected",
            #results.relinked, total))
    end

    return results
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

    -- Collect all basenames
    local all_basenames = {}
    for basename in pairs(candidate_index) do
        all_basenames[#all_basenames + 1] = basename
    end

    -- For each candidate basename, check if it's a segment of any other basename
    for _, cand_basename in ipairs(all_basenames) do
        for _, orig_basename in ipairs(all_basenames) do
            if cand_basename ~= orig_basename and M.match_segment_filename(orig_basename, cand_basename) then
                seg_index[orig_basename] = seg_index[orig_basename] or {}
                -- Add all paths from the candidate's bucket
                for _, path in ipairs(candidate_index[cand_basename]) do
                    seg_index[orig_basename][#seg_index[orig_basename] + 1] = path
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
                            local abs_start = stored_value + clip_info.source_in
                            local abs_end = stored_value + clip_info.source_out

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

        -- Resolution matching
        if passed and matching_rules.match_resolution then
            local media_info = probe_media_fn(cand_path)
            if media_info then
                if media_info.width ~= clip_info.width or media_info.height ~= clip_info.height then
                    passed = false
                end
            end
            -- If no media_info available, can't verify → skip this check
        end

        -- Frame rate matching
        if passed and matching_rules.match_frame_rate then
            local media_info = probe_media_fn(cand_path)
            if media_info and media_info.fps_num and media_info.fps_den then
                if media_info.fps_num ~= clip_info.fps_num or media_info.fps_den ~= clip_info.fps_den then
                    passed = false
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

    -- Step 1: Scan search directories and build candidate index
    if progress_cb then progress_cb(0, "Scanning search directory...") end

    -- Collect all extensions from clips
    local extensions = {}
    for _, clip_info in ipairs(clips) do
        local ext = clip_info.media_path and clip_info.media_path:match("%.([^%.]+)$")
        if ext then extensions[ext:lower()] = true end
    end

    local _candidate_files, candidate_index = build_candidate_cache(options.search_paths, extensions)

    -- Build segment index if enabled
    local segment_index
    if matching_rules.accept_filename_suffixes then
        segment_index = M.build_segment_index(candidate_index)
    end

    -- Step 2: Process each clip
    for i, clip_info in ipairs(clips) do
        local clip_name = clip_info.clip_name or clip_info.clip_id:sub(1, 8)

        -- Find candidates using the pure algorithm function
        local candidates = M.find_candidates_for_clip(
            clip_info, candidate_index, matching_rules,
            probe_start_tc,  -- real ffprobe function
            function(path)   -- probe_media_fn wrapping ffprobe
                local escaped = string.format('"%s"', path:gsub('"', '\\"'))
                local cmd = string.format(
                    'ffprobe -v error -print_format json -show_streams %s 2>/dev/null', escaped)
                local handle = io.popen(cmd)
                if not handle then return nil end
                local output = handle:read("*a")
                handle:close()
                if not output or output == "" then return nil end
                local json = require("dkjson")
                local data = json.decode(output)
                if not data or not data.streams then return nil end
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
                    end
                end
                return info.width and info or nil
            end
        )

        -- Also check segment files if enabled
        if matching_rules.accept_filename_suffixes and segment_index then
            local basename = get_filename(clip_info.media_path)
            local seg_key = basename and basename:lower() or nil
            if seg_key and segment_index[seg_key] then
                for _, seg_path in ipairs(segment_index[seg_key]) do
                    -- Check if this segment is already in candidates
                    local already = false
                    for _, c in ipairs(candidates) do
                        if c.path == seg_path then already = true; break end
                    end
                    if not already then
                        local seg_tc_val, seg_tc_rate = probe_start_tc(seg_path)
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

    return results
end

return M
