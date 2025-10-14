local M = {}

-- UUID generation
local function generate_uuid()
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function(c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end)
end

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
    local dur = params.duration
    local fps = params.frame_rate
    local meta = params.metadata
    local project_id = params.project_id
    local width = params.width or 0
    local height = params.height or 0
    local audio_channels = params.audio_channels or 0
    local codec = params.codec or ""

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
    if not fps or fps < 0 then
        print("WARNING: Media.create: Invalid frame_rate")
        return nil
    end

    local now = os.time()
    local media = {
        id = params.id or generate_uuid(),
        project_id = project_id,
        file_path = file_path,
        name = name,
        file_name = name,  -- Alias for backward compatibility
        duration = dur,
        frame_rate = fps,
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

    local query = db:prepare("SELECT id, project_id, name, file_path, duration, frame_rate, width, height, audio_channels, codec, created_at, modified_at, metadata FROM media WHERE id = ?")
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
        duration = query:value(4),
        frame_rate = query:value(5),
        width = query:value(6),
        height = query:value(7),
        audio_channels = query:value(8),
        codec = query:value(9),
        created_at = query:value(10),
        modified_at = query:value(11),
        metadata = query:value(12)
    }

    setmetatable(media, {__index = M})
    return media
end

-- Save a media item to the database
function M:save(db)
    if not db then
        print("WARNING: Media:save: No database provided")
        return false
    end

    local query = db:prepare([[
        INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, width, height, audio_channels, codec, created_at, modified_at, metadata)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            project_id = excluded.project_id,
            name = excluded.name,
            file_path = excluded.file_path,
            duration = excluded.duration,
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
    query:bind_value(5, self.duration)
    query:bind_value(6, self.frame_rate)
    query:bind_value(7, self.width)
    query:bind_value(8, self.height)
    query:bind_value(9, self.audio_channels)
    query:bind_value(10, self.codec)
    query:bind_value(11, self.created_at)
    query:bind_value(12, self.modified_at)
    query:bind_value(13, self.metadata)

    if not query:exec() then
        print(string.format("WARNING: Media:save: Query execution failed: %s", query:last_error()))
        return false
    end

    return true
end

return M
