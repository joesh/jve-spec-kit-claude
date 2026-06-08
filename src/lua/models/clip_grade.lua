--- ClipGrade model — per-clip CDL primaries + LUT ref + fidelity (spec 023).
---
--- Schema reference: `clip_grade` table in `src/lua/schema.sql` (V12). One row
--- per clip; PK is `clip_id` and FK CASCADE to `clips(id)` so deleting a clip
--- drops its grade automatically.
---
--- CDL all-or-none invariant (data-model.md):
---   The nine CDL channels (slope/offset/power × R/G/B) + saturation are
---   either ALL present (primary fidelity) or ALL absent (non-primary).
---   Writing 8-of-9 is a programming bug and asserts at the model boundary.
---
--- Fidelity enum: 'primary' | 'partial' | 'unrepresentable'. Anything else
--- asserts at the model boundary (SQL CHECK constraint enforces too, but
--- failing earlier is more actionable).
---
--- Stale flag (FR-014): when the source Resolve item disappears, the stored
--- grade is kept but `stale=1` so callers can distinguish "current sync"
--- from "last-known good." `stale` has no SQL default — the writer always
--- sets it explicitly (per ENGINEERING 2.13).

local database = require("core.database")

local M = {}

local CDL_CHANNELS = {
    "slope_r", "slope_g", "slope_b",
    "offset_r", "offset_g", "offset_b",
    "power_r", "power_g", "power_b",
    "saturation",
}

local VALID_FIDELITIES = {
    primary = true,
    partial = true,
    unrepresentable = true,
}

local function assert_cdl_all_or_none(cdl)
    if cdl == nil then return end
    assert(type(cdl) == "table",
        "ClipGrade.upsert: cdl must be table or nil, got " .. type(cdl))
    local present, absent = {}, {}
    for _, ch in ipairs(CDL_CHANNELS) do
        if cdl[ch] == nil then
            absent[#absent + 1] = ch
        else
            assert(type(cdl[ch]) == "number", string.format(
                "ClipGrade.upsert: cdl.%s must be number, got %s",
                ch, type(cdl[ch])))
            present[#present + 1] = ch
        end
    end
    assert(#absent == 0 or #present == 0, string.format(
        "ClipGrade.upsert: CDL must be all-9-channels-plus-saturation OR "
        .. "all NULL; got %d present (%s) and %d absent (%s). Partial CDL "
        .. "is a programming bug — either downgrade fidelity to 'partial' "
        .. "with cdl = nil, or supply every channel.",
        #present, table.concat(present, ","),
        #absent, table.concat(absent, ",")))
end

local function assert_valid_grade(grade)
    assert(type(grade) == "table",
        "ClipGrade.upsert: grade table required")
    assert_cdl_all_or_none(grade.cdl)
    assert(VALID_FIDELITIES[grade.fidelity], string.format(
        "ClipGrade.upsert: fidelity must be one of "
        .. "'primary'|'partial'|'unrepresentable', got %s",
        tostring(grade.fidelity)))
    assert(type(grade.source) == "string" and grade.source ~= "",
        "ClipGrade.upsert: source required (non-empty string)")
    assert(grade.stale == 0 or grade.stale == 1, string.format(
        "ClipGrade.upsert: stale must be 0 or 1, got %s",
        tostring(grade.stale)))
    assert(type(grade.synced_at) == "number" and grade.synced_at >= 0,
        "ClipGrade.upsert: synced_at required (unix timestamp)")
end

-- Schema columns in INSERT order: clip_id, then CDL_CHANNELS, then trailing.
local TRAILING_COLUMNS = { "lut_ref", "fidelity", "source", "stale", "synced_at" }

local function build_upsert_sql()
    local cols = { "clip_id" }
    for _, ch in ipairs(CDL_CHANNELS)     do cols[#cols + 1] = ch end
    for _, ch in ipairs(TRAILING_COLUMNS) do cols[#cols + 1] = ch end
    local placeholders = {}
    for i = 1, #cols do placeholders[i] = "?" end
    return string.format(
        "INSERT OR REPLACE INTO clip_grade (%s) VALUES (%s)",
        table.concat(cols, ", "), table.concat(placeholders, ", "))
end

local UPSERT_SQL = build_upsert_sql()

--- Insert-or-replace a grade for a clip.
--- @param clip_id string                          owning clip's id
--- @param grade   table  {cdl, lut_ref, fidelity, source, stale, synced_at}
--- @param db      table|nil  optional SQLite connection
function M.upsert(clip_id, grade, db)
    assert(type(clip_id) == "string" and clip_id ~= "",
        "ClipGrade.upsert: clip_id required")
    db = db or database.get_connection()
    assert(db, "ClipGrade.upsert: no active database connection")
    assert_valid_grade(grade)

    local stmt = assert(db:prepare(UPSERT_SQL), "ClipGrade.upsert: prepare failed")
    stmt:bind_value(1, clip_id)
    local idx = 2
    local cdl = grade.cdl
    for _, ch in ipairs(CDL_CHANNELS) do
        stmt:bind_value(idx, cdl and cdl[ch] or nil)
        idx = idx + 1
    end
    for _, col in ipairs(TRAILING_COLUMNS) do
        stmt:bind_value(idx, grade[col])
        idx = idx + 1
    end
    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, "ClipGrade.upsert: stmt:exec failed for clip " .. clip_id)
end

--- Deterministic fingerprint of a grade. Stable for identical CDL +
--- fidelity, different for any change. Used by the identity ledger
--- (FR-025) to detect Resolve-side grade drift between syncs.
---
--- The fingerprint is a canonical-format string: each CDL channel is
--- rendered with `%.9g` (enough precision to round-trip an IEEE-754
--- double for any value the encoder produces) and joined with `|`.
--- Stable across Lua versions because we don't rely on `pairs` order.
function M.fingerprint(grade)
    assert(type(grade) == "table",
        "ClipGrade.fingerprint: grade table required")
    assert(VALID_FIDELITIES[grade.fidelity], string.format(
        "ClipGrade.fingerprint: fidelity must be one of "
        .. "'primary'|'partial'|'unrepresentable', got %s",
        tostring(grade.fidelity)))
    local parts = { "fidelity=" .. grade.fidelity }
    if grade.cdl then
        assert_cdl_all_or_none(grade.cdl)
        for _, ch in ipairs(CDL_CHANNELS) do
            parts[#parts + 1] = string.format("%s=%.9g", ch, grade.cdl[ch])
        end
    else
        parts[#parts + 1] = "cdl=nil"
    end
    if grade.lut_ref then
        parts[#parts + 1] = "lut=" .. grade.lut_ref
    end
    return table.concat(parts, "|")
end

--- Load a grade by clip_id; returns nil if no row.
--- `db` is optional — model layer owns SQL access (per the SQL-isolation
--- policy in core/database.lua), so views/pull-helpers can call
--- `ClipGrade.load(clip_id)` without threading a connection through.
--- Command callers still pass their dispatch-supplied db.
function M.load(clip_id, db)
    assert(type(clip_id) == "string" and clip_id ~= "",
        "ClipGrade.load: clip_id required")
    db = db or database.get_connection()
    assert(db, "ClipGrade.load: no active database connection")
    
    local sql = [[
        SELECT slope_r, slope_g, slope_b, offset_r, offset_g, offset_b,
               power_r, power_g, power_b, saturation,
               lut_ref, fidelity, source, stale, synced_at
        FROM clip_grade WHERE clip_id = ?
    ]]
    
    local rows = database.select_rows(db, sql, { clip_id }, function(stmt)
        local slope_r = stmt:value(0)
        local cdl
        if slope_r ~= nil then
            cdl = {
                slope_r    = slope_r,
                slope_g    = stmt:value(1),
                slope_b    = stmt:value(2),
                offset_r   = stmt:value(3),
                offset_g   = stmt:value(4),
                offset_b   = stmt:value(5),
                power_r    = stmt:value(6),
                power_g    = stmt:value(7),
                power_b    = stmt:value(8),
                saturation = stmt:value(9),
            }
        end
        return {
            cdl       = cdl,
            lut_ref   = stmt:value(10),
            fidelity  = stmt:value(11),
            source    = stmt:value(12),
            stale     = stmt:value(13),
            synced_at = stmt:value(14),
        }
    end)
    
    return rows[1] -- returns nil if no row
end

return M
