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
-- Size: ~155 LOC
-- Volatility: unknown
--
-- @file track.lua
-- Original intent (unreviewed):
-- Lua model for timeline tracks. Supports both video and audio variants.
local database = require("core.database")
local uuid = require("uuid")

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

    local max_index = 0
    if stmt:exec() and stmt:next() then
        max_index = stmt:value(0) or 0
    end
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
               enabled, locked, muted, soloed, volume, pan
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
               enabled, locked, muted, soloed, volume, pan
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
            created_at = os.time(),
            modified_at = os.time()
        }
        tracks[#tracks + 1] = setmetatable(track, Track)
    end

    stmt:finalize()
    return tracks
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
    local stmt = conn:prepare([[
        INSERT INTO tracks
        (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            pan = excluded.pan
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

    local ok = stmt:exec()
    if not ok then
        local err = stmt:last_error()
        stmt:finalize()
        error(string.format("Track.save: failed for %s: %s", tostring(self.id), tostring(err)))
    end

    stmt:finalize()
    return ok
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

return Track
