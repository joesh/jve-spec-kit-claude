-- Clip model: Lua wrapper around clip database operations
-- Provides CRUD operations for clips following the Lua-for-logic, C++-for-performance architecture

local M = {}

-- Seed random number generator once when module loads
-- Use os.time() and os.clock() for better entropy
math.randomseed(os.time() + os.clock() * 1000000)

-- UUID generation (simple implementation for now)
local function generate_uuid()
    local random = math.random
    local template ='xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function (c)
        local v = (c == 'x') and random(0, 0xf) or random(8, 0xb)
        return string.format('%x', v)
    end)
end

-- Create a new Clip instance
function M.create(name, media_id)
    local clip = {
        id = generate_uuid(),
        name = name or "Untitled Clip",
        media_id = media_id,
        track_id = nil,
        start_time = 0,
        duration = 1000,  -- Default 1 second
        source_in = 0,
        source_out = 1000,
        enabled = true,
    }

    setmetatable(clip, {__index = M})
    return clip
end

-- Load clip from database
function M.load(clip_id, db)
    if not clip_id or clip_id == "" then
        print("WARNING: Clip.load: Invalid clip_id")
        return nil
    end

    if not db then
        print("WARNING: Clip.load: No database provided")
        return nil
    end

    local query = db:prepare("SELECT id, track_id, media_id, start_time, duration, source_in, source_out, enabled FROM clips WHERE id = ?")
    if not query then
        print("WARNING: Clip.load: Failed to prepare query")
        return nil
    end

    query:bind_value(1, clip_id)

    if not query:exec() then
        print(string.format("WARNING: Clip.load: Query execution failed: %s", query:last_error()))
        return nil
    end

    if not query:next() then
        print(string.format("WARNING: Clip.load: Clip not found: %s", clip_id))
        return nil
    end

    -- Read values from query result
    local clip = {
        id = query:value(0),
        track_id = query:value(1),
        media_id = query:value(2),
        start_time = query:value(3),
        duration = query:value(4),
        source_in = query:value(5),
        source_out = query:value(6),
        enabled = query:value(7) == 1 or query:value(7) == true,
    }

    -- Set name from media or default
    -- TODO: Query media table for actual name
    clip.name = "Clip " .. clip.id:sub(1, 8)

    setmetatable(clip, {__index = M})
    return clip
end

-- Save clip to database (INSERT or UPDATE)
function M:save(db)
    if not db then
        print("WARNING: Clip.save: No database provided")
        return false
    end

    if not self.id or self.id == "" then
        print("WARNING: Clip.save: Invalid clip ID")
        return false
    end

    -- Check if clip exists
    local exists_query = db:prepare("SELECT COUNT(*) FROM clips WHERE id = ?")
    exists_query:bind_value(1, self.id)

    local exists = false
    if exists_query:exec() and exists_query:next() then
        exists = exists_query:value(0) > 0
    end

    local query
    if exists then
        -- UPDATE existing clip
        query = db:prepare([[
            UPDATE clips
            SET track_id = ?, media_id = ?, start_time = ?, duration = ?,
                source_in = ?, source_out = ?, enabled = ?
            WHERE id = ?
        ]])
        query:bind_value(1, self.track_id)
        query:bind_value(2, self.media_id)
        query:bind_value(3, self.start_time)
        query:bind_value(4, self.duration)
        query:bind_value(5, self.source_in)
        query:bind_value(6, self.source_out)
        query:bind_value(7, self.enabled and 1 or 0)
        query:bind_value(8, self.id)
    else
        -- INSERT new clip
        query = db:prepare([[
            INSERT INTO clips (id, track_id, media_id, start_time, duration, source_in, source_out, enabled)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        query:bind_value(1, self.id)
        query:bind_value(2, self.track_id)
        query:bind_value(3, self.media_id)
        query:bind_value(4, self.start_time)
        query:bind_value(5, self.duration)
        query:bind_value(6, self.source_in)
        query:bind_value(7, self.source_out)
        query:bind_value(8, self.enabled and 1 or 0)
    end

    if not query then
        print("WARNING: Clip.save: Failed to prepare query")
        return false
    end

    if not query:exec() then
        print(string.format("WARNING: Clip.save: Failed to save clip: %s", query:last_error()))
        return false
    end

    return true
end

-- Delete clip from database
function M:delete(db)
    if not db then
        print("WARNING: Clip.delete: No database provided")
        return false
    end

    local query = db:prepare("DELETE FROM clips WHERE id = ?")
    query:bind_value(1, self.id)

    if not query:exec() then
        print(string.format("WARNING: Clip.delete: Failed to delete clip: %s", query:last_error()))
        return false
    end

    return true
end

-- Property getters/setters (for generic property access)
function M:get_property(property_name)
    return self[property_name]
end

function M:set_property(property_name, value)
    self[property_name] = value
end

return M
