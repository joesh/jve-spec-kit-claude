-- models/media_ref.lua — feature 013
--
-- Responsibilities:
-- - CRUD on rows in the `media_refs` table: direct file references that live
--   inside master sequences (sequences.kind='master').
-- - Enforce "media_refs must be owned by a kind='master' sequence" at the model layer with actionable asserts (rule 1.14):
--   every media_ref row's owner_sequence_id must reference a master sequence.
-- - Require explicit values for every state column on INSERT (rule 2.13).
--
-- Non-goals:
-- - Audio channel state (lives in media_refs_channel_state).
-- - Layer selection (lives on clips.master_layer_track_id).
-- - Timebase — dereferences to media.fps_numerator/denominator.

local uuid = require("uuid")
local database = require("core.database")

local M = {}

-- Fetch the referenced sequence's kind, asserting the row exists.
local function fetch_sequence_kind(db, sequence_id)
    local stmt = db:prepare("SELECT kind FROM sequences WHERE id = ?")
    assert(stmt, "MediaRef: failed to prepare sequence kind query")
    stmt:bind_value(1, sequence_id)
    assert(stmt:exec(), "MediaRef: sequence kind query failed")
    local found, kind
    if stmt:next() then
        found = true
        kind = stmt:value(0)
    end
    stmt:finalize()
    return found, kind
end

--- Assert that the target sequence exists and has kind='master' (media_refs must be owned by a kind='master' sequence).
--- Message names the media_ref id, the owner_sequence_id, and the actual kind
--- (rule 1.14 — actionable context).
function M.assert_owning_is_master(db, media_ref_id, owner_sequence_id)
    local found, kind = fetch_sequence_kind(db, owner_sequence_id)
    assert(found, string.format(
        "MediaRef.assert_owning_is_master: owner_sequence_id=%s not found (media_ref=%s)",
        tostring(owner_sequence_id), tostring(media_ref_id)))
    assert(kind == "master", string.format(
        "MediaRef.assert_owning_is_master: media_refs must be owned by a kind='master' sequence; media_ref=%s owner_sequence_id=%s "
        .. "kind='%s' (expected 'master')",
        tostring(media_ref_id), tostring(owner_sequence_id), tostring(kind)))
end

-- Required-on-INSERT columns per data-model.md. Rule 2.13: no silent defaults.
local REQUIRED_COLUMNS = {
    "project_id", "owner_sequence_id", "track_id", "media_id",
    "source_in_frame", "source_out_frame",
    "sequence_start_frame", "duration_frames",
    "enabled", "volume", "playhead_frame",
}

local function validate_required(fields)
    for _, col in ipairs(REQUIRED_COLUMNS) do
        local v = fields[col]
        assert(v ~= nil, string.format(
            "MediaRef.create: '%s' is required (rule 2.13 — no column defaults)", col))
    end
    assert(fields.duration_frames > 0,
        "MediaRef.create: duration_frames must be > 0")
end

-- Coerce enabled/volume to SQL-friendly forms.
local function to_int_bool(v)
    if v == true or v == 1 then return 1 end
    if v == false or v == 0 then return 0 end
    error("MediaRef: boolean must be true/false or 1/0; got " .. tostring(v))
end

-- 018 V3 / FR-008: AUDIO media_refs MUST carry audio_sample_rate; the
-- resolver depends on it for sample math. Pull track_type and assert
-- explicitly — no silent default (rule 2.13).
local function assert_audio_rate_for_kind(db, fields, id)
    local stmt = db:prepare("SELECT track_type FROM tracks WHERE id = ?")
    assert(stmt, "MediaRef.create: prepare track_type query failed")
    stmt:bind_value(1, fields.track_id)
    assert(stmt:exec(), "MediaRef.create: track_type query failed")
    assert(stmt:next(), string.format(
        "MediaRef.create: track not found for track_id=%s (media_ref=%s)",
        tostring(fields.track_id), tostring(id)))
    local tt = stmt:value(0)
    stmt:finalize()
    if tt == "AUDIO" then
        assert(fields.audio_sample_rate ~= nil, string.format(
            "MediaRef.create: AUDIO media_ref %s missing audio_sample_rate "
            .. "(track_id=%s; rule 2.13 — no silent default; FR-008 requires it)",
            tostring(id), tostring(fields.track_id)))
        -- 023: each audio track IS one file channel (one clip per stream); the
        -- ref must name which file channel it reads. No silent default (2.13).
        assert(type(fields.source_channel) == "number"
            and fields.source_channel >= 0
            and fields.source_channel == math.floor(fields.source_channel),
            string.format(
            "MediaRef.create: AUDIO media_ref %s missing source_channel "
            .. "(track_id=%s; rule 2.13 — each audio ref reads one file channel, "
            .. "0-based); got %s", tostring(id), tostring(fields.track_id),
            tostring(fields.source_channel)))
    end
end

--- Create a media_ref row. Returns its id.
--- Enforces "media_refs must be owned by a kind='master' sequence" at write time.
function M.create(fields)
    assert(type(fields) == "table", "MediaRef.create: fields table required")
    validate_required(fields)

    local db = database.get_connection()
    local id = fields.id or uuid.generate()
    M.assert_owning_is_master(db, id, fields.owner_sequence_id)
    assert_audio_rate_for_kind(db, fields, id)

    local now = fields.created_at or os.time()
    -- 018 (V11): audio_sample_rate denormalized from media for resolver hot path.
    -- Required when the underlying media has audio (FR-008 needs it for sample math).
    -- NULL only for video-only media_refs.
    if fields.audio_sample_rate ~= nil then
        assert(type(fields.audio_sample_rate) == "number" and fields.audio_sample_rate > 0,
            string.format("MediaRef.create: audio_sample_rate must be positive integer when provided; got %s",
                tostring(fields.audio_sample_rate)))
    end
    local stmt = db:prepare([[
        INSERT INTO media_refs (
            id, project_id, owner_sequence_id, track_id, media_id,
            source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
            audio_sample_rate, source_channel,
            enabled, volume, mark_in_frame, mark_out_frame, playhead_frame,
            created_at, modified_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    assert(stmt, "MediaRef.create: failed to prepare INSERT")
    stmt:bind_value(1, id)
    stmt:bind_value(2, fields.project_id)
    stmt:bind_value(3, fields.owner_sequence_id)
    stmt:bind_value(4, fields.track_id)
    stmt:bind_value(5, fields.media_id)
    stmt:bind_value(6, fields.source_in_frame)
    stmt:bind_value(7, fields.source_out_frame)
    stmt:bind_value(8, fields.sequence_start_frame)
    stmt:bind_value(9, fields.duration_frames)
    stmt:bind_value(10, fields.audio_sample_rate)  -- nullable per V11
    stmt:bind_value(11, fields.source_channel)     -- nullable; required for AUDIO (023)
    stmt:bind_value(12, to_int_bool(fields.enabled))
    stmt:bind_value(13, fields.volume)
    stmt:bind_value(14, fields.mark_in_frame)   -- nullable
    stmt:bind_value(15, fields.mark_out_frame)  -- nullable
    stmt:bind_value(16, fields.playhead_frame)
    stmt:bind_value(17, now)
    stmt:bind_value(18, fields.modified_at or now)

    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, string.format(
        "MediaRef.create: INSERT failed for id=%s (likely trigger: media_refs must be owned by a kind='master' sequence, or FK)",
        id))
    return id
end

--- Load a single row by id. Returns the row table or nil.
function M.find(id)
    local db = database.get_connection()
    local stmt = db:prepare([[
        SELECT id, project_id, owner_sequence_id, track_id, media_id,
               source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
               audio_sample_rate, source_channel,
               enabled, volume, mark_in_frame, mark_out_frame, playhead_frame,
               created_at, modified_at
        FROM media_refs WHERE id = ?
    ]])
    assert(stmt, "MediaRef.find: failed to prepare")
    stmt:bind_value(1, id)
    assert(stmt:exec(), "MediaRef.find: exec failed")
    local row
    if stmt:next() then
        row = {
            id = stmt:value(0),
            project_id = stmt:value(1),
            owner_sequence_id = stmt:value(2),
            track_id = stmt:value(3),
            media_id = stmt:value(4),
            source_in_frame = stmt:value(5),
            source_out_frame = stmt:value(6),
            sequence_start_frame = stmt:value(7),
            duration_frames = stmt:value(8),
            audio_sample_rate = stmt:value(9),
            source_channel = stmt:value(10),
            enabled = stmt:value(11) == 1,
            volume = stmt:value(12),
            mark_in_frame = stmt:value(13),
            mark_out_frame = stmt:value(14),
            playhead_frame = stmt:value(15),
            created_at = stmt:value(16),
            modified_at = stmt:value(17),
        }
    end
    stmt:finalize()
    return row
end

-- Columns updatable after INSERT. Structural columns (project_id,
-- owner_sequence_id, track_id, media_id) are NOT in this set — moving a
-- media_ref between masters/tracks is a higher-level operation, not a bare UPDATE.
local UPDATABLE_COLUMNS = {
    source_in_frame = true, source_out_frame = true,
    sequence_start_frame = true, duration_frames = true,
    enabled = true, volume = true,
    mark_in_frame = true, mark_out_frame = true,
    playhead_frame = true,
}

--- Update a media_ref. `fields` contains only the columns to change.
function M.update(id, fields)
    assert(type(fields) == "table", "MediaRef.update: fields table required")
    local db = database.get_connection()

    local sets, values = {}, {}
    for k, v in pairs(fields) do
        assert(UPDATABLE_COLUMNS[k], string.format(
            "MediaRef.update: column '%s' is not updatable (structural)", k))
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
        "UPDATE media_refs SET %s WHERE id = ?", table.concat(sets, ", ")))
    assert(stmt, "MediaRef.update: prepare failed")
    for i, v in ipairs(values) do stmt:bind_value(i, v) end
    stmt:bind_value(#values + 1, id)
    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, string.format("MediaRef.update: exec failed for id=%s", id))
    return true
end

--- Delete a media_ref by id.
function M.delete(id)
    local db = database.get_connection()
    local stmt = db:prepare("DELETE FROM media_refs WHERE id = ?")
    assert(stmt, "MediaRef.delete: prepare failed")
    stmt:bind_value(1, id)
    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, string.format("MediaRef.delete: exec failed for id=%s", id))
    return true
end

return M
