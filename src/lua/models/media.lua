local uuid = require("uuid")

local M = {}

-- Create a new media item
-- Accepts either: table of named params OR positional args (backward compatible)
function M.create(file_path_or_params, file_name, duration, frame_rate, metadata)
    local params

    -- Support both calling styles
    if type(file_path_or_params) == "table" then
        -- New style: named parameters
        params = file_path_or_params
    else
        -- Old style: positional parameters
        params = {
            file_path = file_path_or_params,
            file_name = file_name,
            name = file_name,  -- Alias
            duration = duration,
            frame_rate = frame_rate,
            metadata = metadata
        }
    end

    -- Extract with multiple name variations for compatibility
    local file_path = params.file_path
    local name = params.name or params.file_name
    local dur = tonumber(params.duration_value or params.duration)
    local fps = tonumber(params.frame_rate)
    local meta = params.metadata
    local project_id = params.project_id
    local width = tonumber(params.width) or 0
    local height = tonumber(params.height) or 0
    local audio_channels = tonumber(params.audio_channels) or 0
    local codec = params.codec or ""
    local sample_rate = tonumber(params.audio_sample_rate) or 48000
    local timebase_type = params.timebase_type
    local timebase_rate = tonumber(params.timebase_rate)

    -- Validation
    if not file_path or file_path == "" then
        print("WARNING: Media.create: Invalid file_path")
        return nil
    end

    if not name or name == "" then
        print("WARNING: Media.create: Invalid name/file_name")
        return nil
    end

    if not dur or dur <= 0 then
        print("WARNING: Media.create: Invalid duration")
        return nil
    end

    -- Frame rate can be 0 for audio-only files
    if fps == nil or fps < 0 then
        print("WARNING: Media.create: Invalid frame_rate")
        return nil
    end

    if not timebase_type then
        if fps and fps > 0 then
            timebase_type = "video_frames"
            timebase_rate = timebase_rate or fps
        else
            timebase_type = "audio_samples"
            timebase_rate = timebase_rate or sample_rate
        end
    end
    if not timebase_rate or timebase_rate <= 0 then
        timebase_rate = (timebase_type == "video_frames") and (fps > 0 and fps or 24) or sample_rate
    end

    local now = os.time()
    local media = {
        id = params.id or uuid.generate(),
        project_id = project_id,
        file_path = file_path,
        name = name,
        file_name = name,  -- Alias for backward compatibility
        duration_value = dur,
        duration = dur,
        frame_rate = fps,
        timebase_type = timebase_type,
        timebase_rate = timebase_rate,
        width = width,
        height = height,
        audio_channels = audio_channels,
        codec = codec,
        created_at = params.created_at or now,
        modified_at = params.modified_at or now,
        metadata = meta or '{}'
    }

    setmetatable(media, {__index = M})
    return media
end

-- Load a media item from the database
function M.load(media_id, db)
    if not media_id or media_id == "" then
        print("WARNING: Media.load: Invalid media_id")
        return nil
    end

    if not db then
        print("WARNING: Media.load: No database provided")
        return nil
    end

    local query = db:prepare([[
        SELECT id, project_id, name, file_path, duration_value, timebase_type, timebase_rate,
               frame_rate, width, height, audio_channels, codec, created_at, modified_at, metadata
        FROM media WHERE id = ?
    ]])
    if not query then
        print("WARNING: Media.load: Failed to prepare query")
        return nil
    end

    query:bind_value(1, media_id)

    if not query:exec() then
        print(string.format("WARNING: Media.load: Query execution failed: %s", query:last_error()))
        return nil
    end

    if not query:next() then
        -- Media not found - this is expected for orphaned clips (after undo/replay)
        -- Calling code handles nil media gracefully by skipping boundary checks
        return nil
    end

    local media = {
        id = query:value(0),
        project_id = query:value(1),
        name = query:value(2),
        file_name = query:value(2),  -- Alias for backward compatibility
        file_path = query:value(3),
        duration_value = tonumber(query:value(4)) or 0,
        timebase_type = query:value(5),
        timebase_rate = tonumber(query:value(6)) or 0,
        frame_rate = tonumber(query:value(7)) or 0,
        width = tonumber(query:value(8)) or 0,
        height = tonumber(query:value(9)) or 0,
        audio_channels = tonumber(query:value(10)) or 0,
        codec = query:value(11),
        created_at = query:value(12),
        modified_at = query:value(13),
        metadata = query:value(14)
    }
    media.duration = media.duration_value

    setmetatable(media, {__index = M})
    return media
end

-- Save a media item to the database
function M:save(db)
    if not db then
        print("WARNING: Media:save: No database provided")
        return false
    end

    if self.duration and not self.duration_value then
        self.duration_value = self.duration
    end
    self.duration = self.duration_value

    local query = db:prepare([[
        INSERT INTO media (id, project_id, name, file_path, duration_value, timebase_type, timebase_rate, frame_rate, width, height, audio_channels, codec, created_at, modified_at, metadata)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            project_id = excluded.project_id,
            name = excluded.name,
            file_path = excluded.file_path,
            duration_value = excluded.duration_value,
            timebase_type = excluded.timebase_type,
            timebase_rate = excluded.timebase_rate,
            frame_rate = excluded.frame_rate,
            width = excluded.width,
            height = excluded.height,
            audio_channels = excluded.audio_channels,
            codec = excluded.codec,
            modified_at = excluded.modified_at,
            metadata = excluded.metadata
    ]])

    if not query then
        print("WARNING: Media:save: Failed to prepare query")
        return false
    end

    -- Bind parameters individually (bind_value, not bind_values)
    query:bind_value(1, self.id)
    query:bind_value(2, self.project_id)
    query:bind_value(3, self.name)
    query:bind_value(4, self.file_path)
    query:bind_value(5, self.duration_value)
    query:bind_value(6, self.timebase_type)
    query:bind_value(7, self.timebase_rate)
    query:bind_value(8, self.frame_rate)
    query:bind_value(9, self.width)
    query:bind_value(10, self.height)
    query:bind_value(11, self.audio_channels)
    query:bind_value(12, self.codec)
    query:bind_value(13, self.created_at)
    query:bind_value(14, self.modified_at)
    query:bind_value(15, self.metadata)

    if not query:exec() then
        print(string.format("WARNING: Media:save: Query execution failed: %s", query:last_error()))
        return false
    end

    return true
end

return M
