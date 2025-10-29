-- Media File Reader - FFprobe Integration
-- Extracts metadata from video/audio files for timeline editing
-- Uses FFprobe (part of FFmpeg suite) for cross-platform media inspection

local M = {}

-- Load JSON library (dkjson - pure Lua, no C dependencies)
local json = require("dkjson")
local uuid = require("uuid")

-- ============================================================================
-- FFprobe Integration
-- ============================================================================

--- Execute ffprobe and parse JSON output
-- @param file_path string Absolute path to media file
-- @return table|nil Parsed data from ffprobe, or nil on error
-- @return string|nil Error message if probe failed
--
-- Architecture: Uses proper JSON parsing instead of fragile pattern matching
-- - FFprobe's JSON output is the canonical, stable format
-- - dkjson library handles all edge cases (escaping, Unicode, nested structures)
-- - No manual parser maintenance required
-- - Extensible: easy to add new metadata fields without parser changes
local function run_ffprobe(file_path)
    -- Escape file path for shell (handle spaces, special chars)
    local escaped_path = string.format('"%s"', file_path:gsub('"', '\\"'))

    -- FFprobe command with JSON output (canonical format)
    -- -v error: Only show errors (suppress banner)
    -- -print_format json: Machine-readable structured output
    -- -show_format: Container-level metadata (duration, bitrate, size)
    -- -show_streams: Per-stream metadata (codec, dimensions, fps, channels)
    local cmd = string.format(
        'ffprobe -v error -print_format json -show_format -show_streams %s 2>&1',
        escaped_path
    )

    local handle = io.popen(cmd)
    if not handle then
        return nil, "Failed to execute ffprobe command"
    end

    local output = handle:read("*a")
    local success = handle:close()

    if not success or output == "" then
        return nil, "FFprobe execution failed - file may not exist or be readable"
    end

    -- Parse JSON using dkjson library
    local data, parse_err = json.decode(output)
    if not data then
        return nil, "Failed to parse FFprobe JSON output: " .. (parse_err or "unknown error")
    end

    -- Validate expected structure
    if not data.format or not data.format.duration then
        return nil, "Invalid FFprobe output - missing required fields"
    end

    -- Post-process: parse rational frame rates (stored as strings like "30/1")
    if data.streams then
        for _, stream in ipairs(data.streams) do
            if stream.r_frame_rate then
                local num, den = stream.r_frame_rate:match("(%d+)/(%d+)")
                if num and den and tonumber(den) ~= 0 then
                    stream.frame_rate = tonumber(num) / tonumber(den)
                else
                    stream.frame_rate = tonumber(stream.r_frame_rate) or 0
                end
            end
        end
    end

    return data, nil
end

--- Find first video stream in probe data
-- @param probe_data table FFprobe output data
-- @return table|nil Video stream data, or nil if no video found
local function find_video_stream(probe_data)
    for _, stream in ipairs(probe_data.streams) do
        if stream.codec_type == "video" then
            return stream
        end
    end
    return nil
end

--- Find first audio stream in probe data
-- @param probe_data table FFprobe output data
-- @return table|nil Audio stream data, or nil if no audio found
local function find_audio_stream(probe_data)
    for _, stream in ipairs(probe_data.streams) do
        if stream.codec_type == "audio" then
            return stream
        end
    end
    return nil
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Probe media file and extract metadata
-- @param file_path string Absolute path to media file
-- @return table|nil Media metadata table, or nil on error
-- @return string|nil Error message if probe failed
--
-- Returned metadata table structure:
-- {
--   file_path = "/path/to/video.mp4",
--   duration_ms = 120000,        -- Duration in milliseconds
--   has_video = true,
--   has_audio = true,
--   video = {
--     width = 1920,
--     height = 1080,
--     frame_rate = 29.97,
--     codec = "h264"
--   },
--   audio = {
--     channels = 2,
--     sample_rate = 48000,
--     codec = "aac"
--   }
-- }
function M.probe_file(file_path)
    -- Validate input
    if not file_path or file_path == "" then
        return nil, "File path cannot be empty"
    end

    -- Run ffprobe
    local probe_data, err = run_ffprobe(file_path)
    if not probe_data then
        return nil, err
    end

    -- Extract video stream info
    local video_stream = find_video_stream(probe_data)
    local audio_stream = find_audio_stream(probe_data)

    -- Build metadata structure
    local metadata = {
        file_path = file_path,
        duration_ms = math.floor((probe_data.format.duration or 0) * 1000),
        has_video = video_stream ~= nil,
        has_audio = audio_stream ~= nil
    }

    if video_stream then
        metadata.video = {
            width = video_stream.width or 0,
            height = video_stream.height or 0,
            frame_rate = video_stream.frame_rate or 0,
            codec = video_stream.codec_name or "unknown"
        }
    end

    if audio_stream then
        metadata.audio = {
            channels = audio_stream.channels or 0,
            sample_rate = audio_stream.sample_rate or 0,
            codec = audio_stream.codec_name or "unknown"
        }
    end

    return metadata, nil
end

--- Import media file into project database
-- Creates Media record with extracted metadata
-- @param file_path string Absolute path to media file
-- @param db table Database connection
-- @param project_id string Project ID for media ownership
-- @param existing_media_id string|nil Optional media ID to reuse (for deterministic replays)
-- @return string|nil Media ID if successful, nil on error
-- @return string|nil Error message if import failed
function M.import_media(file_path, db, project_id, existing_media_id)
    -- Probe file first
    local metadata, err = M.probe_file(file_path)
    if not metadata then
        return nil, nil, "Failed to probe media file: " .. (err or "unknown error")
    end

    -- Generate media ID
    local media_id = existing_media_id or uuid.generate_with_prefix("media")

    -- Extract filename from path
    local filename = file_path:match("([^/\\]+)$") or file_path

    -- Determine primary codec (video codec if present, otherwise audio codec)
    local primary_codec = ""
    if metadata.video and metadata.video.codec then
        primary_codec = metadata.video.codec
    elseif metadata.audio and metadata.audio.codec then
        primary_codec = metadata.audio.codec
    end

    -- Create Media record
    local Media = require("models.media")
    local media = Media.create({
        id = media_id,
        project_id = project_id,
        name = filename,
        file_path = file_path,
        duration = metadata.duration_ms,
        frame_rate = metadata.video and metadata.video.frame_rate or 0,
        width = metadata.video and metadata.video.width or 0,
        height = metadata.video and metadata.video.height or 0,
        audio_channels = metadata.audio and metadata.audio.channels or 0,
        codec = primary_codec,
        created_at = os.time(),
        modified_at = os.time()
    })

    if not media then
        return nil, nil, "Failed to create Media record"
    end

    -- Save to database
    if not media:save(db) then
        return nil, nil, "Failed to save Media record to database"
    end

    return media_id, metadata, nil
end

--- Batch import multiple media files
-- @param file_paths table Array of absolute file paths
-- @param db table Database connection
-- @param project_id string Project ID for media ownership
-- @return table Results table with {success = {media_ids}, failed = {errors}}
function M.batch_import_media(file_paths, db, project_id)
    local results = {
        success = {},
        failed = {}
    }

    for _, file_path in ipairs(file_paths) do
        local media_id, _, err = M.import_media(file_path, db, project_id, nil)
        if media_id then
            table.insert(results.success, {
                file_path = file_path,
                media_id = media_id
            })
        else
            table.insert(results.failed, {
                file_path = file_path,
                error = err
            })
        end
    end

    return results
end

return M
