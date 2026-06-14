--- Lua model for timeline tracks. Supports both video and audio variants.
local database = require("core.database")
local uuid = require("uuid")
local watchers = require("core.watchers")

local Track = {}
Track.__index = Track

local function resolve_db()
    local conn = database.get_connection()
    if not conn then
        error("Track: No database connection available")
    end
    return conn
end

local function determine_next_index(sequence_id, track_type, provided_index)
    if provided_index and provided_index > 0 then
        return provided_index
    end

    local conn = resolve_db()
    assert(conn, "Track.determine_next_index: no database connection")

    local stmt = assert(conn:prepare([[
        SELECT COALESCE(MAX(track_index), 0)
        FROM tracks
        WHERE sequence_id = ? AND track_type = ?
    ]]), "Track.determine_next_index: failed to prepare query")

    stmt:bind_value(1, sequence_id)
    stmt:bind_value(2, track_type)

    assert(stmt:exec(), "Track.determine_next_index: exec failed")
    assert(stmt:next(), "Track.determine_next_index: aggregate returned no row")
    local max_index = stmt:value(0)
    stmt:finalize()

    return max_index + 1
end

local function build_track(track_type, name, sequence_id, opts)
    assert(name and name ~= "", "Track.create: name is required")
    assert(sequence_id and sequence_id ~= "", "Track.create: sequence_id is required")

    opts = opts or {}
    local track = {
        id = opts.id or uuid.generate(),
        sequence_id = sequence_id,
        name = name,
        track_type = track_type,
        track_index = determine_next_index(sequence_id, track_type, opts.index),
        enabled = opts.enabled ~= false,
        locked = opts.locked == true,
        muted = opts.muted == true,
        soloed = opts.soloed == true,
        volume = opts.volume or 1.0, -- NSF-OK: 1.0 = unity gain (domain default for new tracks)
        pan = opts.pan or 0.0, -- NSF-OK: 0.0 = center pan (domain default for new tracks)
        -- NSF-OK: 'ripple' is the domain default (spec §3, matches schema DEFAULT).
        sync_mode = opts.sync_mode or "ripple",
        -- NSF-OK: autoselect ON is the domain default (spec §3 FR-038,
        -- matches schema DEFAULT 1). New track participates in selection-
        -- driven ops until the user opts out via the rec-patch-id click.
        autoselect = opts.autoselect ~= false,
        source_kind = opts.source_kind or nil,
        created_at = os.time(),
        modified_at = os.time()
    }

    return setmetatable(track, Track)
end

function Track.create_video(name, sequence_id, opts)
    assert(name, "Track.create_video: name is required")
    return build_track("VIDEO", name, sequence_id, opts)
end

function Track.create_audio(name, sequence_id, opts)
    assert(name, "Track.create_audio: name is required")
    return build_track("AUDIO", name, sequence_id, opts)
end

function Track.load(id)
    if not id or id == "" then
        error("Track.load: id is required")
    end

    local conn = resolve_db()
    if not conn then
        return nil
    end

    local stmt = conn:prepare([[
        SELECT id, sequence_id, name, track_type, track_index,
               enabled, locked, muted, soloed, volume, pan, sync_mode, autoselect,
               source_kind
        FROM tracks WHERE id = ?
    ]])

    if not stmt then
        error("Track.load: failed to prepare query")
    end

    stmt:bind_value(1, id)
    if not stmt:exec() or not stmt:next() then
        stmt:finalize()
        return nil
    end

    local sync_mode_val = stmt:value(11)
    assert(sync_mode_val and sync_mode_val ~= "", string.format(
        "Track.load: track %s has NULL sync_mode — project DB is older than "
        .. "schema_version=10; re-import the project from source (no in-place "
        .. "migration path per rule 2.15)",
        tostring(id)))
    local track = {
        id = stmt:value(0),
        sequence_id = stmt:value(1),
        name = stmt:value(2),
        track_type = stmt:value(3),
        track_index = stmt:value(4),
        enabled = stmt:value(5) == 1,
        locked = stmt:value(6) == 1,
        muted = stmt:value(7) == 1,
        soloed = stmt:value(8) == 1,
        volume = stmt:value(9),
        pan = stmt:value(10),
        sync_mode = sync_mode_val,
        autoselect = stmt:value(12) == 1,
        source_kind = stmt:value(13),
        created_at = os.time(),
        modified_at = os.time()
    }

    stmt:finalize()
    return setmetatable(track, Track)
end

function Track.find_by_sequence(sequence_id, track_type)
    assert(sequence_id and sequence_id ~= "", "Track.find_by_sequence: sequence_id is required")

    local conn = resolve_db()
    assert(conn, "Track.find_by_sequence: no database connection available")

    local sql = [[
        SELECT id, sequence_id, name, track_type, track_index,
               enabled, locked, muted, soloed, volume, pan, sync_mode, autoselect,
               source_kind
        FROM tracks
        WHERE sequence_id = ?
    ]]

    if track_type and track_type ~= "" then
        sql = sql .. " AND track_type = ?"
    end

    sql = sql .. " ORDER BY track_index ASC"

    local stmt = conn:prepare(sql)
    assert(stmt, string.format(
        "Track.find_by_sequence: failed to prepare query for sequence_id=%s",
        tostring(sequence_id)
    ))

    stmt:bind_value(1, sequence_id)
    if track_type and track_type ~= "" then
        stmt:bind_value(2, track_type)
    end

    local tracks = {}
    local exec_ok = stmt:exec()
    assert(exec_ok, string.format(
        "Track.find_by_sequence: query execution failed for sequence_id=%s",
        tostring(sequence_id)
    ))

    while stmt:next() do
        local track_id = stmt:value(0)
        local sync_mode_val = stmt:value(11)
        assert(sync_mode_val and sync_mode_val ~= "", string.format(
            "Track.find_by_sequence: track %s has NULL sync_mode — project DB "
            .. "is older than schema_version=10; re-import the project from "
            .. "source (no in-place migration path per rule 2.15)",
            tostring(track_id)))
        local track = {
            id = track_id,
            sequence_id = stmt:value(1),
            name = stmt:value(2),
            track_type = stmt:value(3),
            track_index = stmt:value(4),
            enabled = stmt:value(5) == 1,
            locked = stmt:value(6) == 1,
            muted = stmt:value(7) == 1,
            soloed = stmt:value(8) == 1,
            volume = stmt:value(9),
            pan = stmt:value(10),
            sync_mode = sync_mode_val,
            autoselect = stmt:value(12) == 1,
            source_kind = stmt:value(13),
            created_at = os.time(),
            modified_at = os.time()
        }
        tracks[#tracks + 1] = setmetatable(track, Track)
    end

    stmt:finalize()
    return tracks
end

--- Find a track by (sequence_id, track_type, track_index). Used by
--- Unnest to locate the parent sequence's matching track for an inner
--- clip during expansion. Returns the track id or nil.
function Track.find_at(sequence_id, track_type, track_index)
    assert(sequence_id and sequence_id ~= "",
        "Track.find_at: sequence_id required")
    assert(track_type == "VIDEO" or track_type == "AUDIO",
        "Track.find_at: track_type must be VIDEO or AUDIO")
    assert(type(track_index) == "number",
        "Track.find_at: track_index must be integer")
    local conn = resolve_db()
    local stmt = conn:prepare(
        "SELECT id FROM tracks WHERE sequence_id = ? AND track_type = ? "
        .. "AND track_index = ?")
    assert(stmt, "Track.find_at: prepare failed")
    stmt:bind_value(1, sequence_id)
    stmt:bind_value(2, track_type)
    stmt:bind_value(3, track_index)
    assert(stmt:exec(), "Track.find_at: exec failed")
    local id
    if stmt:next() then id = stmt:value(0) end
    stmt:finalize()
    return id
end

function Track.get_sequence_id(track_id)
    assert(track_id and track_id ~= "", "Track.get_sequence_id: track_id is required")

    local conn = resolve_db()
    assert(conn, "Track.get_sequence_id: no database connection available")

    local stmt = conn:prepare("SELECT sequence_id FROM tracks WHERE id = ?")
    assert(stmt, string.format(
        "Track.get_sequence_id: failed to prepare query for track_id=%s",
        tostring(track_id)
    ))

    stmt:bind_value(1, track_id)
    local exec_ok = stmt:exec()
    assert(exec_ok, string.format(
        "Track.get_sequence_id: query execution failed for track_id=%s",
        tostring(track_id)
    ))

    local sequence_id = nil
    if stmt:next() then
        sequence_id = stmt:value(0)
    end

    stmt:finalize()

    assert(sequence_id and sequence_id ~= "", string.format(
        "Track.get_sequence_id: track_id=%s not found in database",
        tostring(track_id)
    ))

    return sequence_id
end

function Track:save()
    assert(self and self.id and self.id ~= "", "Track.save: invalid track or missing id")
    assert(self.sequence_id and self.sequence_id ~= "", "Track.save: sequence_id is required")

    local conn = resolve_db()
    if not conn then
        return false
    end

    self.modified_at = os.time()

    -- CRITICAL: Use ON CONFLICT DO UPDATE instead of INSERT OR REPLACE
    -- INSERT OR REPLACE triggers DELETE first, which cascades to delete clips via foreign keys!
    assert(self.sync_mode and self.sync_mode ~= "",
        string.format("Track.save: sync_mode is required for track %s", tostring(self.id)))

    local stmt = conn:prepare([[
        INSERT INTO tracks
        (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan, sync_mode, autoselect, source_kind)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            sequence_id = excluded.sequence_id,
            name = excluded.name,
            track_type = excluded.track_type,
            track_index = excluded.track_index,
            enabled = excluded.enabled,
            locked = excluded.locked,
            muted = excluded.muted,
            soloed = excluded.soloed,
            volume = excluded.volume,
            pan = excluded.pan,
            sync_mode = excluded.sync_mode,
            autoselect = excluded.autoselect,
            source_kind = excluded.source_kind
    ]])

    assert(stmt, "Track.save: failed to prepare insert statement")

    stmt:bind_value(1, self.id)
    stmt:bind_value(2, self.sequence_id)
    stmt:bind_value(3, self.name)
    stmt:bind_value(4, self.track_type)
    stmt:bind_value(5, self.track_index)
    stmt:bind_value(6, self.enabled and 1 or 0)
    stmt:bind_value(7, self.locked and 1 or 0)
    stmt:bind_value(8, self.muted and 1 or 0)
    stmt:bind_value(9, self.soloed and 1 or 0)
    stmt:bind_value(10, self.volume)
    stmt:bind_value(11, self.pan)
    stmt:bind_value(12, self.sync_mode)
    stmt:bind_value(13, self.autoselect and 1 or 0)
    stmt:bind_value(14, self.source_kind)

    local ok = stmt:exec()
    if not ok then
        local err = stmt:last_error()
        stmt:finalize()
        error(string.format("Track.save: failed for %s: %s", tostring(self.id), tostring(err)))
    end

    stmt:finalize()

    watchers.notify_track(self.id, self.sequence_id)

    return true
end

-- Count tracks for a sequence
function Track.count_for_sequence(sequence_id)
    assert(sequence_id, "Track.count_for_sequence: sequence_id is required")

    local db = require("core.database")
    local conn = assert(db.get_connection(), "Track.count_for_sequence: no database connection")
    local stmt = assert(conn:prepare("SELECT COUNT(*) FROM tracks WHERE sequence_id = ?"),
        "Track.count_for_sequence: failed to prepare query for sequence_id=" .. tostring(sequence_id))

    stmt:bind_value(1, sequence_id)
    assert(stmt:exec(), "Track.count_for_sequence: query execution failed for sequence_id=" .. tostring(sequence_id))
    assert(stmt:next(), "Track.count_for_sequence: no result row")
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

-- Ensure default tracks exist for a sequence
-- Creates V1, V2, V3 video tracks and A1, A2, A3 audio tracks if none exist
function Track.ensure_defaults_for_sequence(sequence_id)
    assert(sequence_id, "Track.ensure_defaults_for_sequence: sequence_id is required")

    if Track.count_for_sequence(sequence_id) > 0 then
        return true  -- Already has tracks
    end

    -- Create default video tracks
    for i = 1, 3 do
        local track = Track.create_video("V" .. i, sequence_id, {index = i})
        if not track or not track:save() then
            return false
        end
    end

    -- Create default audio tracks
    for i = 1, 3 do
        local track = Track.create_audio("A" .. i, sequence_id, {index = i})
        if not track or not track:save() then
            return false
        end
    end

    return true
end

-- ===========================================================================
-- Feature 013: Track.delete with last-video-track guard (repoint-or-refuse)
-- ===========================================================================
-- Deleting a video track that's the default_video_layer_track_id of its
-- sequence requires repointing to another live V track of the same sequence,
-- OR (if this was the last V track AND no clips reference the sequence)
-- setting the default to NULL. If there's no viable target AND live clips
-- reference the sequence, refuse (last video track cannot be deleted while referenced).

--- Delete a track. Enforces "last video track cannot be deleted" when the track is a video track and its
--- sequence's default_video_layer_track_id points at it.
function Track.delete(track_id)
    assert(track_id and track_id ~= "", "Track.delete: track_id required")
    local db = database.get_connection()

    -- Look up the track: its sequence_id and track_type.
    local fetch = db:prepare(
        "SELECT sequence_id, track_type FROM tracks WHERE id = ?")
    assert(fetch, "Track.delete: fetch prepare failed")
    fetch:bind_value(1, track_id)
    assert(fetch:exec(), "Track.delete: fetch exec failed")
    assert(fetch:next(), string.format(
        "Track.delete: track %s not found", tostring(track_id)))
    local seq_id = fetch:value(0)
    local track_type = fetch:value(1)
    fetch:finalize()

    -- Is the track's sequence pointing at THIS track as its default V layer?
    local seq_stmt = db:prepare(
        "SELECT kind, default_video_layer_track_id FROM sequences WHERE id = ?")
    assert(seq_stmt, "Track.delete: seq prepare failed")
    seq_stmt:bind_value(1, seq_id)
    assert(seq_stmt:exec(), "Track.delete: seq exec failed")
    assert(seq_stmt:next(), string.format(
        "Track.delete: sequence %s not found for track %s", tostring(seq_id), tostring(track_id)))
    local seq_kind = seq_stmt:value(0)
    local default_track = seq_stmt:value(1)
    seq_stmt:finalize()

    local is_default = (track_type == "VIDEO") and (default_track == track_id)

    if is_default then
        -- Find another live V track of the same sequence with the lowest index.
        local other = db:prepare([[
            SELECT id FROM tracks
            WHERE sequence_id = ? AND track_type = 'VIDEO' AND id != ?
            ORDER BY track_index ASC LIMIT 1
        ]])
        assert(other, "Track.delete: other-v prepare failed")
        other:bind_value(1, seq_id)
        other:bind_value(2, track_id)
        assert(other:exec(), "Track.delete: other-v exec failed")
        local replacement
        if other:next() then replacement = other:value(0) end
        other:finalize()

        if replacement then
            -- Repoint default before delete.
            local rp = db:prepare(
                "UPDATE sequences SET default_video_layer_track_id = ? WHERE id = ?")
            assert(rp, "Track.delete: repoint prepare failed")
            rp:bind_value(1, replacement)
            rp:bind_value(2, seq_id)
            assert(rp:exec(), "Track.delete: repoint exec failed")
            rp:finalize()
        else
            -- No other V track. If any clip anywhere references this sequence
            -- (acyclic DAG + last video track: we'd orphan the clip's visual content), refuse.
            local ref = db:prepare(
                "SELECT 1 FROM clips WHERE sequence_id = ? LIMIT 1")
            assert(ref, "Track.delete: ref prepare failed")
            ref:bind_value(1, seq_id)
            assert(ref:exec(), "Track.delete: ref exec failed")
            local referenced = ref:next()
            ref:finalize()
            assert(not referenced, string.format(
                "Track.delete: cannot delete last VIDEO track %s of sequence %s "
                .. "while live clips reference the sequence (kind=%s) — last video track cannot be deleted while referenced",
                tostring(track_id), tostring(seq_id), tostring(seq_kind)))
            -- No references: clear default before the FK's ON DELETE SET NULL
            -- would do so, so default_video_layer_track_id non-NULL invariant holds throughout.
            local cl = db:prepare(
                "UPDATE sequences SET default_video_layer_track_id = NULL WHERE id = ?")
            assert(cl, "Track.delete: clear-default prepare failed")
            cl:bind_value(1, seq_id)
            assert(cl:exec(), "Track.delete: clear-default exec failed")
            cl:finalize()
        end
    end

    -- Refuse to delete while any clip still references this track. The FK
    -- declares ON DELETE CASCADE, so a naïve DELETE silently takes its clips
    -- with it — fine for forward edits, catastrophic for undo of auto-track
    -- creation (the undoer is supposed to have removed the clips first; if
    -- one is still here it means the undoer's mutation order has a bug, and
    -- masking it as "delete cascades them too" hides the real defect).
    local clip_check = db:prepare("SELECT 1 FROM clips WHERE track_id = ? LIMIT 1")
    assert(clip_check, "Track.delete: clip_check prepare failed")
    clip_check:bind_value(1, track_id)
    assert(clip_check:exec(), "Track.delete: clip_check exec failed")
    local has_clips = clip_check:next()
    clip_check:finalize()
    assert(not has_clips, string.format(
        "Track.delete: refusing to delete track %s — clips still reference it. "
        .. "Caller must remove or relocate the clips first (FK is ON DELETE "
        .. "CASCADE so a delete here would silently destroy the clip rows).",
        tostring(track_id)))

    -- Delete the track.
    local del = db:prepare("DELETE FROM tracks WHERE id = ?")
    assert(del, "Track.delete: delete prepare failed")
    del:bind_value(1, track_id)
    assert(del:exec(), "Track.delete: delete exec failed")
    del:finalize()

    watchers.notify_track(track_id, seq_id)

    return true
end

return Track
