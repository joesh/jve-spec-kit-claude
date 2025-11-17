-- Clip model: Lua wrapper around clip database operations
-- Provides CRUD operations for clips following the Lua-for-logic, C++-for-performance architecture

local uuid = require("uuid")
local krono_ok, krono = pcall(require, "core.krono")
local timeline_state_ok, timeline_state = pcall(require, "ui.timeline.timeline_state")

local M = {}

local DEFAULT_CLIP_KIND = "timeline"

local function derive_display_name(id, existing_name)
    if existing_name and existing_name ~= "" then
        return existing_name
    end
    return "Clip " .. tostring(id):sub(1, 8)
end

function M.generate_id()
    return uuid.generate()
end

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

    local query = db:prepare([[
        SELECT id, project_id, clip_kind, name, track_id, media_id,
               source_sequence_id, parent_clip_id, owner_sequence_id,
               start_time, duration, source_in, source_out, enabled, offline
        FROM clips
        WHERE id = ?
    ]])
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
        project_id = query:value(1),
        clip_kind = query:value(2),
        name = query:value(3),
        track_id = query:value(4),
        media_id = query:value(5),
        source_sequence_id = query:value(6),
        parent_clip_id = query:value(7),
        owner_sequence_id = query:value(8),
        start_time = query:value(9),
        duration = query:value(10),
        source_in = query:value(11),
        source_out = query:value(12),
        enabled = query:value(13) == 1 or query:value(13) == true,
        offline = query:value(14) == 1 or query:value(14) == true,
    }

    clip.name = derive_display_name(clip.id, clip.name)

    setmetatable(clip, {__index = M})
    return clip
end

-- Create a new Clip instance
function M.create(name, media_id, opts)
    opts = opts or {}
    local clip = {
        id = opts.id or uuid.generate(),
        project_id = opts.project_id,
        clip_kind = opts.clip_kind or DEFAULT_CLIP_KIND,
        name = name,
        track_id = opts.track_id,
        media_id = media_id,
        source_sequence_id = opts.source_sequence_id,
        parent_clip_id = opts.parent_clip_id,
        owner_sequence_id = opts.owner_sequence_id,
        start_time = opts.start_time or 0,
        duration = opts.duration or 1000,  -- Default 1 second
        source_in = opts.source_in or 0,
        source_out = opts.source_out or (opts.source_in or 0) + (opts.duration or 1000),
        enabled = opts.enabled ~= false,
        offline = opts.offline or false,
    }

    clip.name = derive_display_name(clip.id, clip.name)

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

local function ensure_project_context(self, db)
    if self.project_id then
        return
    end

    -- Try to derive from owning sequence via track
    if self.track_id then
        local track_query = db:prepare("SELECT sequence_id FROM tracks WHERE id = ?")
        if track_query then
            track_query:bind_value(1, self.track_id)
            if track_query:exec() and track_query:next() then
                local sequence_id = track_query:value(0)
                self.owner_sequence_id = self.owner_sequence_id or sequence_id
                if sequence_id then
                    local seq_query = db:prepare("SELECT project_id FROM sequences WHERE id = ?")
                    if seq_query then
                        seq_query:bind_value(1, sequence_id)
                        if seq_query:exec() and seq_query:next() then
                            self.project_id = seq_query:value(0)
                        end
                    end
                end
            end
        end
    end

    -- Fallback: derive from source sequence if present
    if not self.project_id and self.source_sequence_id then
        local seq_query = db:prepare("SELECT project_id FROM sequences WHERE id = ?")
        if seq_query then
            seq_query:bind_value(1, self.source_sequence_id)
            if seq_query:exec() and seq_query:next() then
                self.project_id = seq_query:value(0)
            end
        end
    end
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
    if not self.start_time then
        self.start_time = 0
    end

    ensure_project_context(self, db)
    self.clip_kind = self.clip_kind or DEFAULT_CLIP_KIND
    self.offline = self.offline and true or false
    self.name = derive_display_name(self.id, self.name)

    local krono_enabled = krono_ok and krono and krono.is_enabled and krono.is_enabled()
    local krono_start = krono_enabled and krono.now and krono.now() or nil
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
        local pending = opts.pending_clips or {}
        if timeline_state_ok and timeline_state and timeline_state.get_track_clip_windows then
            pending.__window_cache = timeline_state.get_track_clip_windows(
                self.owner_sequence_id or self.track_sequence_id)
        end
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
    local krono_exists = (krono_enabled and krono_start and krono.now and krono.now()) or nil
    if exists then
        query = db:prepare([[
            UPDATE clips
            SET project_id = ?, clip_kind = ?, name = ?, track_id = ?, media_id = ?,
                source_sequence_id = ?, parent_clip_id = ?, owner_sequence_id = ?,
                start_time = ?, duration = ?, source_in = ?, source_out = ?,
                enabled = ?, offline = ?, modified_at = strftime('%s','now')
            WHERE id = ?
        ]])
    else
        query = db:prepare([[
            INSERT INTO clips (
                id, project_id, clip_kind, name, track_id, media_id,
                source_sequence_id, parent_clip_id, owner_sequence_id,
                start_time, duration, source_in, source_out, enabled, offline
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
    end

    if not query then
        print("WARNING: Clip.save: Failed to prepare query")
        return false
    end

    if exists then
        query:bind_value(1, self.project_id)
        query:bind_value(2, self.clip_kind)
        query:bind_value(3, self.name or "")
        query:bind_value(4, self.track_id)
        query:bind_value(5, self.media_id)
        query:bind_value(6, self.source_sequence_id)
        query:bind_value(7, self.parent_clip_id)
        query:bind_value(8, self.owner_sequence_id)
        query:bind_value(9, self.start_time)
        query:bind_value(10, self.duration)
        query:bind_value(11, self.source_in)
        query:bind_value(12, self.source_out)
        query:bind_value(13, self.enabled and 1 or 0)
        query:bind_value(14, self.offline and 1 or 0)
        query:bind_value(15, self.id)
    else
        query:bind_value(1, self.id)
        query:bind_value(2, self.project_id)
        query:bind_value(3, self.clip_kind)
        query:bind_value(4, self.name or "")
        query:bind_value(5, self.track_id)
        query:bind_value(6, self.media_id)
        query:bind_value(7, self.source_sequence_id)
        query:bind_value(8, self.parent_clip_id)
        query:bind_value(9, self.owner_sequence_id)
        query:bind_value(10, self.start_time)
        query:bind_value(11, self.duration)
        query:bind_value(12, self.source_in)
        query:bind_value(13, self.source_out)
        query:bind_value(14, self.enabled and 1 or 0)
        query:bind_value(15, self.offline and 1 or 0)
    end

    local krono_exec = (krono_enabled and krono_exists and krono.now and krono.now()) or nil
    if not query:exec() then
        print(string.format("WARNING: Clip.save: Failed to save clip: %s", query:last_error()))
        return false
    end

    if krono_enabled and krono_start and krono_exists and krono_exec then
        local total_ms = (krono_exec - krono_start)
        print(string.format("Clip.save[%s]: %.2fms (exists=%.2fms run=%.2fms)",
            tostring(self.id:sub(1,8)), total_ms,
            krono_exists - krono_start, krono_exec - krono_exists))
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
