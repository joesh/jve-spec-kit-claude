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
function M.create(file_path, file_name, duration, frame_rate, metadata)
    if not file_path or file_path == "" then
        print("WARNING: Media.create: Invalid file_path")
        return nil
    end

    if not file_name or file_name == "" then
        print("WARNING: Media.create: Invalid file_name")
        return nil
    end

    if not duration or duration <= 0 then
        print("WARNING: Media.create: Invalid duration")
        return nil
    end

    if not frame_rate or frame_rate <= 0 then
        print("WARNING: Media.create: Invalid frame_rate")
        return nil
    end

    local media = {
        id = generate_uuid(),
        file_path = file_path,
        file_name = file_name,
        duration = duration,
        frame_rate = frame_rate,
        metadata = metadata or '{}'
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

    local query = db:prepare("SELECT id, file_path, file_name, duration, frame_rate, metadata FROM media WHERE id = ?")
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
        print(string.format("WARNING: Media.load: Media not found: %s", media_id))
        return nil
    end

    local media = {
        id = query:value(0),
        file_path = query:value(1),
        file_name = query:value(2),
        duration = query:value(3),
        frame_rate = query:value(4),
        metadata = query:value(5)
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
        INSERT INTO media (id, file_path, file_name, duration, frame_rate, metadata)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            file_path = excluded.file_path,
            file_name = excluded.file_name,
            duration = excluded.duration,
            frame_rate = excluded.frame_rate,
            metadata = excluded.metadata
    ]])

    if not query then
        print("WARNING: Media:save: Failed to prepare query")
        return false
    end

    query:bind_values(
        self.id,
        self.file_path,
        self.file_name,
        self.duration,
        self.frame_rate,
        self.metadata
    )

    if not query:exec() then
        print(string.format("WARNING: Media:save: Query execution failed: %s", query:last_error()))
        return false
    end

    return true
end

return M
