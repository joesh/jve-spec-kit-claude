--- Patch model — per-(sequence, source-shape, type, src_idx) → rec_idx routing (Feature 015).
---
--- A patch row binds one (record_sequence, track_type, source_shape,
--- source_track_index) tuple to a record_track_index + enabled flag.
--- `source_shape` is the count of source tracks of `track_type` at the
--- time the routing was established. Different-shape sources have
--- INDEPENDENT remembered maps on the same record sequence.
--- See `specs/015-source-in-timeline/spec.md` F2.
---
--- UNIQUE constraint: (sequence_id, track_type, source_shape, source_track_index).

local database = require("core.database")
local uuid     = require("uuid")

local Patch = {}
Patch.__index = Patch

local function lookup_db()
    local conn = database.get_connection()
    assert(conn, "Patch: no database connection")
    return conn
end

local COLS = "id, sequence_id, track_type, source_shape, source_track_index, "
    .. "record_track_index, enabled, created_at"

local function row_to_patch(stmt)
    return setmetatable({
        id                 = stmt:value(0),
        sequence_id        = stmt:value(1),
        track_type         = stmt:value(2),
        source_shape       = stmt:value(3),
        source_track_index = stmt:value(4),
        record_track_index = stmt:value(5),
        enabled            = stmt:value(6),
        created_at         = stmt:value(7),
    }, Patch)
end

-- Shared validation. Shape is the source's track count of this type; must
-- always be > 0 (a row exists only when a source is actually loaded).
local function assert_key(sequence_id, track_type, source_shape, idx_name, idx_value)
    assert(sequence_id and sequence_id ~= "",
        "Patch: sequence_id required")
    assert(track_type == "VIDEO" or track_type == "AUDIO",
        "Patch: track_type must be VIDEO|AUDIO, got " .. tostring(track_type))
    assert(type(source_shape) == "number" and source_shape > 0,
        "Patch: source_shape must be positive number, got " .. tostring(source_shape))
    assert(type(idx_value) == "number",
        "Patch: " .. idx_name .. " must be number, got " .. type(idx_value))
end

-- Prepare + bind + exec; return the open statement. Caller owns finalize().
-- Centralises the failure messages and conn:last_error() formatting that
-- every find_* helper used to inline.
local function prepare_and_bind(caller, sql, binds)
    local conn = lookup_db()
    local stmt = conn:prepare(sql)
    assert(stmt, caller .. ": prepare failed: "
        .. tostring(conn:last_error() or "unknown"))
    for i, v in ipairs(binds) do stmt:bind_value(i, v) end
    assert(stmt:exec(), caller .. ": exec failed")
    return stmt
end

-- Read at most one row; finalize before returning.
local function fetch_one_patch(stmt)
    if not stmt:next() then stmt:finalize(); return nil end
    local row = row_to_patch(stmt)
    stmt:finalize()
    return row
end

-- Read every row; finalize before returning.
local function fetch_all_patches(stmt)
    local results = {}
    while stmt:next() do table.insert(results, row_to_patch(stmt)) end
    stmt:finalize()
    return results
end

local SELECT_COLS = "SELECT " .. COLS .. " FROM patches "

--- Find a patch by (sequence_id, track_type, source_shape, source_track_index).
function Patch.find_by_source(sequence_id, track_type, source_shape, src_idx)
    assert_key(sequence_id, track_type, source_shape, "source_track_index", src_idx)
    local stmt = prepare_and_bind("Patch.find_by_source",
        SELECT_COLS .. "WHERE sequence_id = ? AND track_type = ? "
        .. "AND source_shape = ? AND source_track_index = ?",
        { sequence_id, track_type, source_shape, src_idx })
    return fetch_one_patch(stmt)
end

--- Find ALL patches at (sequence_id, track_type, source_shape) targeting
--- record_track_index. Reverse lookup for the current shape. Multiple
--- sources may route to one record (FR-010a stacking); ordered by
--- source_track_index.
function Patch.find_all_by_record(sequence_id, track_type, source_shape, rec_idx)
    assert_key(sequence_id, track_type, source_shape, "record_track_index", rec_idx)
    local stmt = prepare_and_bind("Patch.find_all_by_record",
        SELECT_COLS .. "WHERE sequence_id = ? AND track_type = ? "
        .. "AND source_shape = ? AND record_track_index = ? "
        .. "ORDER BY source_track_index ASC",
        { sequence_id, track_type, source_shape, rec_idx })
    return fetch_all_patches(stmt)
end

--- Single-source helper. Asserts at most one row targets (seq,type,shape,rec).
function Patch.find_by_record(sequence_id, track_type, source_shape, rec_idx)
    local results = Patch.find_all_by_record(sequence_id, track_type, source_shape, rec_idx)
    assert(#results <= 1, string.format(
        "Patch.find_by_record: %d patches target seq=%s type=%s shape=%d rec=%d — "
        .. "caller assumed single-source but multiple sources are routed here. "
        .. "Use Patch.find_all_by_record and decide explicitly.",
        #results, tostring(sequence_id), track_type, source_shape, rec_idx))
    return results[1]
end

--- Return all patches for a sequence (across all shapes), ordered by
--- track_type, shape, source_track_index.
function Patch.find_by_sequence(sequence_id)
    assert(sequence_id and sequence_id ~= "",
        "Patch.find_by_sequence: sequence_id required")
    local stmt = prepare_and_bind("Patch.find_by_sequence",
        SELECT_COLS .. "WHERE sequence_id = ? "
        .. "ORDER BY track_type ASC, source_shape ASC, source_track_index ASC",
        { sequence_id })
    return fetch_all_patches(stmt)
end

-- Coerce caller-provided enabled flag (0/1 or false/true) to the canonical
-- INTEGER form stored by SQLite. Reject anything else loudly so we don't
-- silently round-trip a junk value. Centralizing this on the model means
-- callers can keep using whichever form is most readable at the callsite,
-- but reads (find_*) always come back as INTEGER 0/1.
local function normalize_enabled(value)
    if value == 1 or value == true  then return 1 end
    if value == 0 or value == false then return 0 end
    error(string.format(
        "Patch: enabled must be 0/1/true/false; got %s (%s)",
        type(value), tostring(value)))
end

--- Create a new unsaved patch row. Call :save() to persist.
--- All key fields explicit; opts.enabled required.
function Patch.create(sequence_id, track_type, source_shape, src_idx, rec_idx, opts)
    assert_key(sequence_id, track_type, source_shape, "source_track_index", src_idx)
    assert(type(rec_idx) == "number" and rec_idx >= 0,
        "Patch.create: record_track_index must be >= 0, got " .. tostring(rec_idx))
    assert(src_idx >= 0,
        "Patch.create: source_track_index must be >= 0, got " .. tostring(src_idx))
    assert(opts ~= nil, "Patch.create: opts table required (pass {} for defaults)")
    assert(opts.enabled ~= nil,
        "Patch.create: opts.enabled required (1=on, 0=off)")
    local p = {
        id                 = opts.id or uuid.generate(),
        sequence_id        = sequence_id,
        track_type         = track_type,
        source_shape       = source_shape,
        source_track_index = src_idx,
        record_track_index = rec_idx,
        enabled            = normalize_enabled(opts.enabled),
        created_at         = os.time(),
    }
    return setmetatable(p, Patch)
end

--- Ensure identity rows exist for every source track in src_seq_id under
--- the CURRENT shape (count of source tracks of each type). Per-channel
--- idempotent: only creates rows when missing. Existing rows (user-
--- rerouted or disabled) are NEVER touched.
---
--- Called from `effective_source_changed` (UI render path) and from
--- `Insert.execute` / `Overwrite.execute` (API edit path).
function Patch.ensure_identity_for_source(rec_seq_id, src_seq_id)
    assert(type(rec_seq_id) == "string" and rec_seq_id ~= "",
        "Patch.ensure_identity_for_source: rec_seq_id required")
    assert(type(src_seq_id) == "string" and src_seq_id ~= "",
        "Patch.ensure_identity_for_source: src_seq_id required")

    local Track   = require("models.track")
    local Signals = require("core.signals")

    local created_any = false
    local function ensure_for_type(track_type)
        local src_tracks = Track.find_by_sequence(src_seq_id, track_type)
        local shape = #src_tracks
        if shape == 0 then return end  -- source has none of this type
        for _, t in ipairs(src_tracks) do
            if not Patch.find_by_source(rec_seq_id, track_type, shape, t.track_index) then
                local p = Patch.create(rec_seq_id, track_type, shape,
                    t.track_index, t.track_index, { enabled = 1 })
                p:save()
                created_any = true
                Signals.emit("patch_changed",
                    rec_seq_id, track_type, shape, t.track_index, "created")
            end
        end
    end

    ensure_for_type("VIDEO")
    ensure_for_type("AUDIO")
    return created_any
end

--- Render-projection primitive: given a record sequence + effective source
--- sequence, return one entry per source track describing where (and how)
--- that track is currently routed. Used by timeline_panel to render
--- src-btns: iterate this list, draw one btn per entry at entry.record_track_index.
---
--- `src_seq_id == nil` (no source loaded) ⇒ returns empty table. This is
--- the gate that enforces spec §2b-i ("no source ⇒ zero src-btns rendered").
---
--- Entries have shape `{track_type, source_track_index, record_track_index,
--- enabled, source_label}` where source_label is e.g. "V1"/"A3" formatted
--- per `track_type`.
---
--- Pull-based (MVC rule 3.0): no side effects. Caller is responsible for
--- calling ensure_identity_for_source FIRST if it wants seeding.
function Patch.source_routing_for_rec(rec_seq_id, src_seq_id)
    assert(type(rec_seq_id) == "string" and rec_seq_id ~= "",
        "Patch.source_routing_for_rec: rec_seq_id required")
    if src_seq_id == nil then return {} end
    assert(type(src_seq_id) == "string" and src_seq_id ~= "",
        "Patch.source_routing_for_rec: src_seq_id must be string or nil")

    local Track = require("models.track")
    local out = {}

    local function project_for_type(track_type, prefix)
        local src_tracks = Track.find_by_sequence(src_seq_id, track_type)
        local shape = #src_tracks
        if shape == 0 then return end
        for _, t in ipairs(src_tracks) do
            local p = Patch.find_by_source(rec_seq_id, track_type, shape, t.track_index)
            if p then
                table.insert(out, {
                    track_type         = track_type,
                    source_track_index = t.track_index,
                    record_track_index = p.record_track_index,
                    -- Stored value is INTEGER 0/1 (normalized on write). Read as bool
            -- for ergonomic UI/render-side use.
            enabled            = p.enabled == 1,
                    source_label       = prefix .. tostring(t.track_index),
                })
            end
            -- If p is nil the row hasn't been seeded yet. Caller should have
            -- run ensure_identity_for_source first; we don't auto-seed here
            -- to keep this function pure. The missing entry just means no
            -- src-btn is drawn — which is the correct visual signal that
            -- routing is undefined, surfacing the bug at the caller.
        end
    end

    project_for_type("VIDEO", "V")
    project_for_type("AUDIO", "A")
    return out
end

--- Delete every patch row for a record sequence across all shapes.
--- Implements spec §2c "Restore Default Patch". Non-undoable (per F6).
function Patch.restore_defaults_for_sequence(rec_seq_id)
    assert(type(rec_seq_id) == "string" and rec_seq_id ~= "",
        "Patch.restore_defaults_for_sequence: rec_seq_id required")
    local conn = lookup_db()
    local stmt = conn:prepare("DELETE FROM patches WHERE sequence_id = ?")
    assert(stmt, "Patch.restore_defaults_for_sequence: prepare failed")
    stmt:bind_value(1, rec_seq_id)
    assert(stmt:exec(), "Patch.restore_defaults_for_sequence: exec failed")
    stmt:finalize()
    require("core.signals").emit("patches_reset", rec_seq_id)
end

function Patch:save()
    local conn = lookup_db()
    local stmt = conn:prepare([[
        INSERT INTO patches
            (id, sequence_id, track_type, source_shape, source_track_index,
             record_track_index, enabled, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            sequence_id        = excluded.sequence_id,
            track_type         = excluded.track_type,
            source_shape       = excluded.source_shape,
            source_track_index = excluded.source_track_index,
            record_track_index = excluded.record_track_index,
            enabled            = excluded.enabled
    ]])
    assert(stmt, "Patch:save: prepare failed")
    stmt:bind_value(1, self.id)
    stmt:bind_value(2, self.sequence_id)
    assert(self.track_type == "VIDEO" or self.track_type == "AUDIO",
        "Patch:save: track_type must be VIDEO|AUDIO on patch id=" .. tostring(self.id))
    stmt:bind_value(3, self.track_type)
    assert(type(self.source_shape) == "number" and self.source_shape > 0,
        "Patch:save: source_shape must be positive on patch id="
        .. tostring(self.id) .. " got=" .. tostring(self.source_shape))
    stmt:bind_value(4, self.source_shape)
    stmt:bind_value(5, self.source_track_index)
    stmt:bind_value(6, self.record_track_index)
    -- Normalize at the write boundary; SetPatch mutators may set self.enabled
    -- to bool, but the column is INTEGER and all readers should see 0/1.
    self.enabled = normalize_enabled(self.enabled)
    stmt:bind_value(7, self.enabled)
    assert(self.created_at, "Patch:save: created_at missing on patch id=" .. tostring(self.id))
    stmt:bind_value(8, self.created_at)
    assert(stmt:exec(), string.format(
        "Patch:save: exec failed for seq=%s type=%s shape=%d src=%d",
        tostring(self.sequence_id), tostring(self.track_type),
        self.source_shape, self.source_track_index))
    stmt:finalize()
    return true
end

return Patch
