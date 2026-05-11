--- Patch model — per-sequence, per-type source-track → record-track routing (Feature 015).
---
--- A patch binds one source-track-index to one record-track-index on a
--- sequence for a specific track_type (VIDEO or AUDIO).
--- UNIQUE constraint: one patch per (sequence_id, track_type, source_track_index).

local database = require("core.database")
local uuid     = require("uuid")

local Patch = {}
Patch.__index = Patch

local function resolve_db()
    local conn = database.get_connection()
    assert(conn, "Patch: no database connection")
    return conn
end

local COLS = "id, sequence_id, track_type, source_track_index, record_track_index, enabled, color, created_at"

local function row_to_patch(stmt)
    return setmetatable({
        id                 = stmt:value(0),
        sequence_id        = stmt:value(1),
        track_type         = stmt:value(2),
        source_track_index = stmt:value(3),
        record_track_index = stmt:value(4),
        enabled            = stmt:value(5),
        color              = stmt:value(6),
        created_at         = stmt:value(7),
    }, Patch)
end

--- Find a patch by (sequence_id, track_type, source_track_index). Returns table or nil.
function Patch.find_by_source(sequence_id, track_type, src_idx)
    assert(sequence_id and sequence_id ~= "",
        "Patch.find_by_source: sequence_id required")
    assert(track_type == "VIDEO" or track_type == "AUDIO",
        "Patch.find_by_source: track_type must be VIDEO or AUDIO, got: " .. tostring(track_type))
    assert(type(src_idx) == "number",
        "Patch.find_by_source: source_track_index must be number")

    local conn = resolve_db()
    local stmt = conn:prepare(
        "SELECT " .. COLS .. " FROM patches "
        .. "WHERE sequence_id = ? AND track_type = ? AND source_track_index = ?")
    assert(stmt, "Patch.find_by_source: prepare failed for seq="
        .. tostring(sequence_id) .. " type=" .. track_type .. " src=" .. tostring(src_idx))
    stmt:bind_value(1, sequence_id)
    stmt:bind_value(2, track_type)
    stmt:bind_value(3, src_idx)
    assert(stmt:exec(), "Patch.find_by_source: exec failed for seq="
        .. tostring(sequence_id) .. " type=" .. track_type .. " src=" .. tostring(src_idx))

    if not stmt:next() then stmt:finalize(); return nil end
    local p = row_to_patch(stmt)
    stmt:finalize()
    return p
end

--- Find ALL patches targeting (sequence_id, track_type, record_track_index).
--- Reverse lookup. Returns an ordered (by source_track_index) array — possibly
--- empty. Multiple sources MAY route to one record (FR-010a stacking-drag);
--- callers that want to render a single indicator must explicitly decide
--- which source to show or render a stack. There is no UNIQUE constraint
--- on the record side; do not assume cardinality≤1.
function Patch.find_all_by_record(sequence_id, track_type, rec_idx)
    assert(sequence_id and sequence_id ~= "",
        "Patch.find_all_by_record: sequence_id required")
    assert(track_type == "VIDEO" or track_type == "AUDIO",
        "Patch.find_all_by_record: track_type must be VIDEO or AUDIO, got: " .. tostring(track_type))
    assert(type(rec_idx) == "number",
        "Patch.find_all_by_record: record_track_index must be number")

    local conn = resolve_db()
    local stmt = conn:prepare(
        "SELECT " .. COLS .. " FROM patches "
        .. "WHERE sequence_id = ? AND track_type = ? AND record_track_index = ? "
        .. "ORDER BY source_track_index ASC")
    assert(stmt, "Patch.find_all_by_record: prepare failed for seq=" .. tostring(sequence_id)
        .. " type=" .. track_type .. " rec=" .. tostring(rec_idx))
    stmt:bind_value(1, sequence_id)
    stmt:bind_value(2, track_type)
    stmt:bind_value(3, rec_idx)
    assert(stmt:exec(), "Patch.find_all_by_record: exec failed for seq=" .. tostring(sequence_id)
        .. " type=" .. track_type .. " rec=" .. tostring(rec_idx))

    local results = {}
    while stmt:next() do
        table.insert(results, row_to_patch(stmt))
    end
    stmt:finalize()
    return results
end

--- Find the single patch targeting (sequence_id, track_type, record_track_index).
--- Asserts that at most one patch exists for this record cell — use this when
--- the caller's UI/logic cannot represent multi-source stacking. Returns the
--- patch or nil. Once FR-010a stacking-drag is implemented end-to-end, callers
--- should migrate to find_all_by_record. The assert is the loud-failure path
--- replacing the previous silent LIMIT 1.
function Patch.find_by_record(sequence_id, track_type, rec_idx)
    local results = Patch.find_all_by_record(sequence_id, track_type, rec_idx)
    assert(#results <= 1, string.format(
        "Patch.find_by_record: %d patches target seq=%s type=%s rec=%d — "
        .. "caller assumed single-source but multiple sources are routed here. "
        .. "Use Patch.find_all_by_record and decide explicitly.",
        #results, tostring(sequence_id), track_type, rec_idx))
    return results[1]
end

--- Return all patches for a sequence, ordered by track_type then source_track_index.
function Patch.find_by_sequence(sequence_id)
    assert(sequence_id and sequence_id ~= "",
        "Patch.find_by_sequence: sequence_id required")
    local conn = resolve_db()
    local stmt = conn:prepare(
        "SELECT " .. COLS .. " FROM patches "
        .. "WHERE sequence_id = ? "
        .. "ORDER BY track_type ASC, source_track_index ASC")
    assert(stmt, "Patch.find_by_sequence: prepare failed for seq=" .. tostring(sequence_id))
    stmt:bind_value(1, sequence_id)
    assert(stmt:exec(), "Patch.find_by_sequence: exec failed for seq=" .. tostring(sequence_id))
    local results = {}
    while stmt:next() do
        table.insert(results, row_to_patch(stmt))
    end
    stmt:finalize()
    return results
end

--- Create a new unsaved patch. Call :save() to persist.
function Patch.create(sequence_id, track_type, src_idx, rec_idx, opts)
    assert(sequence_id and sequence_id ~= "", "Patch.create: sequence_id required")
    assert(track_type == "VIDEO" or track_type == "AUDIO",
        "Patch.create: track_type must be VIDEO or AUDIO, got: " .. tostring(track_type))
    assert(type(src_idx) == "number" and src_idx >= 0,
        "Patch.create: source_track_index must be >= 0")
    assert(type(rec_idx) == "number" and rec_idx >= 0,
        "Patch.create: record_track_index must be >= 0")
    assert(opts ~= nil, "Patch.create: opts table required (pass {} to use defaults)")
    assert(opts.enabled ~= nil,
        "Patch.create: opts.enabled required; caller must supply explicit enabled state (1=on, 0=off)")
    assert(type(opts.color) == "string" and opts.color ~= "",
        "Patch.create: opts.color required; caller must supply a palette color string")
    local p = {
        id                 = opts.id or uuid.generate(),
        sequence_id        = sequence_id,
        track_type         = track_type,
        source_track_index = src_idx,
        record_track_index = rec_idx,
        enabled            = opts.enabled,
        color              = opts.color,
        created_at         = os.time(),
    }
    return setmetatable(p, Patch)
end

function Patch:save()
    local conn = resolve_db()
    local stmt = conn:prepare([[
        INSERT INTO patches
            (id, sequence_id, track_type, source_track_index, record_track_index, enabled, color, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            sequence_id        = excluded.sequence_id,
            track_type         = excluded.track_type,
            source_track_index = excluded.source_track_index,
            record_track_index = excluded.record_track_index,
            enabled            = excluded.enabled,
            color              = excluded.color
    ]])
    assert(stmt, "Patch:save: prepare failed")
    stmt:bind_value(1, self.id)
    stmt:bind_value(2, self.sequence_id)
    assert(self.track_type == "VIDEO" or self.track_type == "AUDIO",
        "Patch:save: track_type must be VIDEO or AUDIO on patch id=" .. tostring(self.id))
    stmt:bind_value(3, self.track_type)
    stmt:bind_value(4, self.source_track_index)
    stmt:bind_value(5, self.record_track_index)
    stmt:bind_value(6, self.enabled)
    stmt:bind_value(7, self.color)
    assert(self.created_at, "Patch:save: created_at missing on patch id=" .. tostring(self.id))
    stmt:bind_value(8, self.created_at)
    assert(stmt:exec(), string.format(
        "Patch:save: exec failed for seq=%s type=%s src=%d",
        tostring(self.sequence_id), tostring(self.track_type), self.source_track_index))
    stmt:finalize()
    return true
end

return Patch
