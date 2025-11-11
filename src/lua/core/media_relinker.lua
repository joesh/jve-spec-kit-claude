-- Media Relinking System
-- Reconnects offline media files to clips after files have been moved/renamed
-- Supports three strategies: path-based, filename-based, metadata-based
--
-- Architecture: Command-based relinking for full undo/redo support
-- All relinking operations create ReinkMedia commands that can be undone

local M = {}

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
local function normalize_path(path)
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
-- @param max_depth number Maximum recursion depth (default 10)
-- @return table Array of absolute file paths
local function scan_directory(root_dir, extensions, max_depth)
    max_depth = max_depth or 10
    local results = {}

    -- Use find command for efficiency (Lua's directory traversal is slow)
    local ext_pattern = ""
    local ext_list = {}
    for ext, _ in pairs(extensions) do
        table.insert(ext_list, string.format("-name '*.%s'", ext))
    end
    ext_pattern = table.concat(ext_list, " -o ")

    local cmd = string.format('find "%s" -maxdepth %d -type f \\( %s \\) 2>/dev/null',
        root_dir, max_depth, ext_pattern)

    local handle = io.popen(cmd)
    if handle then
        for line in handle:lines() do
            if line and line ~= "" then
                table.insert(results, line)
            end
        end
        handle:close()
    end

    return results
end

local function build_candidate_cache(search_paths, extensions, max_depth)
    local candidate_files = {}
    local candidate_index = {}

    if not search_paths or not extensions or next(extensions) == nil then
        return candidate_files, candidate_index
    end

    for _, search_path in ipairs(search_paths) do
        local files = scan_directory(search_path, extensions, max_depth)
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

    local files, index = build_candidate_cache(options.search_paths, pending, options.max_scan_depth or 5)
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

--- Strategy 2: Filename-based relinking
-- Searches directory tree for matching filename
-- @param media table Media record with old file_path
-- @param search_paths table Array of directories to search
-- @param candidate_files table Pre-scanned file list (optional)
-- @return string|nil New absolute path if found, nil otherwise
local function relink_by_filename(media, search_paths, candidate_files, candidate_index)
    local old_filename = get_filename(media.file_path)
    local old_ext = get_extension(media.file_path)
    local lookup_key = old_filename and old_filename:lower() or nil

    if candidate_index and lookup_key and candidate_index[lookup_key] then
        for _, file_path in ipairs(candidate_index[lookup_key]) do
            local ext = get_extension(file_path)
            if ext == old_ext and file_exists(file_path) then
                return file_path
            end
        end
    end

    -- If candidate files provided, search them
    if candidate_files then
        for _, file_path in ipairs(candidate_files) do
            local filename = get_filename(file_path)
            local ext = get_extension(file_path)

            if filename == old_filename and ext == old_ext then
                if file_exists(file_path) then
                    return file_path
                end
            end
        end
    else
        -- Scan directories
        local extensions = {[old_ext] = true}

        for _, search_path in ipairs(search_paths) do
            local files = scan_directory(search_path, extensions, 5)
            for _, file_path in ipairs(files) do
                local filename = get_filename(file_path)
                if filename == old_filename then
                    if file_exists(file_path) then
                        return file_path
                    end
                end
            end
        end
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
            local parsed, err = json.decode(metadata)
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
            local parsed, err = json.decode(metadata)
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
            local files = scan_directory(search_path, extensions, 5)
            for _, file_path in ipairs(files) do
                table.insert(files_to_check, file_path)
            end
        end
    end

    -- Check each candidate
    for _, file_path in ipairs(files_to_check) do
        if file_exists(file_path) then
            local new_metadata, err = media_reader.probe_file(file_path)

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

    stmt:bind_values(project_id)

    local offline = {}
    for row in stmt:nrows() do
        local media = Media.load(row.id, db)
        if media and not file_exists(media.file_path) then
            table.insert(offline, media)
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
-- @return table Results {relinked = {{media, new_path, strategy, confidence}}, failed = {media}}
function M.batch_relink(media_list, options)
    local results = {
        relinked = {},
        failed = {}
    }

    -- Pre-scan directories once per extension set
    if options.search_paths and #media_list > 0 then
        local extensions = {}
        for _, media in ipairs(media_list) do
            local ext = get_extension(media.file_path)
            if ext and ext ~= "" then
                extensions[ext] = true
            end
        end
        ensure_candidate_cache(options, extensions)
    end

    -- Attempt relinking for each media file
    for _, media in ipairs(media_list) do
        local new_path, strategy, confidence = M.relink_media(media, options)

        if new_path then
            table.insert(results.relinked, {
                media = media,
                new_path = new_path,
                strategy = strategy,
                confidence = confidence
            })
        else
            table.insert(results.failed, media)
        end
    end

    return results
end

return M
