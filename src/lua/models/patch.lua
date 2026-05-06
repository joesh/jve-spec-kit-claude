--- Patch model — per-sequence source-track → record-track routing (Feature 015).
---
--- A patch binds one source-track-index to one record-track-index on a
--- sequence. UNIQUE constraint: one patch per (sequence_id, source_track_index).

local database = require("core.database")
local uuid     = require("uuid")

local Patch = {}
Patch.__index = Patch

local function resolve_db()
    local conn = database.get_connection()
    assert(conn, "Patch: no database connection")
    return conn
end

--- Find a patch by (sequence_id, source_track_index). Returns table or nil.
function Patch.find_by_source(sequence_id, src_idx)
    assert(sequence_id and sequence_id ~= "", "Patch.find_by_source: sequence_id required")
    assert(type(src_idx) == "number", "Patch.find_by_source: source_track_index must be number")

    local conn = resolve_db()
    local stmt = conn:prepare([[
        SELECT id, sequence_id, source_track_index, record_track_index, enabled, color, created_at
        FROM patches
        WHERE sequence_id = ? AND source_track_index = ?
    ]])
    assert(stmt, "Patch.find_by_source: prepare failed for seq="
        .. tostring(sequence_id) .. " src=" .. tostring(src_idx))
    stmt:bind_value(1, sequence_id)
    stmt:bind_value(2, src_idx)
    assert(stmt:exec(), "Patch.find_by_source: exec failed for seq="
        .. tostring(sequence_id) .. " src=" .. tostring(src_idx))

    if not stmt:next() then
        stmt:finalize()
        return nil
    end

    local p = {
        id                 = stmt:value(0),
        sequence_id        = stmt:value(1),
        source_track_index = stmt:value(2),
        record_track_index = stmt:value(3),
        enabled            = stmt:value(4),
        color              = stmt:value(5),
        created_at         = stmt:value(6),
    }
    stmt:finalize()
    return setmetatable(p, Patch)
end

--- Find a patch by (sequence_id, record_track_index) — reverse lookup. Returns table or nil.
function Patch.find_by_record(sequence_id, rec_idx)
    assert(sequence_id and sequence_id ~= "", "Patch.find_by_record: sequence_id required")
    assert(type(rec_idx) == "number", "Patch.find_by_record: record_track_index must be number")

    local conn = resolve_db()
    local stmt = conn:prepare([[
        SELECT id, sequence_id, source_track_index, record_track_index, enabled, color, created_at
        FROM patches
        WHERE sequence_id = ? AND record_track_index = ?
        LIMIT 1
    ]])
    assert(stmt, "Patch.find_by_record: prepare failed for seq=" .. tostring(sequence_id)
        .. " rec=" .. tostring(rec_idx))
    stmt:bind_value(1, sequence_id)
    stmt:bind_value(2, rec_idx)
    assert(stmt:exec(), "Patch.find_by_record: exec failed for seq=" .. tostring(sequence_id)
        .. " rec=" .. tostring(rec_idx))

    if not stmt:next() then stmt:finalize(); return nil end
    local p = setmetatable({
        id                 = stmt:value(0),
        sequence_id        = stmt:value(1),
        source_track_index = stmt:value(2),
        record_track_index = stmt:value(3),
        enabled            = stmt:value(4),
        color              = stmt:value(5),
        created_at         = stmt:value(6),
    }, Patch)
    stmt:finalize()
    return p
end

--- Return all patches for a sequence, ordered by source_track_index.
function Patch.find_by_sequence(sequence_id)
    assert(sequence_id and sequence_id ~= "", "Patch.find_by_sequence: sequence_id required")
    local conn = resolve_db()
    local stmt = conn:prepare([[
        SELECT id, sequence_id, source_track_index, record_track_index, enabled, color, created_at
        FROM patches
        WHERE sequence_id = ?
        ORDER BY source_track_index ASC
    ]])
    assert(stmt, "Patch.find_by_sequence: prepare failed for seq=" .. tostring(sequence_id))
    stmt:bind_value(1, sequence_id)
    assert(stmt:exec(), "Patch.find_by_sequence: exec failed for seq=" .. tostring(sequence_id))
    local results = {}
    while stmt:next() do
        table.insert(results, setmetatable({
            id                 = stmt:value(0),
            sequence_id        = stmt:value(1),
            source_track_index = stmt:value(2),
            record_track_index = stmt:value(3),
            enabled            = stmt:value(4),
            color              = stmt:value(5),
            created_at         = stmt:value(6),
        }, Patch))
    end
    stmt:finalize()
    return results
end

--- Create a new unsaved patch. Call :save() to persist.
function Patch.create(sequence_id, src_idx, rec_idx, opts)
    assert(sequence_id and sequence_id ~= "", "Patch.create: sequence_id required")
    assert(type(src_idx) == "number" and src_idx >= 0,
        "Patch.create: source_track_index must be >= 0")
    assert(type(rec_idx) == "number" and rec_idx >= 0,
        "Patch.create: record_track_index must be >= 0")
    opts = opts or {}
    assert(opts.enabled ~= nil,
        "Patch.create: opts.enabled required; caller must supply explicit enabled state (1=on, 0=off)")
    assert(type(opts.color) == "string" and opts.color ~= "",
        "Patch.create: opts.color required; caller must supply a palette color string")
    local p = {
        id                 = opts.id or uuid.generate(),
        sequence_id        = sequence_id,
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
            (id, sequence_id, source_track_index, record_track_index, enabled, color, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            sequence_id        = excluded.sequence_id,
            source_track_index = excluded.source_track_index,
            record_track_index = excluded.record_track_index,
            enabled            = excluded.enabled,
            color              = excluded.color
    ]])
    assert(stmt, "Patch:save: prepare failed")
    stmt:bind_value(1, self.id)
    stmt:bind_value(2, self.sequence_id)
    stmt:bind_value(3, self.source_track_index)
    stmt:bind_value(4, self.record_track_index)
    stmt:bind_value(5, self.enabled)
    stmt:bind_value(6, self.color)
    assert(self.created_at, "Patch:save: created_at missing on patch id=" .. tostring(self.id))
    stmt:bind_value(7, self.created_at)
    assert(stmt:exec(), string.format(
        "Patch:save: exec failed for seq=%s src=%d",
        tostring(self.sequence_id), self.source_track_index))
    stmt:finalize()
    return true
end

return Patch
