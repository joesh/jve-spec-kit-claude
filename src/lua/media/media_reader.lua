--- Media File Reader - FFprobe Integration
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
                    -- r_frame_rate can be "0/0" for audio streams — frame_rate=0 is valid there
                    -- (audio streams don't have a meaningful frame rate)
                    stream.frame_rate = tonumber(stream.r_frame_rate) or 0
                end
            end
        end
    end

    return data, nil
end

--- Extract rotation from video stream
-- FFprobe stores rotation in side_data_list (displaymatrix) or stream tags
-- @param stream table Video stream data from FFprobe
-- @return number Rotation in degrees (0, 90, 180, 270)
local function extract_rotation(stream)
    -- Check side_data_list for displaymatrix
    if stream.side_data_list then
        for _, sd in ipairs(stream.side_data_list) do
            if sd.side_data_type == "Display Matrix" and sd.rotation then
                local rot = tonumber(sd.rotation) or 0
                -- Normalize to 0, 90, 180, 270
                rot = math.floor(rot + 0.5)
                while rot < 0 do rot = rot + 360 end
                rot = rot % 360
                return ((rot + 45) / 90) * 90 % 360
            end
        end
    end
    -- Check stream tags for rotation
    if stream.tags and stream.tags.rotate then
        local rot = tonumber(stream.tags.rotate) or 0
        rot = math.floor(rot + 0.5)
        while rot < 0 do rot = rot + 360 end
        rot = rot % 360
        return ((rot + 45) / 90) * 90 % 360
    end
    return 0
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

--- Find every audio stream in probe data, in container order.
-- The flat-channel abstraction JVE deals in is "channel of file", not
-- "channel of stream" — containers like broadcast MXF split each channel
-- into its own mono PCM stream and a "first audio stream wins" walk
-- would silently drop 7 of 8 tracks. Sum across every entry to get the
-- flat channel count; use entry [1] as the primary for sample_rate /
-- codec / TC extraction (broadcast MXF shares those across streams).
-- @param probe_data table FFprobe output data
-- @return table Array of audio stream tables (empty if no audio)
local function find_all_audio_streams(probe_data)
    local out = {}
    for _, stream in ipairs(probe_data.streams) do
        if stream.codec_type == "audio" then
            out[#out + 1] = stream
        end
    end
    return out
end

-- ============================================================================
-- Public API
-- ============================================================================

local function find_media_id_by_path(db, file_path)
    assert(db, "find_media_id_by_path: db is nil")
    assert(file_path and file_path ~= "", "find_media_id_by_path: file_path required")

    -- db.prepare may not exist when called with a mock (e.g. media_reader tests)
    if type(db.prepare) ~= "function" then
        return nil
    end

    local stmt = assert(db:prepare("SELECT id FROM media WHERE file_path = ?"),
        "find_media_id_by_path: failed to prepare query")

    stmt:bind_value(1, file_path)

    local media_id = nil
    if stmt:exec() and stmt:next() then
        media_id = stmt:value(0)
    end

    stmt:finalize()

    return media_id  -- nil = "not found" (distinct from SQL error, which asserts above)
end

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
    local audio_streams = find_all_audio_streams(probe_data)
    local audio_stream = audio_streams[1]  -- primary: TC / rate / codec source

    -- Build metadata structure
    local metadata = {
        file_path = file_path,
        duration_ms = math.floor(probe_data.format.duration * 1000),
        has_video = video_stream ~= nil,
        has_audio = audio_stream ~= nil
    }

    if video_stream then
        assert(video_stream.width and video_stream.width > 0,
            string.format("probe_file: video stream has no width for %s", file_path))
        assert(video_stream.height and video_stream.height > 0,
            string.format("probe_file: video stream has no height for %s", file_path))
        assert(video_stream.frame_rate and video_stream.frame_rate > 0,
            string.format("probe_file: video stream has no frame_rate for %s", file_path))
        assert(video_stream.codec_name,
            string.format("probe_file: video stream has no codec_name for %s", file_path))
        metadata.video = {
            width = video_stream.width,
            height = video_stream.height,
            frame_rate = video_stream.frame_rate,
            codec = video_stream.codec_name,
            rotation = extract_rotation(video_stream)
        }
    end

    if audio_stream then
        -- Flat channel count = SUM across every container audio stream,
        -- mirroring the C++ EMP probe in emp_media_file.cpp. Broadcast MXF
        -- splits each track into its own mono PCM stream; a "first stream
        -- wins" walk imports an 8-track file as 1 channel and the other
        -- 7 are silently dropped. master_builder fans out one track per
        -- source_channel ∈ [0, channels), Reader resolves each flat index
        -- back to (av_stream_idx, channel_within_stream). Primary stream
        -- supplies sample_rate / codec; all streams must agree on
        -- sample_rate (one resampler keyed on one rate downstream).
        local primary_sr = tonumber(audio_stream.sample_rate)
        assert(primary_sr and primary_sr > 0,
            string.format("probe_file: audio stream has no sample_rate for %s", file_path))
        assert(audio_stream.codec_name,
            string.format("probe_file: audio stream has no codec_name for %s", file_path))
        local total_channels = 0
        for i, s in ipairs(audio_streams) do
            local ch = tonumber(s.channels)
            assert(ch and ch > 0, string.format(
                "probe_file: audio stream %d has no channels for %s", i, file_path))
            local sr = tonumber(s.sample_rate)
            assert(sr and sr == primary_sr, string.format(
                "probe_file: audio stream %d sample_rate %s ≠ primary %d for %s",
                i, tostring(sr), primary_sr, file_path))
            total_channels = total_channels + ch
        end
        metadata.audio = {
            channels = total_channels,
            sample_rate = primary_sr,
            codec = audio_stream.codec_name,
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

    -- Reuse existing media row when file_path is already present.
    local existing_id = find_media_id_by_path(db, file_path)
    local media_id = existing_id or existing_media_id or uuid.generate_with_prefix("media")

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
    -- Convert duration from ms to native units at the I/O boundary
    local fps = metadata.video and metadata.video.frame_rate
    local duration_frames
    if fps and fps > 0 then
        -- Video: duration in video frames
        duration_frames = math.floor(metadata.duration_ms / 1000.0 * fps + 0.5)
    else
        -- Audio-only: duration in audio samples
        assert(metadata.audio and metadata.audio.sample_rate and metadata.audio.sample_rate > 0,
            string.format("import_media: no video fps and no audio sample_rate for %s", file_path))
        fps = metadata.audio.sample_rate
        duration_frames = math.floor(metadata.duration_ms / 1000.0 * fps + 0.5)
    end

    local Media = require("models.media")
    local media_width = metadata.video and metadata.video.width or 0
    local audio_channels = metadata.audio and metadata.audio.channels or 0
    local audio_sample_rate = metadata.audio and tonumber(metadata.audio.sample_rate) or nil
    assert(audio_channels == 0 or (audio_sample_rate and audio_sample_rate > 0),
        string.format(
            "import_media: probed audio channels=%d but no sample_rate for %s",
            audio_channels, file_path))
    local media = Media.create({
        id = media_id,
        project_id = project_id,
        name = filename,
        file_path = file_path,
        duration_frames = duration_frames,
        frame_rate = fps,
        width = media_width,
        height = metadata.video and metadata.video.height or 0,
        rotation = metadata.video and metadata.video.rotation or 0,
        audio_channels = audio_channels,
        audio_sample_rate = audio_sample_rate,
        codec = primary_codec,
        is_still = Media.classify_is_still(primary_codec, media_width, duration_frames),
        created_at = os.time(),
        modified_at = os.time()
    })

    if not media then
        return nil, nil, "Failed to create Media record"
    end

    -- Extract TC origin from the file via EMP.
    -- File is guaranteed to exist (we just probed it).
    -- This sets start_tc_value/start_tc_rate in metadata so ensure_master
    -- gets the real TC, not a fabricated 0.
    -- In the running app, EMP is always available. In unit tests without EMP,
    -- _ensure_tc_extracted() will lazily extract when the file is first accessed.
    if qt_constants and qt_constants.EMP then
        media:extract_tc_from_file()
    end

    -- Save to database (includes TC metadata)
    if not media:save() then
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
