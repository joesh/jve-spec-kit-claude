local uuid = require("uuid")
local Rational = require("core.rational")
local logger = require("core.logger")

local M = {}

-- Helper to decompose float rate to num/den (simplified for migration)
local function rate_from_float(fps)
    if not fps or fps <= 0 then return 30, 1 end
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
    
    local dur_rational
    if type(dur_input) == "table" and dur_input.frames then
        dur_rational = dur_input
    elseif dur_frames_input then
        -- If duration_frames provided, treat as frames
        dur_rational = Rational.new(tonumber(dur_frames_input) or 0, num, den)
    else
        -- Assume input is milliseconds if number (legacy compat for creation)
        local seconds = (tonumber(dur_input) or 0) / 1000.0
        dur_rational = Rational.from_seconds(seconds, num, den)
    end

    local media = {
        id = params.id or uuid.generate(),
        project_id = params.project_id,
        file_path = file_path,
        name = name,
        duration = dur_rational,
        frame_rate = { fps_numerator = num, fps_denominator = den },
        width = tonumber(params.width) or 0,
        height = tonumber(params.height) or 0,
        audio_channels = tonumber(params.audio_channels) or 0,
        codec = params.codec or "",
        created_at = params.created_at or os.time(),
        modified_at = params.modified_at or os.time(),
        metadata = params.metadata or '{}'
    }

    setmetatable(media, {__index = M})
    return media
end

-- Load a media item from the database
function M.load(media_id, db)
    if not media_id or media_id == "" then
        logger.warn("media", "Media.load: Invalid media_id")
        return nil
    end

    if not db then
        logger.warn("media", "Media.load: No database provided")
        return nil
    end

    local query = db:prepare([[
        SELECT id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
               width, height, audio_channels, codec, created_at, modified_at, metadata
        FROM media WHERE id = ?
    ]])
    if not query then
        logger.warn("media", "Media.load: Failed to prepare query")
        return nil
    end

    query:bind_value(1, media_id)

    if not query:exec() then
        logger.warn("media", string.format("Media.load: Query execution failed: %s", query:last_error()))
        query:finalize()
        return nil
    end

    if not query:next() then
        query:finalize()
        return nil
    end
    
    local frames = query:value(4) or 0
    local num = query:value(5) or 30
    local den = query:value(6) or 1

    local media = {
        id = query:value(0),
        project_id = query:value(1),
        name = query:value(2),
        file_path = query:value(3),
        duration = Rational.new(frames, num, den),
        frame_rate = { fps_numerator = num, fps_denominator = den },
        width = tonumber(query:value(7)) or 0,
        height = tonumber(query:value(8)) or 0,
        audio_channels = tonumber(query:value(9)) or 0,
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
function M:save(db)
    if not db then
        logger.warn("media", "Media:save: No database provided")
        return false
    end
    
    -- Correctly handle duration (Rational)
    local dur_frames = 0
    if type(self.duration) == "table" and self.duration.frames then
        dur_frames = self.duration.frames
    elseif type(self.duration) == "number" then
        dur_frames = self.duration
    elseif type(self.duration_frames) == "number" then
        dur_frames = self.duration_frames
    end

    -- Handle Rate
    local num = (self.frame_rate and self.frame_rate.fps_numerator) or self.fps_numerator
    local den = (self.frame_rate and self.frame_rate.fps_denominator) or self.fps_denominator or 1
    
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
