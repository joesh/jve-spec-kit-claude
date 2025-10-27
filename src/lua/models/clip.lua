-- Clip model: Lua wrapper around clip database operations
-- Provides CRUD operations for clips following the Lua-for-logic, C++-for-performance architecture

local uuid = require("uuid")

local M = {}

local function load_internal(clip_id, db, raise_errors)
    if not clip_id or clip_id == "" then
        if raise_errors then
            error("Clip.load_failed: Invalid clip_id")
        end
        return nil
    end

    if not db then
        if raise_errors then
            error("Clip.load_failed: No database provided")
        end
        return nil
    end

    local query = db:prepare("SELECT id, track_id, media_id, start_time, duration, source_in, source_out, enabled FROM clips WHERE id = ?")
    if not query then
        if raise_errors then
            error("Clip.load_failed: Failed to prepare query")
        end
        return nil
    end

    query:bind_value(1, clip_id)

    if not query:exec() then
        if raise_errors then
            error(string.format("Clip.load_failed: Query execution failed: %s", query:last_error()))
        end
        return nil
    end

    if not query:next() then
        if raise_errors then
            error(string.format("Clip.load_failed: Clip not found: %s", clip_id))
        end
        return nil
    end

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

    clip.name = "Clip " .. clip.id:sub(1, 8)

    setmetatable(clip, {__index = M})
    return clip
end

-- Create a new Clip instance
function M.create(name, media_id)
    local clip = {
        id = uuid.generate(),
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
    return load_internal(clip_id, db, true)
end

function M.load_optional(clip_id, db)
    return load_internal(clip_id, db, false)
end

-- Save clip to database (INSERT or UPDATE)
local function save_internal(self, db, opts)
    if not db then
        print("WARNING: Clip.save: No database provided")
        return false
    end

    opts = opts or {}

    if not self.id or self.id == "" then
        print("WARNING: Clip.save: Invalid clip ID")
        return false
    end

    -- Normalise numeric fields
    if self.start_time then
        self.start_time = math.floor(self.start_time + 0.5)
    end
    if self.duration then
        self.duration = math.floor(self.duration + 0.5)
    end
    if self.source_in then
        self.source_in = math.floor(self.source_in + 0.5)
    end
    if self.source_out then
        self.source_out = math.floor(self.source_out + 0.5)
    end
    if self.duration == nil or self.duration < 1 then
        print(string.format("WARNING: Clip.save: duration %s invalid, clamping to 1 for clip %s",
            tostring(self.duration), tostring(self.id)))
        self.duration = 1
    end
    if self.source_out and self.source_in and self.source_out <= self.source_in then
        self.source_out = self.source_in + self.duration
    end

    -- Validate required fields to prevent NULL constraint violations
    if self.start_time == nil then
        print(string.format("ERROR: Clip.save: Clip %s has nil start_time - cannot save", self.id:sub(1,8)))
        print(string.format("  track_id=%s, duration=%s", tostring(self.track_id), tostring(self.duration)))
        return false
    end

    -- FRAME ALIGNMENT ENFORCEMENT (VIDEO ONLY)
    if not opts.skip_frame_snap and self.track_id then
        local track_query = db:prepare("SELECT track_type, sequence_id FROM tracks WHERE id = ?")
        if track_query then
            track_query:bind_value(1, self.track_id)
            if track_query:exec() and track_query:next() then
                local track_type = track_query:value(0)
                local sequence_id = track_query:value(1)
                if track_type == "VIDEO" and sequence_id then
                    local seq_query = db:prepare("SELECT frame_rate FROM sequences WHERE id = ?")
                    if seq_query then
                        seq_query:bind_value(1, sequence_id)
                        if seq_query:exec() and seq_query:next() then
                            local frame_rate = seq_query:value(0)
                            local frame_utils = require('core.frame_utils')
                            self.start_time = frame_utils.snap_to_frame(self.start_time, frame_rate)
                            self.duration = frame_utils.snap_to_frame(self.duration, frame_rate)
                            if self.source_in then
                                self.source_in = frame_utils.snap_to_frame(self.source_in, frame_rate)
                            end
                            if self.source_out then
                                self.source_out = frame_utils.snap_to_frame(self.source_out, frame_rate)
                            end
                        end
                    end
                end
            end
        end
    end

    -- Check if clip exists
    local exists_query = db:prepare("SELECT COUNT(*) FROM clips WHERE id = ?")
    exists_query:bind_value(1, self.id)

    local exists = false
    if exists_query:exec() and exists_query:next() then
        exists = exists_query:value(0) > 0
    end

    local skip_occlusion = opts.skip_occlusion == true
    local occlusion_actions = nil
    if not skip_occlusion and self.track_id and self.start_time and self.duration then
        local clip_mutator = require('core.clip_mutator')
        local pending = opts.pending_clips
        local ok, err, actions = clip_mutator.resolve_occlusions(db, {
            track_id = self.track_id,
            start_time = self.start_time,
            duration = self.duration,
            exclude_clip_id = exists and self.id or nil,
            pending_clips = pending
        })
        if not ok then
            print("WARNING: Clip.save: Failed to resolve occlusions: " .. tostring(err or "unknown"))
            return false
        end
        occlusion_actions = actions
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

    return true, occlusion_actions
end

function M:save(db, opts)
    return save_internal(self, db, opts or {})
end

function M:restore_without_occlusion(db)
    return save_internal(self, db, {skip_occlusion = true})
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
