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

--- Convert TC string "HH:MM:SS:FF" to seconds since midnight.
-- @param tc string Timecode like "00:40:33:02"
-- @param fps number Frames per second (integer)
-- @return number|nil Seconds since midnight
local function tc_to_seconds(tc, fps)
    if not tc or not fps or fps <= 0 then return nil end
    local h, m, s, f = tc:match("(%d+):(%d+):(%d+):(%d+)")
    if not h then return nil end
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) + tonumber(f) / fps
end

--- Extract start TC from a candidate file via ffprobe.
-- @param file_path string
-- @return string|nil TC string "HH:MM:SS:FF"
-- @return number|nil fps (integer)
local function probe_start_tc(file_path)
    local escaped = string.format('"%s"', file_path:gsub('"', '\\"'))
    local cmd = string.format(
        'ffprobe -v error -print_format json -show_format -show_streams %s 2>/dev/null',
        escaped)
    local handle = io.popen(cmd)
    if not handle then return nil end
    local output = handle:read("*a")
    handle:close()
    if not output or output == "" then return nil end

    local json = require("dkjson")
    local data = json.decode(output)
    if not data then return nil end

    -- Find TC in format tags or stream tags
    local tc = nil
    if data.format and data.format.tags then
        tc = data.format.tags.timecode or data.format.tags.TIMECODE
    end
    if not tc and data.streams then
        for _, stream in ipairs(data.streams) do
            if stream.tags then
                tc = stream.tags.timecode or stream.tags.TIMECODE
                if tc then break end
            end
        end
    end

    -- Get fps from video stream
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

    return tc, fps
end

--- Get the media record's stored start TC (seconds since midnight).
-- @param media table Media record
-- @return number|nil seconds since midnight, or nil if not stored
local function get_stored_start_tc(media)
    if not media.metadata or media.metadata == "" or media.metadata == "{}" then
        return nil
    end
    local meta = media.metadata
    if type(meta) == "string" then
        local json = require("dkjson")
        meta = json.decode(meta)
    end
    if type(meta) == "table" then
        return meta.start_tc
    end
    return nil
end

--- Verify candidate file's start TC matches the media record's stored TC.
-- Rejects media-managed copies with different TC origins (would destroy the edit).
-- Files without TC (audio, stills) or media without stored TC accepted on filename.
-- @param media table Media record (with metadata.start_tc)
-- @param candidate_path string
-- @return boolean true if TC matches or check not applicable
local function verify_candidate_tc(media, candidate_path)
    local stored_tc = get_stored_start_tc(media)
    if not stored_tc then
        -- No stored TC (pre-fix import or native import) — accept on filename
        return true
    end

    local cand_tc_str, cand_fps = probe_start_tc(candidate_path)
    if not cand_tc_str then
        -- No TC in candidate (audio, still) — accept on filename
        return true
    end
    if not cand_fps then
        return true  -- can't convert TC without fps
    end

    local cand_tc = tc_to_seconds(cand_tc_str, cand_fps)
    if not cand_tc then
        return true  -- can't parse TC string
    end

    -- Compare: allow ±1 frame tolerance (rounding between float seconds and TC)
    local tolerance = 1.0 / cand_fps
    if math.abs(cand_tc - stored_tc) <= tolerance then
        log.event("verify_tc: match %s TC=%s (%.2fs ≈ stored %.2fs)",
            get_filename(candidate_path), cand_tc_str, cand_tc, stored_tc)
        return true
    end

    log.warn("verify_tc: REJECTED %s — TC=%s (%.2fs) != stored %.2fs (media-managed copy?)",
        get_filename(candidate_path), cand_tc_str, cand_tc, stored_tc)
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

return M
