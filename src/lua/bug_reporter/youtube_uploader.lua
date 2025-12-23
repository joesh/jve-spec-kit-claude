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
-- Size: ~210 LOC
-- Volatility: unknown
--
-- @file youtube_uploader.lua
-- Original intent (unreviewed):
-- youtube_uploader.lua
-- Upload bug report slideshow videos to YouTube (unlisted)
local dkjson = require("dkjson")
local youtube_oauth = require("bug_reporter.youtube_oauth")
local utils = require("bug_reporter.utils")
local uuid = require("uuid")

local YouTubeUploader = {}

-- YouTube Data API v3 endpoint
local YOUTUBE_API = "https://www.googleapis.com/upload/youtube/v3/videos"

--- Upload video to YouTube using YouTube Data API v3
-- Uploads a video file to YouTube as an unlisted video. Requires OAuth2 authentication
-- via youtube_oauth.get_access_token(). The video is uploaded using multipart upload.
--
-- @param video_path string Path to video file (must be MP4 format and must exist on disk)
-- @param metadata table Optional metadata {
--   title: string - Video title (defaults to "JVE Bug Report"),
--   description: string - Video description (defaults to generated text),
--   tags: array - Array of tag strings (defaults to {"jve", "bug-report", "video-editor"}),
--   privacy: string - Privacy status: "unlisted", "private", or "public" (defaults to "unlisted")
-- }
-- @return table|nil Success: {video_id: string, url: string}
-- @return nil, string Failure: nil + error message
-- @usage
--   local result, err = YouTubeUploader.upload_video("/path/to/video.mp4", {
--     title = "My Bug Report",
--     description = "This video shows the bug I encountered",
--     tags = {"bug", "video-editor"}
--   })
--   if result then
--     print("Uploaded: " .. result.url)
--   else
--     print("Error: " .. err)
--   end
function YouTubeUploader.upload_video(video_path, metadata)
    -- Validate parameters
    local valid, err = utils.validate_non_empty(video_path, "video_path")
    if not valid then
        return nil, err
    end

    if not utils.file_exists(video_path) then
        return nil, "Video file not found: " .. video_path
    end

    metadata = metadata or {}

    -- Get access token
    local access_token, err = youtube_oauth.get_access_token()
    if not access_token then
        return nil, err
    end

    -- Prepare metadata
    local video_metadata = {
        snippet = {
            title = metadata.title or "JVE Bug Report",
            description = metadata.description or "Automatically generated bug report from JVE",
            tags = metadata.tags or {"jve", "bug-report", "video-editor"},
            categoryId = "28"  -- Science & Technology
        },
        status = {
            privacyStatus = "unlisted",  -- Unlisted by default
            selfDeclaredMadeForKids = false
        }
    }

    local metadata_json = dkjson.encode(video_metadata)

    -- Create multipart upload
    -- YouTube API requires resumable upload for videos
    -- Step 1: Initiate resumable upload session
    local session_uri, err = YouTubeUploader.initiate_resumable_upload(
        access_token,
        metadata_json
    )

    if not session_uri then
        return nil, err
    end

    -- Step 2: Upload video file
    local video_id, err = YouTubeUploader.upload_video_file(
        session_uri,
        video_path
    )

    if not video_id then
        return nil, err
    end

    -- Return video URL
    local video_url = "https://www.youtube.com/watch?v=" .. video_id

    return {
        video_id = video_id,
        url = video_url
    }
end

-- Initiate resumable upload session
-- @param access_token: OAuth access token
-- @param metadata_json: Video metadata as JSON
-- @return: Session URI for upload, or nil + error
function YouTubeUploader.initiate_resumable_upload(access_token, metadata_json)
    -- Escape JSON for shell
    local escaped_json = metadata_json:gsub("'", "'\\''")

    local cmd = string.format(
        "curl -s -X POST '%s?uploadType=resumable&part=snippet,status' " ..
        "-H 'Authorization: Bearer %s' " ..
        "-H 'Content-Type: application/json' " ..
        "-d '%s' " ..
        "-D -",  -- Include headers in output
        YOUTUBE_API,
        access_token,
        escaped_json
    )

    local handle = io.popen(cmd)
    local response = handle:read("*a")
    handle:close()

    -- Extract Location header (session URI)
    local session_uri = response:match("Location: (https://[^\r\n]+)")

    if not session_uri then
        -- Try to parse error from response
        local error_msg = "Failed to initiate upload session"
        local json_part = response:match("{.*}")
        if json_part then
            local error_data = dkjson.decode(json_part)
            if error_data and error_data.error then
                error_msg = error_data.error.message or error_msg
            end
        end
        return nil, error_msg
    end

    return session_uri
end

-- Upload video file to session URI
-- @param session_uri: Resumable upload session URI
-- @param video_path: Path to video file
-- @return: Video ID, or nil + error
function YouTubeUploader.upload_video_file(session_uri, video_path)
    -- Get file size
    local stat_cmd = string.format("stat -f%%z '%s' 2>/dev/null || stat -c%%s '%s' 2>/dev/null",
        video_path, video_path)
    local handle = io.popen(stat_cmd)
    local file_size = handle:read("*a"):gsub("%s+", "")
    handle:close()

    if file_size == "" then
        return nil, "Failed to get file size"
    end

    -- Upload file
    local cmd = string.format(
        "curl -s -X PUT '%s' " ..
        "-H 'Content-Type: video/mp4' " ..
        "-H 'Content-Length: %s' " ..
        "--data-binary '@%s'",
        session_uri,
        file_size,
        video_path
    )

    local handle = io.popen(cmd)
    local response = handle:read("*a")
    handle:close()

    -- Parse response
    local data, pos, err = dkjson.decode(response)
    if not data then
        return nil, "Failed to parse upload response: " .. (err or "unknown error")
    end

    if data.error then
        return nil, "Upload error: " .. (data.error.message or "unknown error")
    end

    if not data.id then
        return nil, "No video ID in response"
    end

    return data.id
end

-- Check upload progress (for large files)
-- @param session_uri: Resumable upload session URI
-- @return: Upload status {uploaded_bytes, total_bytes}
function YouTubeUploader.check_upload_progress(session_uri)
    local cmd = string.format(
        "curl -s -X PUT '%s' " ..
        "-H 'Content-Length: 0' " ..
        "-H 'Content-Range: bytes */*' " ..
        "-D -",
        session_uri
    )

    local handle = io.popen(cmd)
    local response = handle:read("*a")
    handle:close()

    -- Parse Range header
    local range = response:match("Range: bytes=0%-(%d+)")
    if range then
        return {
            uploaded_bytes = tonumber(range) + 1,
            total_bytes = nil  -- Unknown until complete
        }
    end

    return nil
end

-- Simple upload for small videos (< 5MB)
-- Bypasses resumable upload for faster uploads
-- @param video_path: Path to video file
-- @param metadata: Video metadata
-- @return: Video ID and URL, or nil + error
function YouTubeUploader.simple_upload(video_path, metadata)
    local access_token, err = youtube_oauth.get_access_token()
    if not access_token then
        return nil, err
    end

    -- Check file size
    local stat_cmd = string.format("stat -f%%z '%s' 2>/dev/null || stat -c%%s '%s' 2>/dev/null",
        video_path, video_path)
    local handle = io.popen(stat_cmd)
    local file_size = tonumber(handle:read("*a"):gsub("%s+", ""))
    handle:close()

    if file_size > 5 * 1024 * 1024 then
        -- File too large for simple upload
        return YouTubeUploader.upload_video(video_path, metadata)
    end

    -- Prepare metadata
    local video_metadata = {
        snippet = {
            title = metadata.title or "JVE Bug Report",
            description = metadata.description or "",
            tags = metadata.tags or {"jve", "bug-report"},
            categoryId = "28"
        },
        status = {
            privacyStatus = "unlisted",
            selfDeclaredMadeForKids = false
        }
    }

    local metadata_json = dkjson.encode(video_metadata)

    -- Create multipart request
    local boundary = "jve_upload_boundary_" .. os.time()

    local multipart_body = string.format(
        "--%s\r\n" ..
        "Content-Type: application/json; charset=UTF-8\r\n\r\n" ..
        "%s\r\n" ..
        "--%s\r\n" ..
        "Content-Type: video/mp4\r\n\r\n",
        boundary,
        metadata_json,
        boundary
    )

    -- Write multipart to temp file (curl can't easily do binary + text inline)
    local suffix = utils.human_datestamp_for_filename(os.time()) .. "-" .. uuid.generate():sub(1, 8)
    local temp_file = utils.get_temp_dir() .. "/jve_youtube_upload_" .. suffix .. ".txt"
    local file = io.open(temp_file, "w")
    file:write(multipart_body)
    file:close()

    -- Append video file
    os.execute(string.format("cat '%s' >> '%s'", video_path, temp_file))

    -- Append closing boundary
    local file = io.open(temp_file, "a")
    file:write(string.format("\r\n--%s--\r\n", boundary))
    file:close()

    -- Upload
    local cmd = string.format(
        "curl -s -X POST '%s?uploadType=multipart&part=snippet,status' " ..
        "-H 'Authorization: Bearer %s' " ..
        "-H 'Content-Type: multipart/related; boundary=%s' " ..
        "--data-binary '@%s'",
        YOUTUBE_API,
        access_token,
        boundary,
        temp_file
    )

    local handle = io.popen(cmd)
    local response = handle:read("*a")
    handle:close()

    -- Cleanup
    os.remove(temp_file)

    -- Parse response
    local data, pos, err = dkjson.decode(response)
    if not data then
        return nil, "Failed to parse response: " .. (err or "unknown error")
    end

    if data.error then
        return nil, "Upload error: " .. (data.error.message or "unknown error")
    end

    if not data.id then
        return nil, "No video ID in response"
    end

    return {
        video_id = data.id,
        url = "https://www.youtube.com/watch?v=" .. data.id
    }
end

return YouTubeUploader
