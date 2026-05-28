--- Clip model: Lua wrapper around clip database operations
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

-- V13: pre-013 had a load_masterclip_stream helper that resolved a
-- master-sequence id to its "first stream clip" so callers could treat
-- a masterclip as either a sequence OR a clip (IS-a). V13 master
-- sequences hold media_refs (not clips), so that helper has no analog
-- and is gone. Callers needing media metadata for a master sequence
-- query media_refs directly via Sequence.find_master_for_media or the
-- resolver chain.

-- ============================================================================
-- Clip.load phase helpers
-- ============================================================================

-- V13 SELECT: clips no longer carry clip_kind / media_id / master_clip_id /
-- fps_numerator / fps_denominator / offline. The clip's source-side
-- timebase comes from its nested sequence; clip_kind is derived from the
-- owner-track type; media metadata is resolved through nested → master →
-- media_ref → media when nested is a master.
local CLIP_LOAD_SQL = [[
    SELECT c.id, c.project_id, c.name, c.track_id,
           c.owner_sequence_id, c.sequence_id,
           c.sequence_start_frame, c.duration_frames,
           c.source_in_frame, c.source_out_frame,
           c.master_layer_track_id, c.master_audio_track_id,
           c.fps_mismatch_policy,
           c.enabled, c.volume, c.mark_in_frame, c.mark_out_frame,
           c.playhead_frame, c.created_at, c.modified_at,
           t.track_type,
           owner_seq.fps_numerator, owner_seq.fps_denominator,
           nested_seq.kind, nested_seq.fps_numerator, nested_seq.fps_denominator,
           mr.media_id, m.name, m.file_path, m.offline_note,
           -- 018: subframes appended at end to avoid shifting older column
           -- indices. NULL on video clips, 0 or more on audio clips (FR-013).
           c.source_in_subframe, c.source_out_subframe
    FROM clips c
    JOIN tracks t ON c.track_id = t.id
    JOIN sequences owner_seq ON c.owner_sequence_id = owner_seq.id
    JOIN sequences nested_seq ON c.sequence_id = nested_seq.id
    LEFT JOIN media_refs mr ON mr.owner_sequence_id = c.sequence_id
                            AND nested_seq.kind = 'master'
    LEFT JOIN media m ON m.id = mr.media_id
    WHERE c.id = ?
]]

-- Assert the nested + owner sequences both carry positive frame rates.
-- Throws on violation (caller has already done query:finalize()).
local function assert_clip_load_frame_rates(query, clip_id)
    local nested_fps_num, nested_fps_den = query:value(24), query:value(25)
    if not nested_fps_num or nested_fps_num <= 0
        or not nested_fps_den or nested_fps_den <= 0 then
        error(string.format(
            "Clip.load_failed: clip %s nested-sequence has invalid frame rate (%s/%s)",
            clip_id, tostring(nested_fps_num), tostring(nested_fps_den)))
    end
    local owner_fps_num, owner_fps_den = query:value(21), query:value(22)
    if not owner_fps_num or owner_fps_num <= 0
        or not owner_fps_den or owner_fps_den <= 0 then
        error(string.format(
            "Clip.load_failed: clip %s owner-sequence has invalid frame rate (%s/%s)",
            clip_id, tostring(owner_fps_num), tostring(owner_fps_den)))
    end
    return nested_fps_num, nested_fps_den
end

-- Materialize the clip table from one cursor row (mirrors
-- database.build_clip_from_query_row's V13 chain-leaf shape so callers
-- can read .resolved_media + .media_path uniformly).
local function build_clip_from_load_row(query, clip_id, nested_fps_num, nested_fps_den)
    local clip = {
        id                    = query:value(0),
        project_id            = query:value(1),
        name                  = query:value(2),
        track_id              = query:value(3),
        owner_sequence_id     = query:value(4),
        sequence_id    = query:value(5),

        sequence_start = assert(query:value(6),  "Clip.load: sequence_start_frame is NULL"),
        duration       = assert(query:value(7),  "Clip.load: duration_frames is NULL"),
        source_in      = assert(query:value(8),  "Clip.load: source_in_frame is NULL"),
        source_out     = assert(query:value(9),  "Clip.load: source_out_frame is NULL"),

        master_layer_track_id = query:value(10),
        master_audio_track_id = query:value(11),
        fps_mismatch_policy   = query:value(12),

        -- Source-side timebase (the nested sequence's frame rate).
        frame_rate = {
            fps_numerator   = nested_fps_num,
            fps_denominator = nested_fps_den,
        },

        enabled = query:value(13) == 1 or query:value(13) == true,
        volume  = assert(query:value(14), string.format(
            "Clip.load: volume is NULL for clip %s", tostring(clip_id))),
        mark_in        = query:value(15),
        mark_out       = query:value(16),
        playhead_frame = assert(query:value(17), string.format(
            "Clip.load: playhead_frame is NULL for clip %s", tostring(clip_id))),
        created_at  = query:value(18),
        modified_at = query:value(19),

        track_type           = query:value(20),
        source_sequence_kind = query:value(23),
    }

    -- V13-resolved chain leaf: media chain leaks through the LEFT JOIN
    -- only when nested.kind = 'master'. media_path is denormed flat for
    -- the timeline offline-tracker (keys clips by media_path).
    local media_id_val = query:value(26)
    if media_id_val then
        clip.resolved_media = {
            id            = media_id_val,
            name          = query:value(27),
            path          = query:value(28),
            offline_note  = query:value(29),
        }
        clip.media_path = query:value(28)
    end

    -- 018: source-side subframe (master-clock ticks). NULL on video clips,
    -- 0 or more on audio clips (FR-013). Consumers that re-create the clip
    -- via Clip.create must thread these through or the schema trigger fires.
    clip.source_in_subframe  = query:value(30)
    clip.source_out_subframe = query:value(31)

    return clip
end

local function load_internal(clip_id, raise_errors)
    if not clip_id or clip_id == "" then
        if raise_errors then error("Clip.load_failed: Invalid clip_id") end
        return nil
    end

    local database = require("core.database")
    local db = database.get_connection()
    if not db then
        if raise_errors then error("Clip.load_failed: No database connection available") end
        return nil
    end

    local query = db:prepare(CLIP_LOAD_SQL)
    if not query then
        if raise_errors then error("Clip.load_failed: Failed to prepare query") end
        return nil
    end
    query:bind_value(1, clip_id)

    if not query:exec() then
        local err = query:last_error()
        query:finalize()
        if raise_errors then
            error(string.format("Clip.load_failed: Query execution failed: %s", err))
        end
        return nil
    end

    if not query:next() then
        query:finalize()
        if raise_errors then
            error(string.format("Clip.load_failed: Clip not found: %s", clip_id))
        end
        return nil
    end

    local nested_fps_num, nested_fps_den = assert_clip_load_frame_rates(query, clip_id)
    local clip = build_clip_from_load_row(query, clip_id, nested_fps_num, nested_fps_den)
    query:finalize()

    clip.name = derive_display_name(clip.id, clip.name)
    setmetatable(clip, {__index = M})
    return clip
end

--- Create a clip row. Args: a single table with the V13 fields:
--- id (optional), project_id, owner_sequence_id, track_id,
--- sequence_id, name, sequence_start_frame, duration_frames,
--- source_in_frame, source_out_frame, master_layer_track_id (nullable),
--- fps_mismatch_policy ('resample'|'passthrough'), enabled, volume,
--- mark_in_frame (nullable), mark_out_frame (nullable), playhead_frame.
--- Returns the clip id (string). Owner must be kind='sequence' and source window
--- must be non-empty with lower bound >= 0 — enforced via the model helpers + DB triggers. To create a master sequence from a media file,
--- call Sequence.ensure_master (writes media_refs, not clips).
function M.create(fields)
    assert(type(fields) == "table",
        "Clip.create: fields table required")
    assert(fields.sequence_id ~= nil,
        "Clip.create: 'sequence_id' is required")
    return M._create_v13_row(fields)
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

    -- Fallback: derive from nested sequence if present
    if not self.project_id and self.sequence_id then
        local seq_query = db:prepare("SELECT project_id FROM sequences WHERE id = ?")
        if seq_query then
            seq_query:bind_value(1, self.sequence_id)
            if seq_query:exec() and seq_query:next() then
                self.project_id = seq_query:value(0)
            end
            seq_query:finalize()
        end
    end

    assert(self.project_id, string.format(
        "ensure_project_context: could not derive project_id for clip %s (track_id=%s, sequence_id=%s)",
        tostring(self.id), tostring(self.track_id), tostring(self.sequence_id)))
end

-- Save clip to database (INSERT or UPDATE)
-- opts.skip_occlusion: when true, skip occlusion checks (currently disabled, will be used when re-enabled)
-- ============================================================================
-- Clip.save phase helpers
-- ============================================================================

-- Type-validate every required field on the clip before any DB work. Per
-- rule 2.13: NOT NULL columns + invariant fields fail loud at write time.
local function assert_clip_save_invariants(self)
    assert(self.id and self.id ~= "", "Clip.save: clip id is required")
    assert(type(self.sequence_start) == "number",
        "Clip.save: sequence_start must be integer (got " .. type(self.sequence_start) .. ")")
    assert(type(self.duration) == "number",
        "Clip.save: duration must be integer (got " .. type(self.duration) .. ")")
    assert(type(self.source_in) == "number",
        "Clip.save: source_in must be integer (got " .. type(self.source_in) .. ")")
    assert(type(self.source_out) == "number",
        "Clip.save: source_out must be integer (got " .. type(self.source_out) .. ")")
    assert(type(self.volume) == "number" and self.volume >= 0, string.format(
        "Clip.save: volume must be non-negative number (got %s=%s) for clip %s",
        type(self.volume), tostring(self.volume), tostring(self.id)))
    if self.mark_in ~= nil then
        assert(type(self.mark_in) == "number", string.format(
            "Clip.save: mark_in must be integer or nil (got %s) for clip %s",
            type(self.mark_in), tostring(self.id)))
    end
    if self.mark_out ~= nil then
        assert(type(self.mark_out) == "number", string.format(
            "Clip.save: mark_out must be integer or nil (got %s) for clip %s",
            type(self.mark_out), tostring(self.id)))
    end
    assert(type(self.playhead_frame) == "number", string.format(
        "Clip.save: playhead_frame must be number (got %s) for clip %s",
        type(self.playhead_frame), tostring(self.id)))
    assert(type(self.name) == "string" and self.name ~= "",
        string.format("Clip.save: name is required for clip %s", tostring(self.id)))
    assert(type(self.fps_mismatch_policy) == "string" and self.fps_mismatch_policy ~= "",
        string.format("Clip.save: fps_mismatch_policy is required for clip %s",
            tostring(self.id)))
    -- Source ordering convention: source_out >= source_in is forward;
    -- source_out < source_in is a reverse clip. Both are valid states.
    -- Full cross-operation source_out consistency is validated by
    -- project_validator, not here.
end

-- Does a row with this id already exist? Used to pick UPDATE vs INSERT.
local function clip_row_exists(db, id)
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    local exists = false
    if stmt:exec() and stmt:next() then exists = stmt:value(0) > 0 end
    stmt:finalize()
    return exists
end

local function prepare_clip_save_stmt(db, exists)
    if exists then
        return db:prepare([[
            UPDATE clips
            SET project_id = ?, name = ?, track_id = ?,
                owner_sequence_id = ?, sequence_id = ?,
                sequence_start_frame = ?, duration_frames = ?,
                source_in_frame = ?, source_out_frame = ?,
                master_layer_track_id = ?, master_audio_track_id = ?,
                fps_mismatch_policy = ?,
                enabled = ?, volume = ?,
                mark_in_frame = ?, mark_out_frame = ?, playhead_frame = ?,
                modified_at = strftime('%s','now')
            WHERE id = ?
        ]])
    end
    return db:prepare([[
        INSERT INTO clips (
            id, project_id, name, track_id,
            owner_sequence_id, sequence_id,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, master_audio_track_id,
            fps_mismatch_policy,
            enabled, volume,
            mark_in_frame, mark_out_frame, playhead_frame,
            created_at, modified_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                strftime('%s','now'), strftime('%s','now'))
    ]])
end

local function bind_clip_value_or_null(stmt, idx, val)
    if val ~= nil then
        stmt:bind_value(idx, val)
    elseif stmt.bind_null then
        stmt:bind_null(idx)
    else
        stmt:bind_value(idx, nil)
    end
end

-- Bind the 17 mutable column values (everything except `id`/created_at/
-- modified_at). UPDATE and INSERT share this set; UPDATE binds at
-- offset 1 (slots 1-17), INSERT at offset 2 (slots 2-18).
local function bind_clip_writable_columns(query, base, self, nested_id)
    query:bind_value(base + 0, self.project_id)
    query:bind_value(base + 1, self.name)
    query:bind_value(base + 2, self.track_id)
    query:bind_value(base + 3, self.owner_sequence_id)
    query:bind_value(base + 4, nested_id)
    query:bind_value(base + 5, self.sequence_start)
    query:bind_value(base + 6, self.duration)
    query:bind_value(base + 7, self.source_in)
    query:bind_value(base + 8, self.source_out)
    bind_clip_value_or_null(query, base + 9, self.master_layer_track_id)
    bind_clip_value_or_null(query, base + 10, self.master_audio_track_id)
    query:bind_value(base + 11, self.fps_mismatch_policy)
    query:bind_value(base + 12, self.enabled and 1 or 0)
    query:bind_value(base + 13, self.volume)
    bind_clip_value_or_null(query, base + 14, self.mark_in)
    bind_clip_value_or_null(query, base + 15, self.mark_out)
    query:bind_value(base + 16, self.playhead_frame)
end

local function save_internal(self, _opts)
    local database = require("core.database")
    local db = database.get_connection()
    assert(db, "Clip.save: No database connection available")

    assert_clip_save_invariants(self)
    require("core.track_lock_guard").assert_writable(db, { self.track_id })

    ensure_project_context(self, db)
    local nested_id = self.sequence_id
    assert(nested_id and nested_id ~= "",
        "Clip.save: sequence_id required for clip " .. tostring(self.id))
    self.name = derive_display_name(self.id, self.name)

    local krono_enabled = krono_ok and krono and krono.is_enabled and krono.is_enabled()
    local krono_start   = krono_enabled and krono.now and krono.now() or nil

    local exists       = clip_row_exists(db, self.id)
    local krono_exists = krono_enabled and krono.now and krono.now() or nil

    -- OCCLUSION LOGIC (temporarily disabled — tracked in clip_mutator).
    local occlusion_actions = nil

    local query = prepare_clip_save_stmt(db, exists)
    assert(query, "Clip.save: Failed to prepare query for clip " .. tostring(self.id))

    if exists then
        bind_clip_writable_columns(query, 1, self, nested_id)
        query:bind_value(18, self.id)
    else
        query:bind_value(1, self.id)
        bind_clip_writable_columns(query, 2, self, nested_id)
    end

    local krono_exec = krono_enabled and krono.now and krono.now() or nil
    if not query:exec() then
        local err = query:last_error()
        query:finalize()
        error(string.format("Clip.save: Failed to save clip %s: %s",
            tostring(self.id), err))
    end
    query:finalize()

    if krono_enabled and krono_start and krono_exists and krono_exec then
        log.detail("Clip.save[%s]: %.2fms (exists=%.2fms run=%.2fms)",
            tostring(self.id:sub(1, 8)),
            krono_exec - krono_start,
            krono_exists - krono_start,
            krono_exec - krono_exists)
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
    require("core.track_lock_guard").assert_writable(db, { self.track_id })

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
-- A clip contains time T if: sequence_start <= T < sequence_start + duration
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
          AND sequence_start_frame <= ?
          AND (sequence_start_frame + duration_frames) > ?
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

--- Get non-master sequences where a master sequence is referenced as a clip's
--- nested target. (V13 — was get_master_clip_usage; "master clip" was the V8
--- name for what V13 calls a master sequence.)
-- @param master_sequence_id string: The master sequence ID to check
-- @return table: Array of {sequence_id, sequence_name, clip_count}
function M.get_master_sequence_usage(master_sequence_id)
    assert(master_sequence_id and master_sequence_id ~= "",
        "Clip.get_master_sequence_usage: missing master_sequence_id")

    local database = require("core.database")
    local db = database.get_connection()
    if not db then
        log.warn("Clip.get_master_sequence_usage: No database connection available")
        return {}
    end

    local query = db:prepare([[
        SELECT s.id, s.name, COUNT(c.id) as clip_count
        FROM clips c
        JOIN sequences s ON c.owner_sequence_id = s.id
        WHERE c.sequence_id = ?
          AND s.kind = 'sequence'
        GROUP BY s.id, s.name
        ORDER BY s.name
    ]])

    if not query then
        log.warn("Clip.get_master_sequence_usage: Failed to prepare query")
        return {}
    end

    query:bind_value(1, master_sequence_id)

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
          AND sequence_start_frame >= ?
          AND enabled = 1
        ORDER BY sequence_start_frame ASC
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
-- "Ending at" means (sequence_start + duration) <= before_frame.
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
          AND (sequence_start_frame + duration_frames) <= ?
          AND enabled = 1
        ORDER BY sequence_start_frame DESC
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

--- Find all clips referencing a given media (V13: walks
--- clip.sequence_id → master.media_refs → media). Returns the
--- list of timeline clips whose underlying chain terminates at a
--- media_ref pointing at this media. (V8 had clip.media_id direct;
--- under V13 the relationship is transitive.)
-- @param media_id string
-- @return table Array of Clip objects
function M.find_clips_for_media(media_id)
    assert(media_id and media_id ~= "", "Clip.find_clips_for_media: media_id required")

    local database = require("core.database")
    local db = assert(database.get_connection(), "Clip.find_clips_for_media: no database connection")

    -- Scope to the active project. The schema permits multiple projects
    -- per .jvp; without this filter a relink operation on media shared
    -- between two projects would touch clips in the inactive project.
    local active_project_id = database.get_current_project_id()
    assert(active_project_id and active_project_id ~= "",
        "Clip.find_clips_for_media: get_current_project_id returned nil/empty")

    local stmt = assert(db:prepare([[
        SELECT DISTINCT c.id FROM clips c
        JOIN media_refs mr ON mr.owner_sequence_id = c.sequence_id
        WHERE mr.media_id = ? AND c.project_id = ?
    ]]), "Clip.find_clips_for_media: failed to prepare query")

    stmt:bind_value(1, media_id)
    stmt:bind_value(2, active_project_id)
    assert(stmt:exec(), "Clip.find_clips_for_media: query exec failed")

    local clips = {}
    while stmt:next() do
        local clip = M.load(stmt:value(0))
        if clip then clips[#clips + 1] = clip end
    end
    stmt:finalize()
    return clips
end

--- Map a frame in the owner-timeline's frame space to the clip's source
--- frame space. Same arithmetic used by `MatchFrame` (FR-024 F) and
--- `OpenClipInSourceMonitor` (FR-024 v2 Shift+F): given a record-side
--- frame inside `[sequence_start, sequence_start + duration)`, return
--- the source frame it corresponds to. Assumes 1:1 source↔owner rate —
--- non-1:1 (fps-mismatched clips) is a separate latent concern tracked
--- under FR-014. No range clamp — callers that need clamping into a
--- master sequence's coverage window apply it themselves
--- (`match_frame.clamp_to_master_range`).
---
--- Module function (not method) so callers that have a plain clip table
--- — `timeline_state.get_clips_at_time` returns rows without the Clip
--- metatable — can use it without round-tripping through `Clip.load`.
--- @param clip table            clip row with sequence_start + source_in
--- @param owner_frame number    frame in owner-sequence space
--- @return number               corresponding source-media frame
function M.owner_frame_to_source(clip, owner_frame)
    assert(type(clip) == "table", "Clip.owner_frame_to_source: clip required")
    assert(type(clip.sequence_start) == "number", string.format(
        "Clip.owner_frame_to_source: clip %s missing sequence_start",
        tostring(clip.id)))
    assert(type(clip.source_in) == "number", string.format(
        "Clip.owner_frame_to_source: clip %s missing source_in",
        tostring(clip.id)))
    assert(type(owner_frame) == "number", string.format(
        "Clip.owner_frame_to_source: owner_frame must be a number; got %s",
        type(owner_frame)))
    return clip.source_in + (owner_frame - clip.sequence_start)
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

--- Read lightweight source state for multiple clips. V13: clip.media_id
--  has been removed; the leaf media is reached through the clip's
--  sequence_id master and its (single) media_ref. Returns the
--  same shape as the legacy V8 helper so relink_clips can keep using
--  it as an opaque 'before' snapshot.
-- @param clip_ids table Array or set of clip IDs
-- @return table {clip_id → {media_id, source_in, source_out}}
function M.batch_read_source(clip_ids)
    local database = require("core.database")
    local db = assert(database.get_connection(), "Clip.batch_read_source: no database connection")

    local stmt = assert(db:prepare([[
        SELECT mr.media_id, c.source_in_frame, c.source_out_frame
          FROM clips c
          JOIN media_refs mr ON mr.owner_sequence_id = c.sequence_id
         WHERE c.id = ?
    ]]), "Clip.batch_read_source: failed to prepare query")

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

--- Batch update source range (and, when changed, retarget the clip's
--  master sequence so it points at a different media). V13: clips
--  themselves no longer hold media_id; rebinding to a different media
--  means switching the clip's sequence_id to that media's master
--  (created on demand via Sequence.ensure_master).
-- @param updates table {clip_id → {media_id, source_in, source_out}}
function M.batch_update_source(updates)
    local database = require("core.database")
    local db = assert(database.get_connection(), "Clip.batch_update_source: no database connection")

    -- Source-range updates always apply.
    local range_stmt = assert(db:prepare([[
        UPDATE clips SET source_in_frame = ?, source_out_frame = ?,
            modified_at = strftime('%s','now') WHERE id = ?
    ]]), "Clip.batch_update_source: failed to prepare range update")

    -- Master swap: only fire when the clip's current master no longer
    -- matches the desired media.
    local current_stmt = assert(db:prepare([[
        SELECT c.sequence_id, mr.media_id
          FROM clips c
          JOIN media_refs mr ON mr.owner_sequence_id = c.sequence_id
         WHERE c.id = ?
    ]]), "Clip.batch_update_source: failed to prepare current-master query")

    local rebind_stmt = assert(db:prepare([[
        UPDATE clips SET sequence_id = ?,
            modified_at = strftime('%s','now') WHERE id = ?
    ]]), "Clip.batch_update_source: failed to prepare rebind update")

    local Sequence = require("models.sequence")

    for clip_id, vals in pairs(updates) do
        assert(vals.media_id, "Clip.batch_update_source: media_id required for " .. clip_id)
        assert(vals.source_in, "Clip.batch_update_source: source_in required for " .. clip_id)
        assert(vals.source_out, "Clip.batch_update_source: source_out required for " .. clip_id)

        -- Read the clip's existing (master, leaf media) pair.
        current_stmt:bind_value(1, clip_id)
        assert(current_stmt:exec(), "Clip.batch_update_source: current-master exec failed for " .. clip_id)
        assert(current_stmt:next(), "Clip.batch_update_source: clip not found: " .. clip_id)
        local current_mid = current_stmt:value(1)
        current_stmt:reset()

        if current_mid ~= vals.media_id then
            -- Rebind the clip to the new media's master sequence. The
            -- clip's project_id is whatever the master's project_id is —
            -- read it back from the existing master's row.
            local proj_stmt = assert(db:prepare(
                "SELECT project_id FROM clips WHERE id = ?"),
                "Clip.batch_update_source: failed to prepare project_id query")
            proj_stmt:bind_value(1, clip_id)
            assert(proj_stmt:exec() and proj_stmt:next(),
                "Clip.batch_update_source: project_id lookup failed for " .. clip_id)
            local project_id = proj_stmt:value(0)
            proj_stmt:finalize()
            local new_master_id = Sequence.ensure_master(vals.media_id, project_id)
            rebind_stmt:bind_value(1, new_master_id)
            rebind_stmt:bind_value(2, clip_id)
            assert(rebind_stmt:exec(), "Clip.batch_update_source: rebind exec failed for " .. clip_id)
            rebind_stmt:reset()
        end

        range_stmt:bind_value(1, vals.source_in)
        range_stmt:bind_value(2, vals.source_out)
        range_stmt:bind_value(3, clip_id)
        assert(range_stmt:exec(), "Clip.batch_update_source: range exec failed for " .. clip_id)
        range_stmt:reset()
    end
    range_stmt:finalize()
    current_stmt:finalize()
    rebind_stmt:finalize()
end

-- ===========================================================================
-- Feature 013: V9 clips row shape
-- ===========================================================================
-- Rows in the V9 `clips` table hold references to other sequences via
-- `sequence_id`. Clips must be owned by a kind='sequence' sequence
-- (enforced by the schema trigger). The clip source window must be non-empty
-- with a lower bound >= 0 (enforced at model layer).

local V13_REQUIRED = {
    "project_id", "owner_sequence_id", "sequence_id",
    "track_id",
    "name",
    "sequence_start_frame", "duration_frames",
    "source_in_frame", "source_out_frame",
    "fps_mismatch_policy",
    "enabled", "volume", "playhead_frame",
}

-- Sanity-check the source window. Direction-agnostic: forward clips have
-- Source window: non-empty (source_in != source_out), non-negative bounds.
-- Upper-bound (source_out <= master.duration) is NOT checked here: relink
-- can shorten the master retroactively; runtime handles past-extent via
-- partial_coverage / offline overlay / silence. Per-command preconditions
-- (trim, slip, roll) enforce the upper bound at the right scope.
local function assert_window_in_bounds(clip_id, source_in, source_out)
    assert(type(source_in) == "number" and type(source_out) == "number",
        "Clip: source_in/out must be numbers")
    assert(source_in ~= source_out, string.format(
        "Clip window invariant: clip %s has source_in=%d == source_out=%d "
        .. "(empty window)", tostring(clip_id), source_in, source_out))
    local lo = math.min(source_in, source_out)
    assert(lo >= 0, string.format(
        "Clip window invariant: clip %s has negative source bound %d "
        .. "(source_in=%d, source_out=%d)",
        tostring(clip_id), lo, source_in, source_out))
end

local function to_int_bool(v)
    if v == true or v == 1 then return 1 end
    if v == false or v == 0 then return 0 end
    error("Clip: boolean must be true/false or 1/0; got " .. tostring(v))
end

-- Model-layer pre-flight: fetch the owner_sequence_id's kind and raise a
-- clear error (rule 1.14) if it isn't 'sequence' (clips must be owned by a kind='sequence' sequence).
-- This fires BEFORE the schema trigger's generic RAISE(ABORT, ...) which cannot embed the offending value.
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
    assert(kind == "sequence", string.format(
        "Clip.create: clips must be owned by a kind='sequence' sequence: clip=%s owner_sequence_id=%s kind='%s' (expected 'sequence')",
        tostring(clip_id), tostring(owner_seq_id), tostring(kind)))
end

-- 018 (V11 / FR-013): explicit accessor for "frame-aligned" clip
-- creation. Caller invokes by name to acknowledge FR-013's "marks UX is
-- frame-aligned today; subframe = 0 for new audio clips" contract. This is
-- NOT a silent fallback (rule 2.13): the call site's choice of this
-- function over the strict path IS the value-declaration.
--
-- Returns (sub_in, sub_out) tuple to splat into the fields table at the
-- audio-creating call site:
--   local sub_in, sub_out = Clip.subframe_defaults_for(db, track_id)
--   Clip.create({ ..., source_in_subframe = sub_in, source_out_subframe = sub_out })
-- Pure kind-dispatch variant for callers that already hold a track row.
-- Commands MUST use this (SQL isolation; rule 1.10).
function M.subframe_defaults_for_track_type(track_type)
    assert(track_type == "VIDEO" or track_type == "AUDIO", string.format(
        "Clip.subframe_defaults_for_track_type: track_type must be "
        .. "'VIDEO' or 'AUDIO', got %s", tostring(track_type)))
    if track_type == "AUDIO" then return 0, 0 end
    return nil, nil
end

-- DB-bound variant for callers that hold only a track_id (importer paths,
-- model-layer helpers). Looks up the track_type and delegates.
function M.subframe_defaults_for(db, track_id)
    assert(db, "Clip.subframe_defaults_for: db connection required")
    assert(track_id and track_id ~= "",
        "Clip.subframe_defaults_for: track_id required")
    local stmt = db:prepare("SELECT track_type FROM tracks WHERE id = ?")
    assert(stmt, "Clip.subframe_defaults_for: prepare failed")
    stmt:bind_value(1, track_id)
    assert(stmt:exec(), "Clip.subframe_defaults_for: exec failed")
    assert(stmt:next(), string.format(
        "Clip.subframe_defaults_for: track not found for id=%s", tostring(track_id)))
    local tt = stmt:value(0)
    stmt:finalize()
    return M.subframe_defaults_for_track_type(tt)
end

-- (Internal) Same as above but called from _create_v13_row's audit path.
-- 018 (V11 / FR-013): subframe columns presence is driven by the
-- clip's track_type. AUDIO requires both source_*_subframe non-NULL; VIDEO
-- requires both NULL. Caller passes both explicitly — no silent default
-- (rule 2.13).
local function fetch_track_type(db, clip_id, track_id)
    local tstmt = db:prepare("SELECT track_type FROM tracks WHERE id = ?")
    assert(tstmt, "Clip._create_v13_row: prepare track_type query failed")
    tstmt:bind_value(1, track_id)
    assert(tstmt:exec(), "Clip._create_v13_row: track_type query failed")
    assert(tstmt:next(), string.format(
        "Clip._create_v13_row: track not found for id=%s (clip=%s)",
        tostring(track_id), tostring(clip_id)))
    local tt = tstmt:value(0)
    tstmt:finalize()
    return tt
end

local function subframe_for_kind(db, clip_id, fields)
    local tt = fetch_track_type(db, clip_id, fields.track_id)
    if tt == "AUDIO" then
        assert(fields.source_in_subframe ~= nil, string.format(
            "Clip._create_v13_row: AUDIO clip %s missing source_in_subframe "
            .. "(audio clips require non-NULL subframe per FR-013 — no silent default per rule 2.13)",
            tostring(clip_id)))
        assert(fields.source_out_subframe ~= nil, string.format(
            "Clip._create_v13_row: AUDIO clip %s missing source_out_subframe "
            .. "(audio clips require non-NULL subframe per FR-013 — no silent default per rule 2.13)",
            tostring(clip_id)))
        return fields.source_in_subframe, fields.source_out_subframe
    end
    assert(fields.source_in_subframe == nil and fields.source_out_subframe == nil,
        string.format("Clip._create_v13_row: video clip %s must have NULL subframes (FR-013)",
            tostring(clip_id)))
    return nil, nil
end

function M._create_v13_row(fields)
    assert(type(fields) == "table", "Clip.create (v13): fields table required")
    for _, col in ipairs(V13_REQUIRED) do
        assert(fields[col] ~= nil, string.format(
            "Clip.create (v13): '%s' is required (rule 2.13 — no column defaults)", col))
    end
    local db = require("core.database").get_connection()
    local id = fields.id or uuid.generate()

    require("core.track_lock_guard").assert_writable(db, { fields.track_id })
    assert_owner_is_nested(db, id, fields.owner_sequence_id)
    assert_window_in_bounds(id, fields.source_in_frame, fields.source_out_frame)

    local sub_in, sub_out = subframe_for_kind(db, id, fields)

    local now = fields.created_at or os.time()
    local stmt = db:prepare([[
        INSERT INTO clips (
            id, project_id, owner_sequence_id, track_id, sequence_id,
            name, sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, mark_in_frame, mark_out_frame, playhead_frame,
            created_at, modified_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    assert(stmt, "Clip._create_v13_row: prepare failed")
    stmt:bind_value(1, id)
    stmt:bind_value(2, fields.project_id)
    stmt:bind_value(3, fields.owner_sequence_id)
    stmt:bind_value(4, fields.track_id)
    stmt:bind_value(5, fields.sequence_id)
    stmt:bind_value(6, fields.name)
    stmt:bind_value(7, fields.sequence_start_frame)
    stmt:bind_value(8, fields.duration_frames)
    stmt:bind_value(9, fields.source_in_frame)
    stmt:bind_value(10, fields.source_out_frame)
    stmt:bind_value(11, sub_in)                          -- nullable on video, set on audio (FR-013)
    stmt:bind_value(12, sub_out)                         -- nullable on video, set on audio (FR-013)
    stmt:bind_value(13, fields.master_layer_track_id)    -- nullable
    stmt:bind_value(14, fields.master_audio_track_id)    -- nullable (Expand/Collapse)
    stmt:bind_value(15, fields.fps_mismatch_policy)
    stmt:bind_value(16, to_int_bool(fields.enabled))
    stmt:bind_value(17, fields.volume)
    stmt:bind_value(18, fields.mark_in_frame)            -- nullable
    stmt:bind_value(19, fields.mark_out_frame)           -- nullable
    stmt:bind_value(20, fields.playhead_frame)
    stmt:bind_value(21, now)
    stmt:bind_value(22, fields.modified_at or now)

    local ok = stmt:exec()
    local err
    if not ok then err = stmt:last_error() end
    stmt:finalize()
    assert(ok, string.format(
        "Clip._create_v13_row: INSERT failed for id=%s: %s (likely trigger: clips must be owned by a kind='sequence' sequence, or FK)",
        id, tostring(err)))
    return id
end

local CLIP_UPDATABLE_V13 = {
    name = true, track_id = true,
    sequence_start_frame = true, duration_frames = true,
    source_in_frame = true, source_out_frame = true,
    master_layer_track_id = true, fps_mismatch_policy = true,
    enabled = true, volume = true,
    mark_in_frame = true, mark_out_frame = true, playhead_frame = true,
}

--- Update a V9 clips row. Enforces the source-window invariant after the write — if
--- source_in_frame or source_out_frame changes, the window must be non-empty with lower bound >= 0.
function M.update(id, fields)
    assert(type(fields) == "table", "Clip.update: fields table required")
    local db = require("core.database").get_connection()

    local fetch = db:prepare(
        "SELECT source_in_frame, source_out_frame, track_id FROM clips WHERE id = ?")
    assert(fetch, "Clip.update: fetch prepare failed")
    fetch:bind_value(1, id)
    assert(fetch:exec(), "Clip.update: fetch exec failed")
    assert(fetch:next(), string.format("Clip.update: clip %s not found", tostring(id)))
    local cur_in = fetch:value(0)
    local cur_out = fetch:value(1)
    local cur_track = fetch:value(2)
    fetch:finalize()

    -- Lock gate: refuse if the clip's current track is locked, and if the
    -- update targets a new (locked) track. Both endpoints must be writable
    -- for a cross-track move.
    local guard = require("core.track_lock_guard")
    local guard_tracks = { cur_track }
    if fields.track_id and fields.track_id ~= cur_track then
        guard_tracks[#guard_tracks + 1] = fields.track_id
    end
    guard.assert_writable(db, guard_tracks)

    local new_in  = fields.source_in_frame  ~= nil and fields.source_in_frame  or cur_in
    local new_out = fields.source_out_frame ~= nil and fields.source_out_frame or cur_out
    if fields.source_in_frame ~= nil or fields.source_out_frame ~= nil then
        assert_window_in_bounds(id, new_in, new_out)
    end

    -- Catch duration_frames <= 0 at the Lua boundary with full context
    -- (the SQL CHECK fires too but its message is opaque). Reverse clips
    -- carry positive owner-timebase duration too, so this is unconditional.
    if fields.duration_frames ~= nil then
        assert(type(fields.duration_frames) == "number"
               and fields.duration_frames > 0, string.format(
            "Clip.update: duration_frames must be > 0 (clip %s); got %s — "
            .. "typically a trim that would collapse the clip",
            tostring(id), tostring(fields.duration_frames)))
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
    -- Capture the sqlite error before finalize (finalize can reset state).
    -- Codebase standard: stmt:last_error() inside the prepare/exec scope.
    local errmsg = ok and nil or stmt:last_error()
    stmt:finalize()
    if not ok then
        local field_vals = {}
        for k, v in pairs(fields) do
            field_vals[#field_vals + 1] = k .. "=" .. tostring(v)
        end
        assert(false, string.format(
            "Clip.update: exec failed for id=%s sqlite_err=%s values={%s}",
            id, tostring(errmsg), table.concat(field_vals, ", ")))
    end
    return true
end

-- ===========================================================================
-- Feature 013 (T041): source<->timeline frame conversion under a clip's
-- policy. A single clip stores sequence_start/duration in owner-timebase
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
--- [window_start, window_end), ordered by sequence_start_frame. Each row is
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
        SELECT id, project_id, owner_sequence_id, track_id, sequence_id,
               name, sequence_start_frame, duration_frames,
               source_in_frame, source_out_frame,
               master_layer_track_id, fps_mismatch_policy,
               enabled, volume, mark_in_frame, mark_out_frame, playhead_frame,
               source_in_subframe, source_out_subframe
        FROM clips
        WHERE track_id = ?
          AND sequence_start_frame < ?
          AND (sequence_start_frame + duration_frames) > ?
        ORDER BY sequence_start_frame ASC
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
            sequence_id    = stmt:value(4),
            name                  = stmt:value(5),
            sequence_start_frame  = stmt:value(6),
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
            source_in_subframe    = stmt:value(17),
            source_out_subframe   = stmt:value(18),
        }
    end
    stmt:finalize()
    return rows
end

--- Owner-timebase duration after an edge trim at 1:1 source↔timeline
--- mapping. Edge convention is dual — OverwriteTrimEdge / RippleTrimEdge
--- use "left"/"right"; selection edge_infos and SetMarkAndTrimIfClip use
--- "in"/"out". Direction is derived from `clip.source_in` vs
--- `clip.source_out`:
---   forward (source_out > source_in) → sign = +1
---   reverse (source_out < source_in) → sign = -1  (source plays
---       backwards as timeline advances; left/in delta inverts because
---       pushing source_in higher GROWS the playback range)
--- left/in:  new_duration = current_duration - sign * delta
--- right/out: new_duration = current_duration + sign * delta
--- Source-frame arithmetic itself (`source_in + delta`,
--- `source_out + delta`) is direction-agnostic and lives at the caller.
--- This helper is the canonical home for trim duration math so the
--- precheck (SetMarkAndTrimIfClip), the overwrite-trim arithmetic
--- (compute_trim), and the ripple arithmetic (batch_ripple_edit) cannot
--- drift on the direction-sign question. fps_mismatch (non-1:1) is a
--- separate latent concern — see TODO in MEMORY.
function M.compute_trim_duration(clip, edge, delta_frames)
    assert(type(clip) == "table", "Clip.compute_trim_duration: clip table required")
    assert(type(clip.duration) == "number",
        "Clip.compute_trim_duration: clip.duration must be a number")
    assert(type(delta_frames) == "number",
        "Clip.compute_trim_duration: delta_frames must be a number")

    -- Gap clips (`is_gap = true`, source_in/source_out nil) have no
    -- source direction. They trim as pure timeline-frame arithmetic, so
    -- the forward sign applies. Real clips must carry both source bounds
    -- and a non-zero direction.
    local sign
    if clip.source_in == nil and clip.source_out == nil then
        sign = 1
    else
        assert(type(clip.source_in) == "number" and type(clip.source_out) == "number",
            "Clip.compute_trim_duration: clip.source_in / source_out must both be numbers (or both nil for gaps)")
        assert(clip.source_in ~= clip.source_out, string.format(
            "Clip.compute_trim_duration: zero-direction clip (source_in == source_out == %d) "
            .. "violates the model invariant; direction is undefined", clip.source_in))
        sign = (clip.source_out > clip.source_in) and 1 or -1
    end

    if edge == "left" or edge == "in" then
        return clip.duration - sign * delta_frames
    end
    if edge == "right" or edge == "out" then
        return clip.duration + sign * delta_frames
    end
    assert(false, string.format(
        "Clip.compute_trim_duration: unknown edge %q (expected 'left'/'in' or 'right'/'out')",
        tostring(edge)))
end

--- Low-level UPDATE: set timeline + duration + source bounds on one clip.
--- Source-window invariant (non-empty, lower bound >= 0) is re-checked by Clip.update which we delegate to.
function M.update_bounds(id, sequence_start_frame, duration_frames,
                        source_in_frame, source_out_frame)
    return M.update(id, {
        sequence_start_frame = sequence_start_frame,
        duration_frames      = duration_frames,
        source_in_frame      = source_in_frame,
        source_out_frame     = source_out_frame,
    })
end

--- Asserts that new_source_out does not exceed the master's media_refs
--- coverage. No-op when master has no media_refs (coverage_max is nil).
--- Called by editing commands (Slip, Roll) to enforce the command-layer
--- upper bound; model layer only checks lower-bound + non-empty.
function M.assert_within_master_coverage(sequence_id, new_source_out, label)
    assert(sequence_id and sequence_id ~= "",
        "Clip.assert_within_master_coverage: sequence_id required")
    assert(type(new_source_out) == "number",
        string.format("Clip.assert_within_master_coverage: new_source_out must be a number, got %s (%s)",
            type(new_source_out), tostring(label)))
    local db = require("core.database").get_connection()
    local stmt = db:prepare(
        "SELECT MAX(source_out_frame) FROM media_refs WHERE owner_sequence_id = ?")
    assert(stmt, "Clip.assert_within_master_coverage: prepare failed")
    stmt:bind_value(1, sequence_id)
    assert(stmt:exec(), "Clip.assert_within_master_coverage: exec failed")
    local coverage_max = stmt:next() and stmt:value(0)
    stmt:finalize()
    if coverage_max and new_source_out > coverage_max then
        error(string.format("%s: source_out %d exceeds master coverage %d",
            label, new_source_out, coverage_max))
    end
end

--- List every clip whose sequence_id == the given sequence,
--- across all owner sequences. Used by GrowMasterMedium to find every
--- clip referencing a master so each can gain a companion clip.
function M.find_referencing_nested(sequence_id)
    assert(sequence_id and sequence_id ~= "",
        "Clip.find_referencing_nested: sequence_id required")
    local db = require("core.database").get_connection()
    local stmt = db:prepare([[
        SELECT id, project_id, owner_sequence_id, track_id, sequence_id,
               name, sequence_start_frame, duration_frames,
               source_in_frame, source_out_frame,
               master_layer_track_id, fps_mismatch_policy,
               enabled, volume, playhead_frame,
               source_in_subframe, source_out_subframe
        FROM clips WHERE sequence_id = ?
        ORDER BY owner_sequence_id, track_id, sequence_start_frame, id
    ]])
    assert(stmt, "Clip.find_referencing_nested: prepare failed")
    stmt:bind_value(1, sequence_id)
    assert(stmt:exec(), "Clip.find_referencing_nested: exec failed")
    local rows = {}
    while stmt:next() do
        rows[#rows + 1] = {
            id                    = stmt:value(0),
            project_id            = stmt:value(1),
            owner_sequence_id     = stmt:value(2),
            track_id              = stmt:value(3),
            sequence_id    = stmt:value(4),
            name                  = stmt:value(5),
            sequence_start_frame  = stmt:value(6),
            duration_frames       = stmt:value(7),
            source_in_frame       = stmt:value(8),
            source_out_frame      = stmt:value(9),
            master_layer_track_id = stmt:value(10),
            fps_mismatch_policy   = stmt:value(11),
            enabled               = stmt:value(12) == 1,
            volume                = stmt:value(13),
            playhead_frame        = stmt:value(14),
            source_in_subframe    = stmt:value(15),
            source_out_subframe   = stmt:value(16),
        }
    end
    stmt:finalize()
    return rows
end

--- List clips on a given owner_sequence_id, ordered by timeline.
--- Returns plain row tables (V13 shape).
function M.list_in_sequence(owner_sequence_id)
    assert(owner_sequence_id and owner_sequence_id ~= "",
        "Clip.list_in_sequence: owner_sequence_id required")
    local db = require("core.database").get_connection()
    local stmt = db:prepare([[
        SELECT id, project_id, owner_sequence_id, track_id, sequence_id,
               name, sequence_start_frame, duration_frames,
               source_in_frame, source_out_frame,
               master_layer_track_id, fps_mismatch_policy,
               enabled, volume, mark_in_frame, mark_out_frame, playhead_frame,
               source_in_subframe, source_out_subframe
        FROM clips WHERE owner_sequence_id = ?
        ORDER BY sequence_start_frame ASC, id ASC
    ]])
    assert(stmt, "Clip.list_in_sequence: prepare failed")
    stmt:bind_value(1, owner_sequence_id)
    assert(stmt:exec(), "Clip.list_in_sequence: exec failed")
    local rows = {}
    while stmt:next() do
        rows[#rows + 1] = {
            id                    = stmt:value(0),
            project_id            = stmt:value(1),
            owner_sequence_id     = stmt:value(2),
            track_id              = stmt:value(3),
            sequence_id    = stmt:value(4),
            name                  = stmt:value(5),
            sequence_start_frame  = stmt:value(6),
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
            source_in_subframe    = stmt:value(17),
            source_out_subframe   = stmt:value(18),
        }
    end
    stmt:finalize()
    return rows
end

--- Count clips that reference `sequence_id`, excluding one
--- (used by Unnest's orphan-cleanup decision).
function M.count_referencing_nested(sequence_id, exclude_clip_id)
    assert(sequence_id and sequence_id ~= "",
        "Clip.count_referencing_nested: sequence_id required")
    local db = require("core.database").get_connection()
    local stmt = db:prepare(
        "SELECT COUNT(*) FROM clips WHERE sequence_id = ? AND id != ?")
    assert(stmt, "Clip.count_referencing_nested: prepare failed")
    stmt:bind_value(1, sequence_id)
    stmt:bind_value(2, exclude_clip_id or "")
    assert(stmt:exec(), "Clip.count_referencing_nested: exec failed")
    assert(stmt:next())
    local n = stmt:value(0)
    stmt:finalize()
    return n
end

--- Move a clip to a different owner sequence (Nest / Unnest). Distinct
--- from M.update because owner_sequence_id is not in the structural-
--- protected updatable set there. Re-checks "clips must be owned by a kind='sequence' sequence" via the SQLite
--- trigger after the UPDATE.
---
--- @param id string
--- @param new_owner_sequence_id string  must reference a kind='sequence' seq
function M.transfer_owner(id, new_owner_sequence_id)
    assert(id and id ~= "", "Clip.transfer_owner: id required")
    assert(new_owner_sequence_id and new_owner_sequence_id ~= "",
        "Clip.transfer_owner: new_owner_sequence_id required")
    local db = require("core.database").get_connection()
    require("core.track_lock_guard").assert_clip_writable(db, id)
    local stmt = db:prepare(
        "UPDATE clips SET owner_sequence_id = ?, modified_at = ? WHERE id = ?")
    assert(stmt, "Clip.transfer_owner: prepare failed")
    stmt:bind_value(1, new_owner_sequence_id)
    stmt:bind_value(2, os.time())
    stmt:bind_value(3, id)
    local ok = stmt:exec()
    local err = (not ok) and stmt:last_error() or nil
    stmt:finalize()
    assert(ok, string.format(
        "Clip.transfer_owner: exec failed for id=%s: %s "
        .. "(trigger: clips must be owned by a kind='sequence' sequence — new owner must be kind='sequence')",
        id, tostring(err)))
end

--- Set the per-clip layer override. Distinct from M.update because Lua's
--- `pairs` skips nil values — passing nil through M.update silently
--- becomes a no-op rather than UPDATEing the column to NULL. This setter
--- always writes the column regardless.
---
--- @param id string
--- @param track_id string|nil  NULL = clear override (inherit nested
---                              sequence's default_video_layer_track_id)
function M.set_master_layer_track_id(id, track_id)
    assert(id and id ~= "", "Clip.set_master_layer_track_id: id required")
    local db = require("core.database").get_connection()
    require("core.track_lock_guard").assert_clip_writable(db, id)
    local stmt = db:prepare(
        "UPDATE clips SET master_layer_track_id = ?, modified_at = ? WHERE id = ?")
    assert(stmt, "Clip.set_master_layer_track_id: prepare failed")
    stmt:bind_value(1, track_id)   -- nil → SQL NULL
    stmt:bind_value(2, os.time())
    stmt:bind_value(3, id)
    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, string.format(
        "Clip.set_master_layer_track_id: exec failed for id=%s", id))
    return true
end

-- ===========================================================================
-- Feature 013 (T040): ripple + batch operations for Insert's write path.
-- ===========================================================================

--- Shift every clip on `track_id` whose `sequence_start_frame >= from_frame`
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
    require("core.track_lock_guard").assert_writable(db, { track_id })
    -- Order matters for the video-overlap trigger:
    --   negative shift: process clips in ASC order (lowest-start first
    --     moves left into now-empty space), no transient overlap.
    --   positive shift: process clips in DESC order (highest-start first
    --     moves right into now-empty space).
    -- A bulk UPDATE without ORDER would let SQLite pick row order
    -- arbitrarily; if it shifts a clip into a slot still occupied by
    -- the next-up clip, the trigger raises VIDEO_OVERLAP. Selecting
    -- ids first + UPDATE-by-id in the right order avoids that.
    local order = (shift > 0) and "DESC" or "ASC"
    local sel = db:prepare(string.format([[
        SELECT id FROM clips
        WHERE track_id = ? AND sequence_start_frame >= ?
        ORDER BY sequence_start_frame %s
    ]], order))
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
        SET sequence_start_frame = sequence_start_frame + ?,
            modified_at = strftime('%s','now')
        WHERE id = ?
    ]])
    assert(upd, "Clip.ripple_track_forward: update prepare failed")
    for _, cid in ipairs(ids) do
        upd:bind_value(1, shift)
        upd:bind_value(2, cid)
        assert(upd:exec(), "Clip.ripple_track_forward: update exec failed")
        upd:reset()
    end
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
    require("core.track_lock_guard").assert_clips_writable(db, clip_ids)
    local upd = db:prepare([[
        UPDATE clips
        SET sequence_start_frame = sequence_start_frame + ?,
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
    require("core.track_lock_guard").assert_clips_writable(db, clip_ids)
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

--- Return the id of the clip on `track_id` whose timeline range
--- STRICTLY contains `frame` (i.e. sequence_start < frame < sequence_end).
--- Used by Blade (T045a) — boundary-touching clips must NOT match because
--- splitting AT a boundary is a no-op refused by SplitClip.
--- Returns nil if no such clip exists.
function M.find_strictly_spanning(track_id, frame)
    assert(track_id and track_id ~= "",
        "Clip.find_strictly_spanning: track_id required")
    assert(type(frame) == "number",
        "Clip.find_strictly_spanning: frame must be integer")
    local db = require("core.database").get_connection()
    local stmt = db:prepare([[
        SELECT id FROM clips
        WHERE track_id = ?
          AND sequence_start_frame < ?
          AND (sequence_start_frame + duration_frames) > ?
        LIMIT 1
    ]])
    assert(stmt, "Clip.find_strictly_spanning: prepare failed")
    stmt:bind_value(1, track_id)
    stmt:bind_value(2, frame)
    stmt:bind_value(3, frame)
    assert(stmt:exec(), "Clip.find_strictly_spanning: exec failed")
    local id
    if stmt:next() then id = stmt:value(0) end
    stmt:finalize()
    return id
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
    require("core.track_lock_guard").assert_clip_writable(db, clip_id)
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
        SELECT id, project_id, owner_sequence_id, track_id, sequence_id,
               name, sequence_start_frame, duration_frames,
               source_in_frame, source_out_frame,
               source_in_subframe, source_out_subframe,
               master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
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
            sequence_id    = stmt:value(4),
            name                  = stmt:value(5),
            sequence_start_frame  = stmt:value(6),
            duration_frames       = stmt:value(7),
            source_in_frame       = stmt:value(8),
            source_out_frame      = stmt:value(9),
            source_in_subframe    = stmt:value(10),
            source_out_subframe   = stmt:value(11),
            master_layer_track_id = stmt:value(12),
            master_audio_track_id = stmt:value(13),
            fps_mismatch_policy   = stmt:value(14),
            enabled               = stmt:value(15) == 1,
            volume                = stmt:value(16),
            mark_in_frame         = stmt:value(17),
            mark_out_frame        = stmt:value(18),
            playhead_frame        = stmt:value(19),
        }
    end
    stmt:finalize()
    return row
end

--- Capture the FULL V13 state of a clip for undo: the row, its
--- clip_channel_override rows, and its clip_links membership (if any).
--- The returned table can be passed to Clip.restore_v13_state to
--- recreate the clip exactly as it was. Loud-fail if clip is missing
--- (capturing a non-existent clip is always a caller bug).
function M.capture_v13_state(clip_id)
    assert(clip_id and clip_id ~= "", "Clip.capture_v13_state: clip_id required")
    local row = M.load_v13_row(clip_id)
    assert(row, string.format(
        "Clip.capture_v13_state: clip %s not found", clip_id))

    local db = require("core.database").get_connection()

    local overrides = {}
    do
        local stmt = db:prepare([[
            SELECT channel_index, enabled, gain_db
            FROM clip_channel_override WHERE clip_id = ?
            ORDER BY channel_index ASC
        ]])
        assert(stmt, "Clip.capture_v13_state: override prepare failed")
        stmt:bind_value(1, clip_id)
        assert(stmt:exec(), "Clip.capture_v13_state: override exec failed")
        while stmt:next() do
            overrides[#overrides + 1] = {
                channel_index = stmt:value(0),
                enabled       = stmt:value(1),
                gain_db       = stmt:value(2),
            }
        end
        stmt:finalize()
    end

    local link
    do
        local stmt = db:prepare([[
            SELECT link_group_id, role, time_offset, enabled
            FROM clip_links WHERE clip_id = ?
            LIMIT 1
        ]])
        assert(stmt, "Clip.capture_v13_state: link prepare failed")
        stmt:bind_value(1, clip_id)
        assert(stmt:exec(), "Clip.capture_v13_state: link exec failed")
        if stmt:next() then
            link = {
                link_group_id = stmt:value(0),
                role          = stmt:value(1),
                time_offset   = stmt:value(2),
                enabled       = stmt:value(3) == 1,
            }
        end
        stmt:finalize()
    end

    return {
        row       = row,
        overrides = overrides,
        link      = link,
    }
end

--- Restore a clip from the state captured by Clip.capture_v13_state.
--- Re-INSERTs the clip row (owner-kind and source-window checks fire), the
--- clip_channel_override rows, and the clip_links row (if it had one).
--- The clip is assumed to be ABSENT before this call — restoring over
--- a live clip is a caller bug.
function M.restore_v13_state(state)
    assert(type(state) == "table", "Clip.restore_v13_state: state table required")
    assert(type(state.row) == "table", "Clip.restore_v13_state: state.row required")
    local r = state.row

    M._create_v13_row({
        id                    = r.id,
        project_id            = r.project_id,
        owner_sequence_id     = r.owner_sequence_id,
        track_id              = r.track_id,
        sequence_id    = r.sequence_id,
        name                  = r.name,
        sequence_start_frame  = r.sequence_start_frame,
        duration_frames       = r.duration_frames,
        source_in_frame       = r.source_in_frame,
        source_out_frame      = r.source_out_frame,
        source_in_subframe    = r.source_in_subframe,
        source_out_subframe   = r.source_out_subframe,
        master_layer_track_id = r.master_layer_track_id,
        master_audio_track_id = r.master_audio_track_id,
        fps_mismatch_policy   = r.fps_mismatch_policy,
        enabled               = r.enabled,
        volume                = r.volume,
        mark_in_frame         = r.mark_in_frame,
        mark_out_frame        = r.mark_out_frame,
        playhead_frame        = r.playhead_frame,
    })

    if state.overrides and #state.overrides > 0 then
        local db = require("core.database").get_connection()
        local stmt = db:prepare([[
            INSERT INTO clip_channel_override (clip_id, channel_index, enabled, gain_db)
            VALUES (?, ?, ?, ?)
        ]])
        assert(stmt, "Clip.restore_v13_state: override prepare failed")
        for _, o in ipairs(state.overrides) do
            stmt:bind_value(1, r.id)
            stmt:bind_value(2, o.channel_index)
            stmt:bind_value(3, o.enabled)
            stmt:bind_value(4, o.gain_db)
            assert(stmt:exec(),
                "Clip.restore_v13_state: override exec failed")
            stmt:reset()
        end
        stmt:finalize()
    end

    if state.link then
        local db = require("core.database").get_connection()
        local stmt = db:prepare([[
            INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
            VALUES (?, ?, ?, ?, ?)
        ]])
        assert(stmt, "Clip.restore_v13_state: link prepare failed")
        stmt:bind_value(1, state.link.link_group_id)
        stmt:bind_value(2, r.id)
        stmt:bind_value(3, state.link.role)
        stmt:bind_value(4, state.link.time_offset)
        stmt:bind_value(5, state.link.enabled and 1 or 0)
        assert(stmt:exec(),
            "Clip.restore_v13_state: link exec failed")
        stmt:finalize()
    end
end

return M
