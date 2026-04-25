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

-- Forward-declare so load_masterclip_stream can call it
local load_internal

--- IS-a: a masterclip is both a sequence and a clip. When the caller asks for
--- a clip by masterclip sequence ID, resolve to the first stream clip inside
--- that sequence. This is the ONE place that handles the dual identity.
-- V13: master sequences hold media_refs, not stream clips. The pre-013
-- IS-a alias (clip_id == masterclip_seq_id resolves to the inner stream clip)
-- has no V13 analogue. Callers that need media metadata for a master sequence
-- should query media_refs directly.
local function load_masterclip_stream(_db, _seq_id)
    return nil
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

    -- V13 SELECT: clips no longer carry clip_kind / media_id / master_clip_id /
    -- fps_numerator / fps_denominator / offline. The clip's source-side
    -- timebase comes from its nested sequence; clip_kind is derived from the
    -- owner-track type; media metadata is resolved through nested→master→
    -- media_ref→media when nested is a master.
    local query = db:prepare([[
        SELECT c.id, c.project_id, c.name, c.track_id,
               c.owner_sequence_id, c.nested_sequence_id,
               c.timeline_start_frame, c.duration_frames,
               c.source_in_frame, c.source_out_frame,
               c.master_layer_track_id, c.master_audio_track_id,
               c.fps_mismatch_policy,
               c.enabled, c.volume, c.mark_in_frame, c.mark_out_frame,
               c.playhead_frame, c.created_at, c.modified_at,
               t.track_type,
               owner_seq.fps_numerator, owner_seq.fps_denominator,
               nested_seq.kind, nested_seq.fps_numerator, nested_seq.fps_denominator,
               mr.media_id, m.name, m.file_path, m.offline_note
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        JOIN sequences owner_seq ON c.owner_sequence_id = owner_seq.id
        JOIN sequences nested_seq ON c.nested_sequence_id = nested_seq.id
        LEFT JOIN media_refs mr ON mr.owner_sequence_id = c.nested_sequence_id
                                AND nested_seq.kind = 'master'
        LEFT JOIN media m ON m.id = mr.media_id
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
        if raise_errors then
            error(string.format("Clip.load_failed: Clip not found: %s", clip_id))
        end
        return nil
    end

    local nested_fps_num = query:value(24)
    local nested_fps_den = query:value(25)
    if not nested_fps_num or nested_fps_num <= 0 or not nested_fps_den or nested_fps_den <= 0 then
        query:finalize()
        error(string.format(
            "Clip.load_failed: clip %s nested-sequence has invalid frame rate (%s/%s)",
            clip_id, tostring(nested_fps_num), tostring(nested_fps_den)))
    end
    local owner_fps_num = query:value(21)
    local owner_fps_den = query:value(22)
    if not owner_fps_num or owner_fps_num <= 0 or not owner_fps_den or owner_fps_den <= 0 then
        query:finalize()
        error(string.format(
            "Clip.load_failed: clip %s owner-sequence has invalid frame rate (%s/%s)",
            clip_id, tostring(owner_fps_num), tostring(owner_fps_den)))
    end

    local track_type = query:value(20)
    local nested_id = query:value(5)

    local clip = {
        id = query:value(0),
        project_id = query:value(1),
        name = query:value(2),
        track_id = query:value(3),
        owner_sequence_id = query:value(4),
        nested_sequence_id = nested_id,

        timeline_start = assert(query:value(6), "Clip.load: timeline_start_frame is NULL"),
        duration = assert(query:value(7), "Clip.load: duration_frames is NULL"),
        source_in = assert(query:value(8), "Clip.load: source_in_frame is NULL"),
        source_out = assert(query:value(9), "Clip.load: source_out_frame is NULL"),

        master_layer_track_id = query:value(10),
        master_audio_track_id = query:value(11),
        fps_mismatch_policy   = query:value(12),

        -- Source-side timebase (the nested sequence's rate).
        rate = {
            fps_numerator = nested_fps_num,
            fps_denominator = nested_fps_den,
        },
        owner_rate = {
            fps_numerator = owner_fps_num,
            fps_denominator = owner_fps_den,
        },

        enabled = query:value(13) == 1 or query:value(13) == true,
        volume = assert(query:value(14),
            string.format("Clip.load: volume is NULL for clip %s", tostring(clip_id))),
        mark_in = query:value(15),
        mark_out = query:value(16),
        playhead_frame = assert(query:value(17),
            string.format("Clip.load: playhead_frame is NULL for clip %s", tostring(clip_id))),
        created_at = query:value(18),
        modified_at = query:value(19),

        track_type = track_type,
        nested_sequence_kind = query:value(23),

        -- Compatibility surfaces — see database.build_clip_from_query_row.
        clip_kind = (track_type == "VIDEO") and "video" or "audio",
        media_id = query:value(26),
        media_name = query:value(27),
        media_path = query:value(28),
        offline_note = query:value(29),
        master_clip_id = nested_id,
        offline = false,
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
--- Create a clip row (V13). Args: a single table with the V13 fields:
--- id (optional), project_id, owner_sequence_id, track_id,
--- nested_sequence_id, name, timeline_start_frame, duration_frames,
--- source_in_frame, source_out_frame, master_layer_track_id (nullable),
--- fps_mismatch_policy ('resample'|'passthrough'), enabled, volume,
--- mark_in_frame (nullable), mark_out_frame (nullable), playhead_frame.
--- Returns the clip id (string). INV-2/INV-4 enforced via the model
--- helpers + DB triggers.
---
--- The legacy positional form (name, media_id, opts) and its V8 column
--- writes (clip_kind/master_clip_id/media_id/offline) were deleted per
--- FR-018. Callers that need a master sequence call Sequence.ensure_master
--- (which writes media_refs, not clips).
function M.create(fields)
    assert(type(fields) == "table",
        "Clip.create: fields table required (V13 table form). Legacy "
        .. "positional form was removed under FR-018. To create a master "
        .. "from a media file, use Sequence.ensure_master.")
    assert(fields.nested_sequence_id ~= nil,
        "Clip.create: 'nested_sequence_id' is required (V13). Old callers "
        .. "passing 'media_id' / 'master_clip_id' / 'clip_kind' must "
        .. "migrate to the V13 model.")
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
    -- V13: clip_kind is a derived/compat surface (from track type); not a real
    -- column. self.nested_sequence_id replaces master_clip_id.
    local nested_id = self.nested_sequence_id or self.master_clip_id
    assert(nested_id and nested_id ~= "",
        "Clip.save: nested_sequence_id (or master_clip_id alias) required for clip " .. tostring(self.id))
    self.offline = false
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
            SET project_id = ?, name = ?, track_id = ?,
                owner_sequence_id = ?, nested_sequence_id = ?,
                timeline_start_frame = ?, duration_frames = ?,
                source_in_frame = ?, source_out_frame = ?,
                master_layer_track_id = ?, master_audio_track_id = ?,
                fps_mismatch_policy = ?,
                enabled = ?, volume = ?,
                mark_in_frame = ?, mark_out_frame = ?, playhead_frame = ?,
                modified_at = strftime('%s','now')
            WHERE id = ?
        ]])
    else
        query = db:prepare([[
            INSERT INTO clips (
                id, project_id, name, track_id,
                owner_sequence_id, nested_sequence_id,
                timeline_start_frame, duration_frames,
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

    assert(query, "Clip.save: Failed to prepare query for clip " .. tostring(self.id))

    local function bind_nullable(stmt, idx, val)
        if val ~= nil then
            stmt:bind_value(idx, val)
        elseif stmt.bind_null then
            stmt:bind_null(idx)
        else
            stmt:bind_value(idx, nil)
        end
    end

    local fps_policy = self.fps_mismatch_policy or "resample"
    if exists then
        query:bind_value(1, self.project_id)
        query:bind_value(2, self.name or "")
        query:bind_value(3, self.track_id)
        query:bind_value(4, self.owner_sequence_id)
        query:bind_value(5, nested_id)
        query:bind_value(6, db_start_frame)
        query:bind_value(7, db_duration_frames)
        query:bind_value(8, db_source_in_frame)
        query:bind_value(9, db_source_out_frame)
        bind_nullable(query, 10, self.master_layer_track_id)
        bind_nullable(query, 11, self.master_audio_track_id)
        query:bind_value(12, fps_policy)
        query:bind_value(13, self.enabled and 1 or 0)
        query:bind_value(14, self.volume)
        bind_nullable(query, 15, self.mark_in)
        bind_nullable(query, 16, self.mark_out)
        query:bind_value(17, self.playhead_frame)
        query:bind_value(18, self.id)
    else
        query:bind_value(1, self.id)
        query:bind_value(2, self.project_id)
        query:bind_value(3, self.name or "")
        query:bind_value(4, self.track_id)
        query:bind_value(5, self.owner_sequence_id)
        query:bind_value(6, nested_id)
        query:bind_value(7, db_start_frame)
        query:bind_value(8, db_duration_frames)
        query:bind_value(9, db_source_in_frame)
        query:bind_value(10, db_source_out_frame)
        bind_nullable(query, 11, self.master_layer_track_id)
        bind_nullable(query, 12, self.master_audio_track_id)
        query:bind_value(13, fps_policy)
        query:bind_value(14, self.enabled and 1 or 0)
        query:bind_value(15, self.volume)
        bind_nullable(query, 16, self.mark_in)
        bind_nullable(query, 17, self.mark_out)
        query:bind_value(18, self.playhead_frame)
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
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, mark_in_frame, mark_out_frame, playhead_frame,
            created_at, modified_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
    stmt:bind_value(12, fields.master_audio_track_id)  -- nullable (Expand/Collapse)
    stmt:bind_value(13, fields.fps_mismatch_policy)
    stmt:bind_value(14, to_int_bool(fields.enabled))
    stmt:bind_value(15, fields.volume)
    stmt:bind_value(16, fields.mark_in_frame)    -- nullable
    stmt:bind_value(17, fields.mark_out_frame)   -- nullable
    stmt:bind_value(18, fields.playhead_frame)
    stmt:bind_value(19, now)
    stmt:bind_value(20, fields.modified_at or now)

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

--- List every clip whose nested_sequence_id == the given sequence,
--- across all owner sequences. Used by GrowMasterMedium to find every
--- clip referencing a master so each can gain a companion clip.
function M.find_referencing_nested(nested_sequence_id)
    assert(nested_sequence_id and nested_sequence_id ~= "",
        "Clip.find_referencing_nested: nested_sequence_id required")
    local db = require("core.database").get_connection()
    local stmt = db:prepare([[
        SELECT id, project_id, owner_sequence_id, track_id, nested_sequence_id,
               name, timeline_start_frame, duration_frames,
               source_in_frame, source_out_frame,
               master_layer_track_id, fps_mismatch_policy,
               enabled, volume, playhead_frame
        FROM clips WHERE nested_sequence_id = ?
        ORDER BY owner_sequence_id, track_id, timeline_start_frame, id
    ]])
    assert(stmt, "Clip.find_referencing_nested: prepare failed")
    stmt:bind_value(1, nested_sequence_id)
    assert(stmt:exec(), "Clip.find_referencing_nested: exec failed")
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
            playhead_frame        = stmt:value(14),
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
        SELECT id, project_id, owner_sequence_id, track_id, nested_sequence_id,
               name, timeline_start_frame, duration_frames,
               source_in_frame, source_out_frame,
               master_layer_track_id, fps_mismatch_policy,
               enabled, volume, mark_in_frame, mark_out_frame, playhead_frame
        FROM clips WHERE owner_sequence_id = ?
        ORDER BY timeline_start_frame ASC, id ASC
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

--- Count clips that reference `nested_sequence_id`, excluding one
--- (used by Unnest's orphan-cleanup decision).
function M.count_referencing_nested(nested_sequence_id, exclude_clip_id)
    assert(nested_sequence_id and nested_sequence_id ~= "",
        "Clip.count_referencing_nested: nested_sequence_id required")
    local db = require("core.database").get_connection()
    local stmt = db:prepare(
        "SELECT COUNT(*) FROM clips WHERE nested_sequence_id = ? AND id != ?")
    assert(stmt, "Clip.count_referencing_nested: prepare failed")
    stmt:bind_value(1, nested_sequence_id)
    stmt:bind_value(2, exclude_clip_id or "")
    assert(stmt:exec(), "Clip.count_referencing_nested: exec failed")
    assert(stmt:next())
    local n = stmt:value(0) or 0
    stmt:finalize()
    return n
end

--- Move a clip to a different owner sequence (Nest / Unnest). Distinct
--- from M.update because owner_sequence_id is not in the structural-
--- protected updatable set there. Re-checks INV-2 via the SQLite
--- trigger after the UPDATE.
---
--- @param id string
--- @param new_owner_sequence_id string  must reference a kind='nested' seq
function M.transfer_owner(id, new_owner_sequence_id)
    assert(id and id ~= "", "Clip.transfer_owner: id required")
    assert(new_owner_sequence_id and new_owner_sequence_id ~= "",
        "Clip.transfer_owner: new_owner_sequence_id required")
    local db = require("core.database").get_connection()
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
        .. "(likely INV-2 trigger — new owner must be kind='nested')",
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
        WHERE track_id = ? AND timeline_start_frame >= ?
        ORDER BY timeline_start_frame %s
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
        SET timeline_start_frame = timeline_start_frame + ?,
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

--- Return the id of the clip on `track_id` whose timeline range
--- STRICTLY contains `frame` (i.e. timeline_start < frame < timeline_end).
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
          AND timeline_start_frame < ?
          AND (timeline_start_frame + duration_frames) > ?
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
            nested_sequence_id    = stmt:value(4),
            name                  = stmt:value(5),
            timeline_start_frame  = stmt:value(6),
            duration_frames       = stmt:value(7),
            source_in_frame       = stmt:value(8),
            source_out_frame      = stmt:value(9),
            master_layer_track_id = stmt:value(10),
            master_audio_track_id = stmt:value(11),
            fps_mismatch_policy   = stmt:value(12),
            enabled               = stmt:value(13) == 1,
            volume                = stmt:value(14),
            mark_in_frame         = stmt:value(15),
            mark_out_frame        = stmt:value(16),
            playhead_frame        = stmt:value(17),
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
--- Re-INSERTs the clip row (INV-2 + INV-4 fire), the
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
        nested_sequence_id    = r.nested_sequence_id,
        name                  = r.name,
        timeline_start_frame  = r.timeline_start_frame,
        duration_frames       = r.duration_frames,
        source_in_frame       = r.source_in_frame,
        source_out_frame      = r.source_out_frame,
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
