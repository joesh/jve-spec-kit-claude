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
local log = require("core.logger").for_area("timeline")

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

-- Forward-declare so load_masterclip_stream can call it
local load_internal

--- IS-a: a masterclip is both a sequence and a clip. When the caller asks for
--- a clip by masterclip sequence ID, resolve to the first stream clip inside
--- that sequence. This is the ONE place that handles the dual identity.
local function load_masterclip_stream(db, seq_id)
    -- Check if this ID is a masterclip sequence
    local seq_stmt = db:prepare("SELECT kind FROM sequences WHERE id = ?")
    if not seq_stmt then return nil end
    seq_stmt:bind_value(1, seq_id)
    if not seq_stmt:exec() or not seq_stmt:next() then
        seq_stmt:finalize()
        return nil
    end
    local kind = seq_stmt:value(0)
    seq_stmt:finalize()
    if kind ~= "masterclip" then return nil end

    -- Find the first stream clip in this masterclip sequence
    local clip_stmt = db:prepare([[
        SELECT c.id FROM clips c
        JOIN tracks t ON c.track_id = t.id
        WHERE t.sequence_id = ? AND c.clip_kind = 'master'
        ORDER BY t.track_type DESC, t.track_index ASC
        LIMIT 1
    ]])
    if not clip_stmt then return nil end
    clip_stmt:bind_value(1, seq_id)
    if not clip_stmt:exec() or not clip_stmt:next() then
        clip_stmt:finalize()
        return nil
    end
    local stream_clip_id = clip_stmt:value(0)
    clip_stmt:finalize()

    -- Load the stream clip via the normal path (recursive call is safe —
    -- the stream clip exists in the clips table, so it won't recurse again).
    local clip = load_internal(stream_clip_id, false)
    if clip then
        -- Override master_clip_id to be the sequence ID (IS-a identity)
        clip.master_clip_id = seq_id
    end
    return clip
end

load_internal = function(clip_id, raise_errors)
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
               c.master_clip_id, c.owner_sequence_id,
               c.timeline_start_frame, c.duration_frames, c.source_in_frame, c.source_out_frame,
               c.fps_numerator, c.fps_denominator, c.enabled, c.offline,
               s.fps_numerator, s.fps_denominator,
               c.mark_in_frame, c.mark_out_frame, c.playhead_frame,
               c.volume
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
        query:finalize()
        -- IS-a: masterclip IS a sequence. If not found in clips table,
        -- check if it's a masterclip sequence and return its first stream clip.
        -- This is THE one place that handles the IS-a lookup transparency.
        local mc_clip = load_masterclip_stream(db, clip_id)
        if mc_clip then return mc_clip end
        if raise_errors then
            error(string.format("Clip.load_failed: Clip not found: %s", clip_id))
        end
        return nil
    end

    local clip_kind = query:value(2)
    local fps_numerator = query:value(12)
    local fps_denominator = query:value(13)
    local sequence_fps_numerator = query:value(16)
    local sequence_fps_denominator = query:value(17)
    
    -- Enforce Rate existence (Strict V5)
    if not fps_numerator or fps_numerator <= 0 then 
        query:finalize()
        error(string.format("Clip.load_failed: Clip %s has invalid frame rate (%s)", clip_id, tostring(fps_numerator)))
    end
    if not fps_denominator or fps_denominator <= 0 then
        query:finalize()
        error(string.format("Clip.load_failed: Clip %s has invalid frame rate denominator (%s)", clip_id, tostring(fps_denominator)))
    end

    if clip_kind ~= "master" then
        if not sequence_fps_numerator or not sequence_fps_denominator then
            query:finalize()
            error(string.format("Clip.load_failed: Clip %s missing owning sequence frame rate", clip_id))
        end
        if sequence_fps_numerator <= 0 or sequence_fps_denominator <= 0 then
            query:finalize()
            error(string.format("Clip.load_failed: Clip %s has invalid owning sequence frame rate (%s/%s)", clip_id, tostring(sequence_fps_numerator), tostring(sequence_fps_denominator)))
        end
    end

    local clip = {
        id = query:value(0),
        project_id = query:value(1),
        clip_kind = clip_kind,
        name = query:value(3),
        track_id = query:value(4),
        media_id = query:value(5),
        master_clip_id = query:value(6),
        owner_sequence_id = query:value(7),

        -- Integer frame coordinates (fps is metadata in clip.rate and sequence.frame_rate)
        timeline_start = assert(query:value(8), "Clip.load: timeline_start_frame is NULL"),
        duration = assert(query:value(9), "Clip.load: duration_frames is NULL"),
        source_in = assert(query:value(10), "Clip.load: source_in_frame is NULL"),
        source_out = assert(query:value(11), "Clip.load: source_out_frame is NULL"),

        -- Store rate explicitly
        rate = {
            fps_numerator = fps_numerator,
            fps_denominator = fps_denominator
        },

        enabled = query:value(14) == 1 or query:value(14) == true,
        offline = false,  -- transient: recomputed by media_status registry

        -- Source viewer state (nullable marks + playhead)
        mark_in = query:value(18),           -- nil when NULL
        mark_out = query:value(19),          -- nil when NULL
        playhead_frame = assert(query:value(20) ~= nil and query:value(20),
            string.format("Clip.load: playhead_frame is NULL for clip %s (NOT NULL column)",
                tostring(query:value(0)))),

        -- Audio mixer state (clip gain, applied before track fader)
        volume = assert(query:value(21) ~= nil and query:value(21),
            string.format("Clip.load: volume is NULL for clip %s (NOT NULL DEFAULT 1.0 column)",
                tostring(query:value(0)))),
    }
    
    query:finalize()

    clip.name = derive_display_name(clip.id, clip.name)

    setmetatable(clip, {__index = M})
    return clip
end

-- Create a new Clip instance.
--
-- Two calling conventions:
--  1. Positional (legacy, pre-013): Clip.create(name, media_id, opts) →
--     returns an unpersisted Clip object for :save() chaining.
--  2. Table form (013, direct DB insert): Clip.create(fields) → inserts a V9
--     clips row and returns its id as a string. Enforces INV-2 via the
--     schema trigger + INV-4 via model-layer check.
function M.create(arg1, media_id_or_nil, opts_or_nil)
    if type(arg1) == "table" and arg1.nested_sequence_id ~= nil then
        return M._create_v13_row(arg1)
    end
    -- Legacy positional path.
    local name = arg1
    local media_id = media_id_or_nil
    local opts = opts_or_nil or {}

    local now = os.time()

    -- FAIL FAST: fps is required - no silent fallbacks that hide bugs
    assert(opts.fps_numerator, "Clip.create: fps_numerator is required")
    assert(opts.fps_denominator, "Clip.create: fps_denominator is required")
    local fps_numerator = opts.fps_numerator
    local fps_denominator = opts.fps_denominator

    -- FAIL FAST: Check for legacy keys
    if opts.start_value or opts.duration_value or opts.source_in_value or opts.source_out_value then
        error("Clip.create: Legacy field names (start_value, etc.) are NOT allowed. Use Rational objects.")
    end

    local clip_kind = opts.clip_kind or "timeline"

    -- FAIL FAST: timeline clips require structural fields
    if clip_kind == "timeline" then
        assert(opts.track_id and opts.track_id ~= "",
            "Clip.create: track_id is required for timeline clips")
        assert(opts.owner_sequence_id and opts.owner_sequence_id ~= "",
            "Clip.create: owner_sequence_id is required for timeline clips")
        -- Auto-resolve master_clip_id from media_id if not provided
        if not opts.master_clip_id or opts.master_clip_id == "" then
            assert(media_id and media_id ~= "",
                "Clip.create: media_id is required to auto-resolve master_clip_id")
            assert(opts.project_id and opts.project_id ~= "",
                "Clip.create: project_id is required to auto-resolve master_clip_id")
            local Sequence = require("models.sequence")
            opts.master_clip_id = Sequence.ensure_masterclip(media_id, opts.project_id, {
                bin_id = opts.bin_id,
            })
        end
    end

    local clip = {
        id = opts.id or uuid.generate(),
        project_id = opts.project_id,
        clip_kind = clip_kind,
        name = name,
        track_id = opts.track_id,
        media_id = media_id,
        master_clip_id = opts.master_clip_id,
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
        offline = false,  -- transient: recomputed by media_status registry

        -- Audio mixer state (clip gain, applied before track fader)
        -- Domain default, not a fallback: new clips start at unity gain (0dB).
        -- DRP import passes explicit volume from parsed data.
        volume = opts.volume or 1.0,

        -- Source viewer state (nullable marks + playhead)
        mark_in = opts.mark_in,           -- nil = no mark
        mark_out = opts.mark_out,         -- nil = no mark
        playhead_frame = (opts.playhead_frame == nil) and 0 or opts.playhead_frame,
    }

    -- Validate mark fields: nil is valid (no mark), but non-nil must be integer
    if clip.mark_in ~= nil then
        assert(type(clip.mark_in) == "number",
            string.format("Clip.create: mark_in must be integer or nil (got %s)", type(clip.mark_in)))
    end
    if clip.mark_out ~= nil then
        assert(type(clip.mark_out) == "number",
            string.format("Clip.create: mark_out must be integer or nil (got %s)", type(clip.mark_out)))
    end
    assert(type(clip.playhead_frame) == "number",
        string.format("Clip.create: playhead_frame must be integer (got %s)", type(clip.playhead_frame)))

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

    -- Fallback: derive from masterclip sequence if present
    if not self.project_id and self.master_clip_id then
        local seq_query = db:prepare("SELECT project_id FROM sequences WHERE id = ?")
        if seq_query then
            seq_query:bind_value(1, self.master_clip_id)
            if seq_query:exec() and seq_query:next() then
                self.project_id = seq_query:value(0)
            end
            seq_query:finalize()
        end
    end

    assert(self.project_id, string.format(
        "ensure_project_context: could not derive project_id for clip %s (track_id=%s, master_clip_id=%s)",
        tostring(self.id), tostring(self.track_id), tostring(self.master_clip_id)))
end

-- Save clip to database (INSERT or UPDATE)
-- opts.skip_occlusion: when true, skip occlusion checks (currently disabled, will be used when re-enabled)
local function save_internal(self, _opts)
    local database = require("core.database")
    local db = database.get_connection()
    assert(db, "Clip.save: No database connection available")

    assert(self.id and self.id ~= "", "Clip.save: clip id is required")

    -- Verify Invariants: coordinates must be integers
    assert(type(self.timeline_start) == "number", "Clip.save: timeline_start must be integer (got " .. type(self.timeline_start) .. ")")
    assert(type(self.duration) == "number", "Clip.save: duration must be integer (got " .. type(self.duration) .. ")")
    assert(type(self.source_in) == "number", "Clip.save: source_in must be integer (got " .. type(self.source_in) .. ")")
    assert(type(self.source_out) == "number", "Clip.save: source_out must be integer (got " .. type(self.source_out) .. ")")

    -- Verify volume
    assert(type(self.volume) == "number" and self.volume >= 0,
        string.format("Clip.save: volume must be non-negative number (got %s=%s) for clip %s",
            type(self.volume), tostring(self.volume), tostring(self.id)))

    -- Verify mark field types (nullable marks must be number or nil)
    if self.mark_in ~= nil then
        assert(type(self.mark_in) == "number",
            string.format("Clip.save: mark_in must be integer or nil (got %s) for clip %s",
                type(self.mark_in), tostring(self.id)))
    end
    if self.mark_out ~= nil then
        assert(type(self.mark_out) == "number",
            string.format("Clip.save: mark_out must be integer or nil (got %s) for clip %s",
                type(self.mark_out), tostring(self.id)))
    end
    assert(type(self.playhead_frame) == "number",
        string.format("Clip.save: playhead_frame must be number (got %s) for clip %s",
            type(self.playhead_frame), tostring(self.id)))

    -- Source ordering convention: source_out >= source_in is forward;
    -- source_out < source_in is a reverse clip. Both are valid states.
    -- Full cross-operation source_out consistency is validated by
    -- project_validator, not here.

    ensure_project_context(self, db)
    assert(self.clip_kind, "Clip.save: clip_kind is required for clip " .. tostring(self.id))
    self.offline = false  -- transient: never persist to DB
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

    -- OCCLUSION LOGIC (Temporarily Disabled)
    -- TODO: Update ClipMutator to handle occlusion properly
    -- opts.skip_occlusion controls whether to skip occlusion checks (when re-enabled)
    local occlusion_actions = nil

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
                master_clip_id = ?, owner_sequence_id = ?,
                timeline_start_frame = ?, duration_frames = ?, source_in_frame = ?, source_out_frame = ?,
                fps_numerator = ?, fps_denominator = ?, enabled = ?, offline = ?,
                volume = ?,
                mark_in_frame = ?, mark_out_frame = ?, playhead_frame = ?,
                modified_at = strftime('%s','now')
            WHERE id = ?
        ]])
    else
        query = db:prepare([[
            INSERT INTO clips (
                id, project_id, clip_kind, name, track_id, media_id,
                master_clip_id, owner_sequence_id,
                timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                fps_numerator, fps_denominator, enabled, offline,
                volume,
                mark_in_frame, mark_out_frame, playhead_frame,
                created_at, modified_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%s','now'), strftime('%s','now'))
        ]])
    end

    assert(query, "Clip.save: Failed to prepare query for clip " .. tostring(self.id))

    -- Helper: bind nullable integer (mark_in, mark_out are nullable)
    local function bind_nullable(stmt, idx, val)
        if val ~= nil then
            stmt:bind_value(idx, val)
        elseif stmt.bind_null then
            stmt:bind_null(idx)
        else
            stmt:bind_value(idx, nil)
        end
    end

    if exists then
        query:bind_value(1, self.project_id)
        query:bind_value(2, self.clip_kind)
        query:bind_value(3, self.name or "")
        query:bind_value(4, self.track_id)
        query:bind_value(5, self.media_id)
        query:bind_value(6, self.master_clip_id)
        query:bind_value(7, self.owner_sequence_id)
        query:bind_value(8, db_start_frame)
        query:bind_value(9, db_duration_frames)
        query:bind_value(10, db_source_in_frame)
        query:bind_value(11, db_source_out_frame)
        query:bind_value(12, db_fps_num)
        query:bind_value(13, db_fps_den)
        query:bind_value(14, self.enabled and 1 or 0)
        query:bind_value(15, self.offline and 1 or 0)
        query:bind_value(16, self.volume)
        bind_nullable(query, 17, self.mark_in)
        bind_nullable(query, 18, self.mark_out)
        query:bind_value(19, self.playhead_frame)
        query:bind_value(20, self.id)
    else
        query:bind_value(1, self.id)
        query:bind_value(2, self.project_id)
        query:bind_value(3, self.clip_kind)
        query:bind_value(4, self.name or "")
        query:bind_value(5, self.track_id)
        query:bind_value(6, self.media_id)
        query:bind_value(7, self.master_clip_id)
        query:bind_value(8, self.owner_sequence_id)
        query:bind_value(9, db_start_frame)
        query:bind_value(10, db_duration_frames)
        query:bind_value(11, db_source_in_frame)
        query:bind_value(12, db_source_out_frame)
        query:bind_value(13, db_fps_num)
        query:bind_value(14, db_fps_den)
        query:bind_value(15, self.enabled and 1 or 0)
        query:bind_value(16, self.offline and 1 or 0)
        query:bind_value(17, self.volume)
        bind_nullable(query, 18, self.mark_in)
        bind_nullable(query, 19, self.mark_out)
        query:bind_value(20, self.playhead_frame)
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
        log.detail("Clip.save[%s]: %.2fms (exists=%.2fms run=%.2fms)",
            tostring(self.id:sub(1,8)), total_ms,
            krono_exists - krono_start, krono_exec - krono_exists)
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

    -- Clean up properties and clip_links (no FK cascade on these tables)
    local prop_stmt = db:prepare("DELETE FROM properties WHERE clip_id = ?")
    if prop_stmt then
        prop_stmt:bind_value(1, self.id)
        prop_stmt:exec()
        prop_stmt:finalize()
    end
    local link_stmt = db:prepare("DELETE FROM clip_links WHERE clip_id = ?")
    if link_stmt then
        link_stmt:bind_value(1, self.id)
        link_stmt:exec()
        link_stmt:finalize()
    end

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
        log.warn("Clip.find_at_time: No database connection available")
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
        log.warn("Clip.find_at_time: Failed to prepare query")
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
        log.warn("Clip.get_master_clip_usage: No database connection available")
        return {}
    end

    -- Find all sequences that have timeline clips referencing this masterclip
    local query = db:prepare([[
        SELECT s.id, s.name, COUNT(c.id) as clip_count
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        JOIN sequences s ON t.sequence_id = s.id
        WHERE c.master_clip_id = ?
          AND c.clip_kind = 'timeline'
        GROUP BY s.id, s.name
        ORDER BY s.name
    ]])

    if not query then
        log.warn("Clip.get_master_clip_usage: Failed to prepare query")
        return {}
    end

    query:bind_value(1, master_clip_id)

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
-- TRACK-RELATIVE QUERY METHODS (for engine lookahead / pre-buffering)
-- =============================================================================

--- Find the next enabled clip on a track starting at or after a given frame.
-- @param track_id string: Track ID to search
-- @param after_frame number: Timeline frame position (inclusive lower bound)
-- @return Clip or nil
function M.find_next_on_track(track_id, after_frame)
    assert(track_id and track_id ~= "", "Clip.find_next_on_track: track_id is required")
    assert(type(after_frame) == "number", "Clip.find_next_on_track: after_frame must be a number")

    local database = require("core.database")
    local db = database.get_connection()
    assert(db, "Clip.find_next_on_track: no database connection")

    local stmt = db:prepare([[
        SELECT id FROM clips
        WHERE track_id = ?
          AND timeline_start_frame >= ?
          AND enabled = 1
        ORDER BY timeline_start_frame ASC
        LIMIT 1
    ]])
    assert(stmt, "Clip.find_next_on_track: failed to prepare query")

    stmt:bind_value(1, track_id)
    stmt:bind_value(2, after_frame)

    local clip_id = nil
    if stmt:exec() and stmt:next() then
        clip_id = stmt:value(0)
    end
    stmt:finalize()

    if not clip_id then return nil end
    return M.load(clip_id)
end

--- Find the previous enabled clip on a track ending at or before a given frame.
-- "Ending at" means (timeline_start + duration) <= before_frame.
-- @param track_id string: Track ID to search
-- @param before_frame number: Timeline frame position (inclusive upper bound for clip end)
-- @return Clip or nil
function M.find_prev_on_track(track_id, before_frame)
    assert(track_id and track_id ~= "", "Clip.find_prev_on_track: track_id is required")
    assert(type(before_frame) == "number", "Clip.find_prev_on_track: before_frame must be a number")

    local database = require("core.database")
    local db = database.get_connection()
    assert(db, "Clip.find_prev_on_track: no database connection")

    local stmt = db:prepare([[
        SELECT id FROM clips
        WHERE track_id = ?
          AND (timeline_start_frame + duration_frames) <= ?
          AND enabled = 1
        ORDER BY timeline_start_frame DESC
        LIMIT 1
    ]])
    assert(stmt, "Clip.find_prev_on_track: failed to prepare query")

    stmt:bind_value(1, track_id)
    stmt:bind_value(2, before_frame)

    local clip_id = nil
    if stmt:exec() and stmt:next() then
        clip_id = stmt:value(0)
    end
    stmt:finalize()

    if not clip_id then return nil end
    return M.load(clip_id)
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

--- Find the master clip for a given media_id.
-- @param media_id string
-- @return Clip|nil master clip, or nil if none
function M.find_master_clip_for_media(media_id)
    assert(media_id and media_id ~= "", "Clip.find_master_clip_for_media: media_id required")

    local database = require("core.database")
    local db = assert(database.get_connection(), "Clip.find_master_for_media: no database connection")

    local stmt = assert(db:prepare([[
        SELECT id FROM clips
        WHERE media_id = ? AND clip_kind = 'master'
        LIMIT 1
    ]]), "Clip.find_master_for_media: failed to prepare query")

    stmt:bind_value(1, media_id)
    assert(stmt:exec(), "Clip.find_master_for_media: query exec failed")

    if not stmt:next() then
        stmt:finalize()
        return nil
    end

    local clip_id = stmt:value(0)
    stmt:finalize()
    return M.load(clip_id)
end

--- Find all clips (master + timeline) referencing a given media_id.
-- @param media_id string
-- @return table Array of Clip objects
function M.find_clips_for_media(media_id)
    assert(media_id and media_id ~= "", "Clip.find_clips_for_media: media_id required")

    local database = require("core.database")
    local db = assert(database.get_connection(), "Clip.find_clips_for_media: no database connection")

    local stmt = assert(db:prepare([[
        SELECT id FROM clips WHERE media_id = ?
    ]]), "Clip.find_clips_for_media: failed to prepare query")

    stmt:bind_value(1, media_id)
    assert(stmt:exec(), "Clip.find_clips_for_media: query exec failed")

    local clips = {}
    while stmt:next() do
        local clip = M.load(stmt:value(0))
        if clip then clips[#clips + 1] = clip end
    end
    stmt:finalize()
    return clips
end

--- Update source_in and source_out and persist.
-- @param source_in number New source_in (native units)
-- @param source_out number New source_out (native units)
function M:set_source_range(source_in, source_out)
    assert(type(source_in) == "number", "Clip:set_source_range: source_in must be a number")
    assert(type(source_out) == "number", "Clip:set_source_range: source_out must be a number")
    self.source_in = source_in
    self.source_out = source_out
    self:save()
end

--- Read lightweight source state for multiple clips (no JOINs).
-- @param clip_ids table Array or set of clip IDs
-- @return table {clip_id → {media_id, source_in, source_out}}
function M.batch_read_source(clip_ids)
    local database = require("core.database")
    local db = assert(database.get_connection(), "Clip.batch_read_source: no database connection")

    local stmt = assert(db:prepare(
        "SELECT media_id, source_in_frame, source_out_frame FROM clips WHERE id = ?"),
        "Clip.batch_read_source: failed to prepare query")

    local result = {}
    for clip_id in pairs(clip_ids) do
        stmt:bind_value(1, clip_id)
        assert(stmt:exec(), "Clip.batch_read_source: exec failed for " .. clip_id)
        assert(stmt:next(), "Clip.batch_read_source: clip not found: " .. clip_id)
        local mid = stmt:value(0)
        assert(mid, string.format(
            "Clip.batch_read_source: clip %s has NULL media_id", clip_id))
        result[clip_id] = {
            media_id = mid,
            source_in = stmt:value(1),
            source_out = stmt:value(2),
        }
        stmt:reset()
    end
    stmt:finalize()
    return result
end

--- Batch update media_id + source range for multiple clips.
-- @param updates table {clip_id → {media_id, source_in, source_out}}
function M.batch_update_source(updates)
    local database = require("core.database")
    local db = assert(database.get_connection(), "Clip.batch_update_source: no database connection")

    local stmt = assert(db:prepare([[
        UPDATE clips SET media_id = ?, source_in_frame = ?, source_out_frame = ?,
            modified_at = strftime('%s','now') WHERE id = ?
    ]]), "Clip.batch_update_source: failed to prepare query")

    for clip_id, vals in pairs(updates) do
        assert(vals.media_id, "Clip.batch_update_source: media_id required for " .. clip_id)
        assert(vals.source_in, "Clip.batch_update_source: source_in required for " .. clip_id)
        assert(vals.source_out, "Clip.batch_update_source: source_out required for " .. clip_id)
        stmt:bind_value(1, vals.media_id)
        stmt:bind_value(2, vals.source_in)
        stmt:bind_value(3, vals.source_out)
        stmt:bind_value(4, clip_id)
        assert(stmt:exec(), "Clip.batch_update_source: exec failed for " .. clip_id)
        stmt:reset()
    end
    stmt:finalize()
end

-- ===========================================================================
-- Feature 013: V9 clips row shape
-- ===========================================================================
-- Rows in the V9 `clips` table hold references to other sequences via
-- `nested_sequence_id`. INV-2 says owner_sequence_id must be kind='nested'
-- (enforced by the schema trigger). INV-4 says the window [source_in,
-- source_out] must fit inside the nested sequence's effective duration.

local V13_REQUIRED = {
    "project_id", "owner_sequence_id", "nested_sequence_id",
    "name",
    "timeline_start_frame", "duration_frames",
    "source_in_frame", "source_out_frame",
    "fps_mismatch_policy",
    "enabled", "volume", "playhead_frame",
}

-- Fetch the nested sequence's effective duration in its own timebase. For a
-- 'nested' sequence, this is the max (timeline_start + duration) across its
-- clips; for a 'master', the max across its media_refs. 0 if empty — the
-- INV-4 caller then requires source_in/out to both be 0 (empty window refused
-- separately below).
local function nested_sequence_effective_duration(db, seq_id)
    local stmt = db:prepare([[
        SELECT COALESCE(MAX(timeline_start_frame + duration_frames), 0)
          FROM clips WHERE owner_sequence_id = ?
        UNION ALL
        SELECT COALESCE(MAX(timeline_start_frame + duration_frames), 0)
          FROM media_refs WHERE owner_sequence_id = ?
    ]])
    assert(stmt, "Clip: nested-duration prepare failed")
    stmt:bind_value(1, seq_id)
    stmt:bind_value(2, seq_id)
    assert(stmt:exec(), "Clip: nested-duration exec failed")
    local total = 0
    while stmt:next() do
        local v = stmt:value(0)
        if v and v > total then total = v end
    end
    stmt:finalize()
    return total
end

-- Assert window is in-bounds per INV-4. Loud-fail with the clip id, the
-- offending bounds, and the nested sequence's duration in its timebase
-- (rule 1.14: names everything a caller would need to debug).
local function assert_window_in_bounds(db, clip_id, nested_seq_id, source_in, source_out)
    assert(type(source_in) == "number" and type(source_out) == "number",
        "Clip: source_in/out must be numbers")
    assert(source_in >= 0, string.format(
        "INV-4 violation: clip %s has source_in=%d < 0 (assert_window_in_bounds)",
        tostring(clip_id), source_in))
    assert(source_out > source_in, string.format(
        "INV-4 violation: clip %s has source_in=%d >= source_out=%d (empty/inverted window)",
        tostring(clip_id), source_in, source_out))
    local dur = nested_sequence_effective_duration(db, nested_seq_id)
    assert(source_out <= dur, string.format(
        "INV-4 violation: clip %s has source_out=%d > nested_sequence(%s).duration=%d",
        tostring(clip_id), source_out, tostring(nested_seq_id), dur))
end

local function to_int_bool(v)
    if v == true or v == 1 then return 1 end
    if v == false or v == 0 then return 0 end
    error("Clip: boolean must be true/false or 1/0; got " .. tostring(v))
end

-- Model-layer INV-2 pre-flight: fetch the owner_sequence_id's kind and raise a
-- clear error (rule 1.14) if it isn't 'nested'. This fires BEFORE the schema
-- trigger's generic RAISE(ABORT, ...) which cannot embed the offending value.
local function assert_owner_is_nested(db, clip_id, owner_seq_id)
    local stmt = db:prepare("SELECT kind FROM sequences WHERE id = ?")
    assert(stmt, "Clip: owner-kind prepare failed")
    stmt:bind_value(1, owner_seq_id)
    assert(stmt:exec(), "Clip: owner-kind exec failed")
    local found, kind
    if stmt:next() then
        found = true
        kind = stmt:value(0)
    end
    stmt:finalize()
    assert(found, string.format(
        "Clip: owner_sequence_id=%s not found (clip=%s)",
        tostring(owner_seq_id), tostring(clip_id)))
    assert(kind == "nested", string.format(
        "INV-2 violation in Clip.create: clip=%s owner_sequence_id=%s kind='%s' (expected 'nested')",
        tostring(clip_id), tostring(owner_seq_id), tostring(kind)))
end

function M._create_v13_row(fields)
    assert(type(fields) == "table", "Clip.create (v13): fields table required")
    for _, col in ipairs(V13_REQUIRED) do
        assert(fields[col] ~= nil, string.format(
            "Clip.create (v13): '%s' is required (rule 2.13 — no column defaults)", col))
    end
    local db = require("core.database").get_connection()
    local id = fields.id or uuid.generate()

    assert_owner_is_nested(db, id, fields.owner_sequence_id)
    assert_window_in_bounds(db, id, fields.nested_sequence_id,
        fields.source_in_frame, fields.source_out_frame)

    local now = fields.created_at or os.time()
    local stmt = db:prepare([[
        INSERT INTO clips (
            id, project_id, owner_sequence_id, track_id, nested_sequence_id,
            name, timeline_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, fps_mismatch_policy,
            enabled, volume, mark_in_frame, mark_out_frame, playhead_frame,
            created_at, modified_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    assert(stmt, "Clip._create_v13_row: prepare failed")
    stmt:bind_value(1, id)
    stmt:bind_value(2, fields.project_id)
    stmt:bind_value(3, fields.owner_sequence_id)
    stmt:bind_value(4, fields.track_id)
    stmt:bind_value(5, fields.nested_sequence_id)
    stmt:bind_value(6, fields.name)
    stmt:bind_value(7, fields.timeline_start_frame)
    stmt:bind_value(8, fields.duration_frames)
    stmt:bind_value(9, fields.source_in_frame)
    stmt:bind_value(10, fields.source_out_frame)
    stmt:bind_value(11, fields.master_layer_track_id)  -- nullable
    stmt:bind_value(12, fields.fps_mismatch_policy)
    stmt:bind_value(13, to_int_bool(fields.enabled))
    stmt:bind_value(14, fields.volume)
    stmt:bind_value(15, fields.mark_in_frame)    -- nullable
    stmt:bind_value(16, fields.mark_out_frame)   -- nullable
    stmt:bind_value(17, fields.playhead_frame)
    stmt:bind_value(18, now)
    stmt:bind_value(19, fields.modified_at or now)

    local ok = stmt:exec()
    local err
    if not ok then err = stmt:last_error() end
    stmt:finalize()
    assert(ok, string.format(
        "Clip._create_v13_row: INSERT failed for id=%s: %s (likely INV-2 trigger or FK)",
        id, tostring(err)))
    return id
end

local CLIP_UPDATABLE_V13 = {
    name = true, track_id = true,
    timeline_start_frame = true, duration_frames = true,
    source_in_frame = true, source_out_frame = true,
    master_layer_track_id = true, fps_mismatch_policy = true,
    enabled = true, volume = true,
    mark_in_frame = true, mark_out_frame = true, playhead_frame = true,
}

--- Update a V9 clips row. Enforces INV-4 after the write — if
--- source_in_frame or source_out_frame changes, the new window must still
--- fit the nested sequence's bounds.
function M.update(id, fields)
    assert(type(fields) == "table", "Clip.update: fields table required")
    local db = require("core.database").get_connection()

    -- Fetch the clip to get the nested_sequence_id for INV-4.
    local fetch = db:prepare(
        "SELECT nested_sequence_id, source_in_frame, source_out_frame FROM clips WHERE id = ?")
    assert(fetch, "Clip.update: fetch prepare failed")
    fetch:bind_value(1, id)
    assert(fetch:exec(), "Clip.update: fetch exec failed")
    assert(fetch:next(), string.format("Clip.update: clip %s not found", tostring(id)))
    local nested_id = fetch:value(0)
    local cur_in = fetch:value(1)
    local cur_out = fetch:value(2)
    fetch:finalize()

    local new_in  = fields.source_in_frame  ~= nil and fields.source_in_frame  or cur_in
    local new_out = fields.source_out_frame ~= nil and fields.source_out_frame or cur_out
    if fields.source_in_frame ~= nil or fields.source_out_frame ~= nil then
        assert_window_in_bounds(db, id, nested_id, new_in, new_out)
    end

    local sets, values = {}, {}
    for k, v in pairs(fields) do
        assert(CLIP_UPDATABLE_V13[k], string.format(
            "Clip.update: column '%s' is not updatable (structural)", k))
        sets[#sets + 1] = k .. " = ?"
        if k == "enabled" then
            values[#values + 1] = to_int_bool(v)
        else
            values[#values + 1] = v
        end
    end
    if #sets == 0 then return true end
    sets[#sets + 1] = "modified_at = ?"
    values[#values + 1] = os.time()

    local stmt = db:prepare(string.format(
        "UPDATE clips SET %s WHERE id = ?", table.concat(sets, ", ")))
    assert(stmt, "Clip.update: update prepare failed")
    for i, v in ipairs(values) do stmt:bind_value(i, v) end
    stmt:bind_value(#values + 1, id)
    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, string.format("Clip.update: exec failed for id=%s", id))
    return true
end

-- ===========================================================================
-- Feature 013 (T041): source<->timeline frame conversion under a clip's
-- policy. A single clip stores timeline_start/duration in owner-timebase
-- frames AND source_in/out in nested-timebase frames; to trim by N owner
-- frames you have to shift source bounds by the policy-appropriate ratio.
-- ===========================================================================

--- Convert an owner-timebase delta to the nested-timebase delta for a clip
--- under its own fps_mismatch_policy.
---   resample    : scale by nested.fps / owner.fps (so owner-frame trim
---                 corresponds to the right number of native frames)
---   passthrough : 1:1 (owner frames ARE counted as-if already in owner fps)
--- Uses round-nearest on the multiply, matching the round used at Insert.
--- nested_fps_num/den describe the nested sequence's native timebase.
function M.owner_delta_to_source(policy, owner_delta,
                                 owner_fps_num, owner_fps_den,
                                 nested_fps_num, nested_fps_den)
    assert(type(owner_delta) == "number",
        "Clip.owner_delta_to_source: owner_delta must be integer")
    if policy == "passthrough" then
        return owner_delta
    end
    assert(policy == "resample",
        "Clip.owner_delta_to_source: unknown policy " .. tostring(policy))
    assert(owner_fps_num > 0 and owner_fps_den > 0
       and nested_fps_num > 0 and nested_fps_den > 0,
        "Clip.owner_delta_to_source: invalid fps")
    local ratio = (nested_fps_num / nested_fps_den)
                / (owner_fps_num  / owner_fps_den)
    if owner_delta >= 0 then
        return math.floor(owner_delta * ratio + 0.5)
    end
    return -math.floor(-owner_delta * ratio + 0.5)
end

--- Return every clip on `track_id` that overlaps the owner-timebase range
--- [window_start, window_end), ordered by timeline_start_frame. Each row is
--- a plain table carrying the fields needed to plan an occlusion mutation.
--- Used by Overwrite to compute its remove/trim/split plan.
function M.find_overlapping_on_track(track_id, window_start, window_end)
    assert(track_id and track_id ~= "",
        "Clip.find_overlapping_on_track: track_id required")
    assert(type(window_start) == "number" and type(window_end) == "number",
        "Clip.find_overlapping_on_track: window must be integer pair")
    assert(window_end > window_start,
        "Clip.find_overlapping_on_track: empty/inverted window")

    local db = require("core.database").get_connection()
    local stmt = db:prepare([[
        SELECT id, project_id, owner_sequence_id, track_id, nested_sequence_id,
               name, timeline_start_frame, duration_frames,
               source_in_frame, source_out_frame,
               master_layer_track_id, fps_mismatch_policy,
               enabled, volume, mark_in_frame, mark_out_frame, playhead_frame
        FROM clips
        WHERE track_id = ?
          AND timeline_start_frame < ?
          AND (timeline_start_frame + duration_frames) > ?
        ORDER BY timeline_start_frame ASC
    ]])
    assert(stmt, "Clip.find_overlapping_on_track: prepare failed")
    stmt:bind_value(1, track_id)
    stmt:bind_value(2, window_end)
    stmt:bind_value(3, window_start)
    assert(stmt:exec(), "Clip.find_overlapping_on_track: exec failed")

    local rows = {}
    while stmt:next() do
        rows[#rows + 1] = {
            id                    = stmt:value(0),
            project_id            = stmt:value(1),
            owner_sequence_id     = stmt:value(2),
            track_id              = stmt:value(3),
            nested_sequence_id    = stmt:value(4),
            name                  = stmt:value(5),
            timeline_start_frame  = stmt:value(6),
            duration_frames       = stmt:value(7),
            source_in_frame       = stmt:value(8),
            source_out_frame      = stmt:value(9),
            master_layer_track_id = stmt:value(10),
            fps_mismatch_policy   = stmt:value(11),
            enabled               = stmt:value(12) == 1,
            volume                = stmt:value(13),
            mark_in_frame         = stmt:value(14),
            mark_out_frame        = stmt:value(15),
            playhead_frame        = stmt:value(16),
        }
    end
    stmt:finalize()
    return rows
end

--- Low-level UPDATE: set timeline + duration + source bounds on one clip.
--- INV-4 is re-checked by Clip.update which we delegate to.
function M.update_bounds(id, timeline_start_frame, duration_frames,
                        source_in_frame, source_out_frame)
    return M.update(id, {
        timeline_start_frame = timeline_start_frame,
        duration_frames      = duration_frames,
        source_in_frame      = source_in_frame,
        source_out_frame     = source_out_frame,
    })
end

-- ===========================================================================
-- Feature 013 (T040): ripple + batch operations for Insert's write path.
-- ===========================================================================

--- Shift every clip on `track_id` whose `timeline_start_frame >= from_frame`
--- forward by `shift` frames. Returns the list of clip ids actually shifted
--- (for undo capture). `shift` must be non-zero (rule 2.13).
function M.ripple_track_forward(track_id, from_frame, shift)
    assert(track_id and track_id ~= "",
        "Clip.ripple_track_forward: track_id required")
    assert(type(from_frame) == "number",
        "Clip.ripple_track_forward: from_frame must be integer")
    assert(type(shift) == "number" and shift ~= 0,
        "Clip.ripple_track_forward: shift must be non-zero integer")

    local db = require("core.database").get_connection()
    local sel = db:prepare([[
        SELECT id FROM clips
        WHERE track_id = ? AND timeline_start_frame >= ?
    ]])
    assert(sel, "Clip.ripple_track_forward: select prepare failed")
    sel:bind_value(1, track_id)
    sel:bind_value(2, from_frame)
    assert(sel:exec(), "Clip.ripple_track_forward: select exec failed")
    local ids = {}
    while sel:next() do ids[#ids + 1] = sel:value(0) end
    sel:finalize()

    if #ids == 0 then return ids end

    local upd = db:prepare([[
        UPDATE clips
        SET timeline_start_frame = timeline_start_frame + ?,
            modified_at = strftime('%s','now')
        WHERE track_id = ? AND timeline_start_frame >= ?
    ]])
    assert(upd, "Clip.ripple_track_forward: update prepare failed")
    upd:bind_value(1, shift)
    upd:bind_value(2, track_id)
    upd:bind_value(3, from_frame)
    assert(upd:exec(), "Clip.ripple_track_forward: update exec failed")
    upd:finalize()
    return ids
end

--- Shift a specific set of clips by `delta` frames. Used by undo to reverse
--- a previous ripple without re-querying (the insertion point's new clips
--- would otherwise be swept in). `delta` may be negative.
function M.shift_many_by(clip_ids, delta)
    assert(type(clip_ids) == "table",
        "Clip.shift_many_by: clip_ids table required")
    assert(type(delta) == "number" and delta ~= 0,
        "Clip.shift_many_by: delta must be non-zero integer")
    if #clip_ids == 0 then return end

    local db = require("core.database").get_connection()
    local upd = db:prepare([[
        UPDATE clips
        SET timeline_start_frame = timeline_start_frame + ?,
            modified_at = strftime('%s','now')
        WHERE id = ?
    ]])
    assert(upd, "Clip.shift_many_by: prepare failed")
    for _, cid in ipairs(clip_ids) do
        upd:bind_value(1, delta)
        upd:bind_value(2, cid)
        assert(upd:exec(),
            "Clip.shift_many_by: exec failed for " .. tostring(cid))
        upd:reset()
    end
    upd:finalize()
end

--- Delete clip rows by id. FK ON DELETE CASCADE covers `clip_links`; the
--- `properties` table has no FK and is cleaned here for parity with the
--- instance `:delete()`.
function M.delete_by_ids(clip_ids)
    assert(type(clip_ids) == "table",
        "Clip.delete_by_ids: clip_ids table required")
    if #clip_ids == 0 then return end

    local db = require("core.database").get_connection()
    local del_props = db:prepare("DELETE FROM properties WHERE clip_id = ?")
    local del_clips = db:prepare("DELETE FROM clips WHERE id = ?")
    assert(del_props and del_clips, "Clip.delete_by_ids: prepare failed")
    for _, cid in ipairs(clip_ids) do
        del_props:bind_value(1, cid)
        del_props:exec()
        del_props:reset()
        del_clips:bind_value(1, cid)
        assert(del_clips:exec(),
            "Clip.delete_by_ids: DELETE failed for " .. tostring(cid))
        del_clips:reset()
    end
    del_props:finalize()
    del_clips:finalize()
end

--- Copy all clip_channel_override rows from src_clip_id to dst_clip_id.
--- Used by SplitClip (T045) to preserve per-channel overrides on both
--- halves. Returns the number of rows copied.
function M.copy_channel_overrides(src_clip_id, dst_clip_id)
    assert(src_clip_id and src_clip_id ~= "",
        "Clip.copy_channel_overrides: src required")
    assert(dst_clip_id and dst_clip_id ~= "",
        "Clip.copy_channel_overrides: dst required")
    assert(src_clip_id ~= dst_clip_id,
        "Clip.copy_channel_overrides: src and dst must differ")
    local db = require("core.database").get_connection()
    local sel = db:prepare([[
        SELECT channel_index, enabled, gain_db
        FROM clip_channel_override WHERE clip_id = ?
    ]])
    assert(sel, "Clip.copy_channel_overrides: select prepare failed")
    sel:bind_value(1, src_clip_id)
    assert(sel:exec(), "Clip.copy_channel_overrides: select exec failed")
    local rows = {}
    while sel:next() do
        rows[#rows + 1] = {
            channel_index = sel:value(0),
            enabled       = sel:value(1),
            gain_db       = sel:value(2),
        }
    end
    sel:finalize()
    if #rows == 0 then return 0 end

    local ins = db:prepare([[
        INSERT INTO clip_channel_override (clip_id, channel_index, enabled, gain_db)
        VALUES (?, ?, ?, ?)
    ]])
    assert(ins, "Clip.copy_channel_overrides: insert prepare failed")
    for _, r in ipairs(rows) do
        ins:bind_value(1, dst_clip_id)
        ins:bind_value(2, r.channel_index)
        ins:bind_value(3, r.enabled)
        ins:bind_value(4, r.gain_db)
        assert(ins:exec(),
            "Clip.copy_channel_overrides: insert exec failed")
        ins:reset()
    end
    ins:finalize()
    return #rows
end

--- Delete a single clip row (and cascade via FK/TRIGGER to clip_links
--- and clip_channel_override). Loud on failure. Used by SplitClip undo.
function M.delete_one(clip_id)
    assert(clip_id and clip_id ~= "", "Clip.delete_one: clip_id required")
    local db = require("core.database").get_connection()
    local stmt = db:prepare("DELETE FROM clips WHERE id = ?")
    assert(stmt, "Clip.delete_one: prepare failed")
    stmt:bind_value(1, clip_id)
    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, string.format("Clip.delete_one: exec failed for id=%s", clip_id))
end

--- Load a V9 clips row as a plain table (no legacy JOINs — purely this
--- row's columns). Used by Insert's __timeline_mutations builder to
--- re-read a freshly-inserted clip for the UI cache.
function M.load_v13_row(id)
    assert(id and id ~= "", "Clip.load_v13_row: id required")
    local db = require("core.database").get_connection()
    local stmt = db:prepare([[
        SELECT id, project_id, owner_sequence_id, track_id, nested_sequence_id,
               name, timeline_start_frame, duration_frames,
               source_in_frame, source_out_frame,
               master_layer_track_id, fps_mismatch_policy,
               enabled, volume, mark_in_frame, mark_out_frame, playhead_frame
        FROM clips WHERE id = ?
    ]])
    assert(stmt, "Clip.load_v13_row: prepare failed")
    stmt:bind_value(1, id)
    assert(stmt:exec(), "Clip.load_v13_row: exec failed")
    local row
    if stmt:next() then
        row = {
            id                    = stmt:value(0),
            project_id            = stmt:value(1),
            owner_sequence_id     = stmt:value(2),
            track_id              = stmt:value(3),
            nested_sequence_id    = stmt:value(4),
            name                  = stmt:value(5),
            timeline_start_frame  = stmt:value(6),
            duration_frames       = stmt:value(7),
            source_in_frame       = stmt:value(8),
            source_out_frame      = stmt:value(9),
            master_layer_track_id = stmt:value(10),
            fps_mismatch_policy   = stmt:value(11),
            enabled               = stmt:value(12) == 1,
            volume                = stmt:value(13),
            mark_in_frame         = stmt:value(14),
            mark_out_frame        = stmt:value(15),
            playhead_frame        = stmt:value(16),
        }
    end
    stmt:finalize()
    return row
end

return M
