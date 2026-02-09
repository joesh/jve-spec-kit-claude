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
-- Size: ~176 LOC
-- Volatility: unknown
--
-- @file media.lua
local uuid = require("uuid")
local logger = require("core.logger")

local M = {}

-- Helper to decompose float rate to num/den (simplified for migration)
local function rate_from_float(fps)
    assert(fps, "rate_from_float: fps must not be nil")
    assert(type(fps) == "number" and fps > 0, "rate_from_float: fps must be a positive number, got: " .. tostring(fps))
    -- Common NTSC values
    if math.abs(fps - 29.97) < 0.01 then return 30000, 1001 end
    if math.abs(fps - 23.976) < 0.01 then return 24000, 1001 end
    if math.abs(fps - 59.94) < 0.01 then return 60000, 1001 end
    return math.floor(fps + 0.5), 1
end

-- Create a new media item
function M.create(file_path_or_params, file_name, duration, frame_rate, metadata)
    local params

    if type(file_path_or_params) == "table" then
        params = file_path_or_params
    else
        params = {
            file_path = file_path_or_params,
            name = file_name,
            duration = duration,
            frame_rate = frame_rate,
            metadata = metadata
        }
    end

    local file_path = params.file_path
    local name = params.name or params.file_name
    local dur_input = params.duration
    local dur_frames_input = params.duration_frames
    local fps_input = params.frame_rate
    
    local num, den
    if type(fps_input) == "table" and fps_input.fps_numerator then
        num, den = fps_input.fps_numerator, fps_input.fps_denominator
    elseif params.fps_numerator and params.fps_denominator then
        num, den = params.fps_numerator, params.fps_denominator
    else
        num, den = rate_from_float(tonumber(fps_input))
    end
    
    local dur_frames
    if dur_frames_input then
        -- If duration_frames provided, use directly (integer)
        dur_frames = assert(tonumber(dur_frames_input), "Media.create: duration_frames must be a number, got " .. tostring(dur_frames_input))
    elseif dur_input then
        -- Milliseconds -> frames (I/O boundary conversion)
        assert(type(dur_input) == "number", "Media.create: duration must be integer ms, got " .. type(dur_input))
        local dur_ms = dur_input
        local seconds = dur_ms / 1000.0
        dur_frames = math.floor(seconds * num / den + 0.5)
    else
        dur_frames = 0 -- Unknown duration (audio-only, still image)
    end

    local media = {
        id = params.id or uuid.generate(),
        project_id = params.project_id,
        file_path = file_path,
        name = name,
        duration = dur_frames,  -- integer frames
        frame_rate = { fps_numerator = num, fps_denominator = den },
        width = tonumber(params.width) or 0, -- NSF-OK: 0 = unknown dimension (audio-only media has no width)
        height = tonumber(params.height) or 0, -- NSF-OK: 0 = unknown dimension
        audio_channels = tonumber(params.audio_channels) or 0, -- NSF-OK: 0 = unknown/not applicable
        codec = params.codec or "", -- NSF-OK: "" = unknown codec
        created_at = params.created_at or os.time(),
        modified_at = params.modified_at or os.time(),
        metadata = params.metadata or '{}'
    }

    setmetatable(media, {__index = M})
    return media
end

-- Load a media item from the database
function M.load(media_id)
    assert(media_id and media_id ~= "", "Media.load: media_id must not be nil or empty")

    local database = require("core.database")
    local db = assert(database.get_connection(), "Media.load: no database connection available")

    local query = assert(db:prepare([[
        SELECT id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
               width, height, audio_channels, codec, created_at, modified_at, metadata
        FROM media WHERE id = ?
    ]]), string.format("Media.load: failed to prepare query for media_id=%s", media_id))

    query:bind_value(1, media_id)

    if not query:exec() then
        error(string.format("Media.load: query execution failed for media_id=%s: %s", media_id, query:last_error()))
    end

    if not query:next() then
        query:finalize()
        return nil -- NSF-OK: nil = "not found" (distinct from DB error, which asserts above)
    end
    
    local frames = query:value(4) or 0 -- NSF-OK: 0 frames = still-image or unknown-duration media
    local num = query:value(5)
    local den = query:value(6)
    assert(num, string.format("Media.load: fps_numerator is NULL for media_id=%s", tostring(media_id)))
    assert(den, string.format("Media.load: fps_denominator is NULL for media_id=%s", tostring(media_id)))

    local media = {
        id = query:value(0),
        project_id = query:value(1),
        name = query:value(2),
        file_path = query:value(3),
        duration = frames,  -- integer frames
        frame_rate = { fps_numerator = num, fps_denominator = den },
        width = tonumber(query:value(7)) or 0, -- NSF-OK: 0 = unknown dimension
        height = tonumber(query:value(8)) or 0, -- NSF-OK: 0 = unknown dimension
        audio_channels = tonumber(query:value(9)) or 0, -- NSF-OK: 0 = unknown
        codec = query:value(10),
        created_at = query:value(11),
        modified_at = query:value(12),
        metadata = query:value(13)
    }
    
    query:finalize()

    setmetatable(media, {__index = M})
    return media
end

-- Save a media item to the database
function M:save()
    local database = require("core.database")
    local db = database.get_connection()
    if not db then
        logger.warn("media", "Media:save: No database connection available")
        return false
    end

    -- Duration is now an integer
    assert(type(self.duration) == "number", "Media:save: duration must be integer for media " .. tostring(self.id))
    local dur_frames = self.duration

    -- Handle Rate
    local num = (self.frame_rate and self.frame_rate.fps_numerator) or self.fps_numerator
    local den = (self.frame_rate and self.frame_rate.fps_denominator) or self.fps_denominator
    assert(den and den > 0, string.format("Media:save: Invalid fps_denominator for media %s (den=%s)", tostring(self.id), tostring(den)))
    
    if not num or num <= 0 then
        error(string.format("Media:save: Invalid frame rate for media %s (num=%s)", self.id, tostring(num)))
    end
    
    local query = db:prepare([[
        INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at, metadata)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            project_id = excluded.project_id,
            name = excluded.name,
            file_path = excluded.file_path,
            duration_frames = excluded.duration_frames,
            fps_numerator = excluded.fps_numerator,
            fps_denominator = excluded.fps_denominator,
            width = excluded.width,
            height = excluded.height,
            audio_channels = excluded.audio_channels,
            codec = excluded.codec,
            modified_at = excluded.modified_at,
            metadata = excluded.metadata
    ]])

    if not query then
        logger.warn("media", "Media:save: Failed to prepare query")
        return false
    end

    query:bind_value(1, self.id)
    query:bind_value(2, self.project_id)
    query:bind_value(3, self.name)
    query:bind_value(4, self.file_path)
    query:bind_value(5, dur_frames)
    query:bind_value(6, num)
    query:bind_value(7, den)
    query:bind_value(8, self.width)
    query:bind_value(9, self.height)
    query:bind_value(10, self.audio_channels)
    query:bind_value(11, self.codec)
    query:bind_value(12, self.created_at)
    query:bind_value(13, self.modified_at)
    query:bind_value(14, self.metadata)

    if not query:exec() then
        logger.warn("media", string.format("Media:save: Query execution failed: %s", query:last_error()))
        query:finalize()
        return false
    end
    
    query:finalize()

    return true
end

return M
