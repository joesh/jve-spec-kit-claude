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
-- Size: ~348 LOC
-- Volatility: unknown
--
-- @file clip.lua
-- Original intent (unreviewed):
-- Clip model: Lua wrapper around clip database operations
-- Provides CRUD operations for clips following the Lua-for-logic, C++-for-performance architecture
local uuid = require("uuid")
local krono_ok, krono = pcall(require, "core.krono")
local timeline_state_ok, timeline_state = pcall(require, "ui.timeline.timeline_state")
local logger = require("core.logger")

local M = {}

local function derive_display_name(id, existing_name)
    if existing_name and existing_name ~= "" then
        return existing_name
    end
    return "Clip " .. tostring(id):sub(1, 8)
end

function M.generate_id()
    return uuid.generate()
end

-- Helper: Validate integer frame value
local function validate_frame(val, field_name)
    if val == nil then
        error(string.format("Clip: %s is required", field_name))
    end
    if type(val) ~= "number" then
        error(string.format("Clip: %s must be an integer (got %s)", field_name, type(val)))
    end
    return val
end

local function load_internal(clip_id, raise_errors)
    if not clip_id or clip_id == "" then
        if raise_errors then
            error("Clip.load_failed: Invalid clip_id")
        end
        return nil
    end

    local database = require("core.database")
    local db = database.get_connection()
    if not db then
        if raise_errors then
            error("Clip.load_failed: No database connection available")
        end
        return nil
    end

    local query = db:prepare([[
        SELECT c.id, c.project_id, c.clip_kind, c.name, c.track_id, c.media_id,
               c.source_sequence_id, c.parent_clip_id, c.owner_sequence_id,
               c.timeline_start_frame, c.duration_frames, c.source_in_frame, c.source_out_frame,
               c.fps_numerator, c.fps_denominator, c.enabled, c.offline,
               s.fps_numerator, s.fps_denominator
        FROM clips c
        LEFT JOIN tracks t ON c.track_id = t.id
        LEFT JOIN sequences s ON t.sequence_id = s.id
        WHERE c.id = ?
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
            local err = query:last_error()
            query:finalize()
            error(string.format("Clip.load_failed: Query execution failed: %s", err))
        end
        query:finalize()
        return nil
    end

    if not query:next() then
        if raise_errors then
            query:finalize()
            error(string.format("Clip.load_failed: Clip not found: %s", clip_id))
        end
        query:finalize()
        return nil
    end

    local clip_kind = query:value(2)
    local fps_numerator = query:value(13)
    local fps_denominator = query:value(14)
    local sequence_fps_numerator = query:value(17)
    local sequence_fps_denominator = query:value(18)
    
    -- Enforce Rate existence (Strict V5)
    if not fps_numerator or fps_numerator <= 0 then 
        query:finalize()
        error(string.format("Clip.load_failed: Clip %s has invalid frame rate (%s)", clip_id, tostring(fps_numerator)))
    end
    if not fps_denominator or fps_denominator <= 0 then
        query:finalize()
        error(string.format("Clip.load_failed: Clip %s has invalid frame rate denominator (%s)", clip_id, tostring(fps_denominator)))
    end

    local timeline_fps_numerator = fps_numerator
    local timeline_fps_denominator = fps_denominator
    if clip_kind ~= "master" then
        if not sequence_fps_numerator or not sequence_fps_denominator then
            query:finalize()
            error(string.format("Clip.load_failed: Clip %s missing owning sequence frame rate", clip_id))
        end
        if sequence_fps_numerator <= 0 or sequence_fps_denominator <= 0 then
            query:finalize()
            error(string.format("Clip.load_failed: Clip %s has invalid owning sequence frame rate (%s/%s)", clip_id, tostring(sequence_fps_numerator), tostring(sequence_fps_denominator)))
        end
        timeline_fps_numerator = sequence_fps_numerator
        timeline_fps_denominator = sequence_fps_denominator
    end

    local clip = {
        id = query:value(0),
        project_id = query:value(1),
        clip_kind = clip_kind,
        name = query:value(3),
        track_id = query:value(4),
        media_id = query:value(5),
        source_sequence_id = query:value(6),
        parent_clip_id = query:value(7),
        owner_sequence_id = query:value(8),

        -- Integer frame coordinates (fps is metadata in clip.rate and sequence.frame_rate)
        timeline_start = assert(query:value(9), "Clip.load: timeline_start_frame is NULL"),
        duration = assert(query:value(10), "Clip.load: duration_frames is NULL"),
        source_in = assert(query:value(11), "Clip.load: source_in_frame is NULL"),
        source_out = assert(query:value(12), "Clip.load: source_out_frame is NULL"),
        
        -- Store rate explicitly
        rate = {
            fps_numerator = fps_numerator,
            fps_denominator = fps_denominator
        },

        enabled = query:value(15) == 1 or query:value(15) == true,
        offline = query:value(16) == 1 or query:value(16) == true,
    }
    
    query:finalize()

    clip.name = derive_display_name(clip.id, clip.name)

    setmetatable(clip, {__index = M})
    return clip
end

-- Create a new Clip instance
function M.create(name, media_id, opts)
    opts = opts or {}

    local now = os.time()

    -- FAIL FAST: fps is required - no silent fallbacks that hide bugs
    assert(opts.fps_numerator, "Clip.create: fps_numerator is required")
    assert(opts.fps_denominator, "Clip.create: fps_denominator is required")
    local fps_numerator = opts.fps_numerator
    local fps_denominator = opts.fps_denominator
    local default_rate = {fps_numerator = fps_numerator, fps_denominator = fps_denominator}

    -- FAIL FAST: Check for legacy keys
    if opts.start_value or opts.duration_value or opts.source_in_value or opts.source_out_value then
        error("Clip.create: Legacy field names (start_value, etc.) are NOT allowed. Use Rational objects.")
    end

    local clip = {
        id = opts.id or uuid.generate(),
        project_id = opts.project_id,
        clip_kind = opts.clip_kind or "timeline", -- NSF-OK: "timeline" is the natural default kind for new clips
        name = name,
        track_id = opts.track_id,
        media_id = media_id,
        source_sequence_id = opts.source_sequence_id,
        parent_clip_id = opts.parent_clip_id,
        owner_sequence_id = opts.owner_sequence_id,
        created_at = opts.created_at or now,
        modified_at = opts.modified_at or now,
        
        -- Integer frame coordinates (fps is metadata in clip.rate)
        timeline_start = validate_frame(opts.timeline_start, "timeline_start"),
        duration = validate_frame(opts.duration, "duration"),
        source_in = validate_frame(opts.source_in ~= nil and opts.source_in or 0, "source_in"),
        source_out = validate_frame(opts.source_out ~= nil and opts.source_out or opts.duration, "source_out"),
        
        rate = {
            fps_numerator = fps_numerator,
            fps_denominator = fps_denominator
        },
        
        enabled = opts.enabled ~= false,
        offline = opts.offline or false,
    }

    clip.name = derive_display_name(clip.id, clip.name)

    setmetatable(clip, {__index = M})
    return clip
end

-- Load clip from database
function M.load(clip_id)
    return load_internal(clip_id, true)
end

function M.load_optional(clip_id)
    return load_internal(clip_id, false)
end

function M.get_sequence_id(clip_id)
    if not clip_id or clip_id == "" then
        error("Clip.get_sequence_id: clip_id is required")
    end

    local database = require("core.database")
    local db = database.get_connection()
    if not db then
        error("Clip.get_sequence_id: No database connection available")
    end

    local stmt = db:prepare([[
        SELECT t.sequence_id
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        WHERE c.id = ?
    ]])

    if not stmt then
        error("Clip.get_sequence_id: Failed to prepare query")
    end

    stmt:bind_value(1, clip_id)

    if not stmt:exec() then
        local err = "unknown error"
        if stmt.last_error then
            local ok, msg = pcall(stmt.last_error, stmt)
            if ok and msg then
                err = msg
            end
        end
        stmt:finalize()
        error(string.format("Clip.get_sequence_id: Query execution failed: %s", err))
    end

    local sequence_id = nil
    if stmt:next() then
        sequence_id = stmt:value(0)
    end

    stmt:finalize()

    if not sequence_id or sequence_id == "" then
        error(string.format("Clip.get_sequence_id: clip_id=%s not found or has no track", tostring(clip_id)))
    end

    return sequence_id
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
                        seq_query:finalize()
                    end
                end
            end
            track_query:finalize()
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
            seq_query:finalize()
        end
    end

    assert(self.project_id, string.format(
        "ensure_project_context: could not derive project_id for clip %s (track_id=%s, source_sequence_id=%s)",
        tostring(self.id), tostring(self.track_id), tostring(self.source_sequence_id)))
end

-- Save clip to database (INSERT or UPDATE)
local function save_internal(self, opts)
    local database = require("core.database")
    local db = database.get_connection()
    assert(db, "Clip.save: No database connection available")

    opts = opts or {}

    assert(self.id and self.id ~= "", "Clip.save: clip id is required")

    -- Verify Invariants: coordinates must be integers
    assert(type(self.timeline_start) == "number", "Clip.save: timeline_start must be integer (got " .. type(self.timeline_start) .. ")")
    assert(type(self.duration) == "number", "Clip.save: duration must be integer (got " .. type(self.duration) .. ")")
    assert(type(self.source_in) == "number", "Clip.save: source_in must be integer (got " .. type(self.source_in) .. ")")
    assert(type(self.source_out) == "number", "Clip.save: source_out must be integer (got " .. type(self.source_out) .. ")")

    ensure_project_context(self, db)
    assert(self.clip_kind, "Clip.save: clip_kind is required for clip " .. tostring(self.id))
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
    exists_query:finalize()

    -- OCCLUSION LOGIC (Temporarily Disabled/Modified for Rational)
    -- ClipMutator needs to be updated to handle Rational before we re-enable this fully.
    -- For now, we pass if skip_occlusion is true, or warn.
    local skip_occlusion = opts.skip_occlusion == true
    local occlusion_actions = nil
    
    -- TODO: Update ClipMutator to use Rational
    -- if not skip_occlusion and self.track_id then ... end

    -- Coordinates are now plain integers - no .frames access needed
    local db_start_frame = self.timeline_start
    local db_duration_frames = self.duration
    local db_source_in_frame = self.source_in
    local db_source_out_frame = self.source_out
    
    local db_fps_num = self.rate.fps_numerator
    local db_fps_den = self.rate.fps_denominator
    
    local query
    local krono_exists = (krono_enabled and krono_start and krono.now and krono.now()) or nil
    if exists then
        query = db:prepare([[
            UPDATE clips
            SET project_id = ?, clip_kind = ?, name = ?, track_id = ?, media_id = ?,
                source_sequence_id = ?, parent_clip_id = ?, owner_sequence_id = ?,
                timeline_start_frame = ?, duration_frames = ?, source_in_frame = ?, source_out_frame = ?,
                fps_numerator = ?, fps_denominator = ?, enabled = ?, offline = ?, modified_at = strftime('%s','now')
            WHERE id = ?
        ]])
    else
        query = db:prepare([[
            INSERT INTO clips (
                id, project_id, clip_kind, name, track_id, media_id,
                source_sequence_id, parent_clip_id, owner_sequence_id,
                timeline_start_frame, duration_frames, source_in_frame, source_out_frame, 
                fps_numerator, fps_denominator, enabled, offline, created_at, modified_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%s','now'), strftime('%s','now'))
        ]])
    end

    assert(query, "Clip.save: Failed to prepare query for clip " .. tostring(self.id))

    if exists then
        query:bind_value(1, self.project_id)
        query:bind_value(2, self.clip_kind)
        query:bind_value(3, self.name or "")
        query:bind_value(4, self.track_id)
        query:bind_value(5, self.media_id)
        query:bind_value(6, self.source_sequence_id)
        query:bind_value(7, self.parent_clip_id)
        query:bind_value(8, self.owner_sequence_id)
        query:bind_value(9, db_start_frame)
        query:bind_value(10, db_duration_frames)
        query:bind_value(11, db_source_in_frame)
        query:bind_value(12, db_source_out_frame)
        query:bind_value(13, db_fps_num)
        query:bind_value(14, db_fps_den)
        query:bind_value(15, self.enabled and 1 or 0)
        query:bind_value(16, self.offline and 1 or 0)
        query:bind_value(17, self.id)
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
        query:bind_value(10, db_start_frame)
        query:bind_value(11, db_duration_frames)
        query:bind_value(12, db_source_in_frame)
        query:bind_value(13, db_source_out_frame)
        query:bind_value(14, db_fps_num)
        query:bind_value(15, db_fps_den)
        query:bind_value(16, self.enabled and 1 or 0)
        query:bind_value(17, self.offline and 1 or 0)
    end

    local krono_exec = (krono_enabled and krono_exists and krono.now and krono.now()) or nil
    if not query:exec() then
        local err = query:last_error()
        query:finalize()
        error(string.format("Clip.save: Failed to save clip %s: %s", tostring(self.id), err))
    end
    
    query:finalize()

    if krono_enabled and krono_start and krono_exists and krono_exec then
        local total_ms = (krono_exec - krono_start)
        logger.debug("clip", string.format("Clip.save[%s]: %.2fms (exists=%.2fms run=%.2fms)",
            tostring(self.id:sub(1,8)), total_ms,
            krono_exists - krono_start, krono_exec - krono_exists))
    end

    return true, occlusion_actions
end

function M:save(opts)
    return save_internal(self, opts or {})
end

function M:restore_without_occlusion()
    return save_internal(self, {skip_occlusion = true})
end

-- Delete clip from database
function M:delete()
    local database = require("core.database")
    local db = database.get_connection()
    assert(db, "Clip.delete: No database connection available")

    local query = db:prepare("DELETE FROM clips WHERE id = ?")
    query:bind_value(1, self.id)

    if not query:exec() then
        local err = query:last_error()
        query:finalize()
        error(string.format("Clip.delete: Failed to delete clip %s: %s", tostring(self.id), err))
    end
    
    query:finalize()

    return true
end

-- Property getters/setters (for generic property access)
function M:get_property(property_name)
    -- Map new names to old if necessary, but here we just return what's there
    return self[property_name]
end

function M:set_property(property_name, value)
    self[property_name] = value
end

--- Find a clip on a track that contains a given timeline time
-- A clip contains time T if: timeline_start <= T < timeline_start + duration
-- @param track_id string: Track ID to search
-- @param time_frames number: Timeline frame position to check
-- @return Clip or nil: First enabled clip containing the time, or nil
function M.find_at_time(track_id, time_frames)
    assert(track_id and track_id ~= "", "Clip.find_at_time: track_id is required")
    assert(type(time_frames) == "number", "Clip.find_at_time: time_frames must be a number")

    local database = require("core.database")
    local db = database.get_connection()
    if not db then
        logger.warn("clip", "Clip.find_at_time: No database connection available")
        return nil
    end

    local stmt = db:prepare([[
        SELECT id FROM clips
        WHERE track_id = ?
          AND timeline_start_frame <= ?
          AND (timeline_start_frame + duration_frames) > ?
          AND enabled = 1
        LIMIT 1
    ]])

    if not stmt then
        logger.warn("clip", "Clip.find_at_time: Failed to prepare query")
        return nil
    end

    stmt:bind_value(1, track_id)
    stmt:bind_value(2, time_frames)
    stmt:bind_value(3, time_frames)

    local clip_id = nil
    if stmt:exec() and stmt:next() then
        clip_id = stmt:value(0)
    end
    stmt:finalize()

    if not clip_id then
        return nil
    end

    return M.load(clip_id)
end

--- Get sequences where a master clip is used (has timeline clips)
-- @param master_clip_id string: The master clip ID to check
-- @return table: Array of {sequence_id, sequence_name, clip_count} for each affected sequence
function M.get_master_clip_usage(master_clip_id)
    assert(master_clip_id and master_clip_id ~= "", "Clip.get_master_clip_usage: missing master_clip_id")

    local database = require("core.database")
    local db = database.get_connection()
    if not db then
        logger.warn("clip", "Clip.get_master_clip_usage: No database connection available")
        return {}
    end

    -- Get the master clip's source sequence (to exclude it from results)
    local master = M.load_optional(master_clip_id)
    local source_seq_id = master and master.source_sequence_id or ""

    -- Find all sequences that have timeline clips referencing this master clip
    local query = db:prepare([[
        SELECT s.id, s.name, COUNT(c.id) as clip_count
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        JOIN sequences s ON t.sequence_id = s.id
        WHERE c.parent_clip_id = ?
          AND c.clip_kind = 'timeline'
          AND (c.owner_sequence_id IS NULL OR c.owner_sequence_id <> ?)
        GROUP BY s.id, s.name
        ORDER BY s.name
    ]])

    if not query then
        logger.warn("clip", "Clip.get_master_clip_usage: Failed to prepare query")
        return {}
    end

    query:bind_value(1, master_clip_id)
    query:bind_value(2, source_seq_id)

    local results = {}
    if query:exec() then
        while query:next() do
            table.insert(results, {
                sequence_id = query:value(0),
                sequence_name = query:value(1),
                clip_count = query:value(2),
            })
        end
    end
    query:finalize()

    return results
end

-- =============================================================================
-- DOMAIN METHODS
-- =============================================================================

--- Set source_in position and save to database
-- @param pos number New source_in value (in this clip's native units)
function M:set_in(pos)
    assert(type(pos) == "number", "Clip:set_in: pos must be a number")
    self.source_in = pos
    self:save()
end

--- Set source_out position and save to database
-- @param pos number New source_out value (in this clip's native units)
function M:set_out(pos)
    assert(type(pos) == "number", "Clip:set_out: pos must be a number")
    self.source_out = pos
    self:save()
end

return M
