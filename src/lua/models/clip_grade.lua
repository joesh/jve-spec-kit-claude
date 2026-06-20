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

local VALID_REPRODUCTIONS = {
    full = true,
    approximate = true,
    not_shown = true,
}

--- Classify what JVE can DISPLAY of a grade (the FR-015 badge axis) — a
--- separate concept from `fidelity` (Resolve grade complexity). A spatial
--- Resolve grade is `unrepresentable` AND bakes to an identity LUT, so the
--- viewer shows passthrough: honest answer is `not_shown`, never silently
--- "graded" (rule 2.32).
---   primary                                  → 'full'
---   non-primary + non-identity LUT carrier   → 'approximate'
---   non-primary + identity LUT or no carrier → 'not_shown'
--- @param fidelity         string  'primary'|'partial'|'unrepresentable'
--- @param lut_ref          string|nil  the baked LUT path, or nil
--- @param lut_is_identity  boolean|nil whether that LUT is a passthrough;
---                         REQUIRED (boolean) when lut_ref is present
--- @return string  'full' | 'approximate' | 'not_shown'
function M.classify_reproduction(fidelity, lut_ref, lut_is_identity)
    assert(VALID_FIDELITIES[fidelity], string.format(
        "ClipGrade.classify_reproduction: fidelity must be one of "
        .. "'primary'|'partial'|'unrepresentable', got %s", tostring(fidelity)))
    if fidelity == "primary" then
        return "full"
    end
    if lut_ref ~= nil then
        assert(type(lut_is_identity) == "boolean", string.format(
            "ClipGrade.classify_reproduction: lut_is_identity (boolean) "
            .. "required when lut_ref is present (got %s) — the caller must "
            .. "classify the baked cube", type(lut_is_identity)))
        return lut_is_identity and "not_shown" or "approximate"
    end
    return "not_shown"
end

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
        "ClipGrade.upsert: CDL must supply all 10 channels "
        .. "(slope/offset/power × R/G/B + saturation) OR all NULL; "
        .. "got %d present (%s) and %d absent (%s). Partial CDL "
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
    assert(VALID_REPRODUCTIONS[grade.reproduction], string.format(
        "ClipGrade.upsert: reproduction must be one of "
        .. "'full'|'approximate'|'not_shown', got %s",
        tostring(grade.reproduction)))
    assert(type(grade.source) == "string" and grade.source ~= "",
        "ClipGrade.upsert: source required (non-empty string)")
    assert(grade.stale == 0 or grade.stale == 1, string.format(
        "ClipGrade.upsert: stale must be 0 or 1, got %s",
        tostring(grade.stale)))
    assert(type(grade.synced_at) == "number" and grade.synced_at >= 0,
        "ClipGrade.upsert: synced_at required (unix timestamp)")
end

-- Schema columns in INSERT order: clip_id, then CDL_CHANNELS, then trailing.
local TRAILING_COLUMNS = { "lut_ref", "fidelity", "reproduction", "source", "stale", "synced_at" }

local function build_upsert_sql()
    local cols = { "clip_id" }
    for _, ch in ipairs(CDL_CHANNELS)     do cols[#cols + 1] = ch end
    for _, ch in ipairs(TRAILING_COLUMNS) do cols[#cols + 1] = ch end
    return string.format(
        "INSERT OR REPLACE INTO clip_grade (%s) VALUES (%s)",
        table.concat(cols, ", "), database.in_placeholders(#cols))
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

--- Copy a grade row from one clip to another (spec 023 FR-012
--- bladed-both-inherit). SplitClip calls this so the right fragment —
--- a brand-new clip id — renders identically to the parent: a blade is
--- a timeline edit and must not change what the viewer sees. Returns
--- true when a grade was copied, false when the source is ungraded
--- (correct domain outcome, not a fallback: ungraded parent ⇒
--- ungraded halves).
--- @param from_clip_id string
--- @param to_clip_id   string
--- @param db           table|nil optional SQLite connection
function M.copy_to(from_clip_id, to_clip_id, db)
    assert(type(from_clip_id) == "string" and from_clip_id ~= "",
        "ClipGrade.copy_to: from_clip_id required")
    assert(type(to_clip_id) == "string" and to_clip_id ~= "",
        "ClipGrade.copy_to: to_clip_id required")
    assert(from_clip_id ~= to_clip_id,
        "ClipGrade.copy_to: from == to (" .. from_clip_id .. ")")
    local grade = M.load(from_clip_id, db)
    if grade == nil then
        return false
    end
    -- A bladed fragment has no prior Resolve sync relationship; inheriting
    -- stale=1 from the parent would mark it for re-sync before it has ever
    -- been synced (wrong domain meaning — stale tracks sync staleness,
    -- not timeline origin).
    grade.stale = 0
    M.upsert(to_clip_id, grade, db)
    return true
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
               lut_ref, fidelity, reproduction, source, stale, synced_at
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
            cdl          = cdl,
            lut_ref      = stmt:value(10),
            fidelity     = stmt:value(11),
            reproduction = stmt:value(12),
            source       = stmt:value(13),
            stale        = stmt:value(14),
            synced_at    = stmt:value(15),
        }
    end)
    
    return rows[1] -- returns nil if no row
end

--- Batch-load just the `reproduction` axis for many clips in one query.
--- Returns a map { [clip_id] = 'full'|'approximate'|'not_shown' } containing
--- ONLY the clips that have a grade row (ungraded clips are absent — the
--- caller treats absence as "no badge", which is correct: no grade ⇒ nothing
--- to flag). Used by per-clip render/find paths (timeline badges, Find
--- filter) that would otherwise issue one SELECT per visible clip. Empty
--- input → empty map (no SQL issued).
--- @param clip_ids string[]  list of clip ids
--- @param db       table|nil optional SQLite connection
--- @return table  { [clip_id]=reproduction }
function M.load_reproduction_batch(clip_ids, db)
    assert(type(clip_ids) == "table",
        "ClipGrade.load_reproduction_batch: clip_ids array required")
    local out = {}
    if #clip_ids == 0 then return out end
    db = db or database.get_connection()
    assert(db, "ClipGrade.load_reproduction_batch: no active database connection")

    local sql = "SELECT clip_id, reproduction FROM clip_grade WHERE clip_id IN ("
        .. database.in_placeholders(#clip_ids) .. ")"
    database.select_rows(db, sql, clip_ids, function(stmt)
        out[stmt:value(0)] = stmt:value(1)
        return true  -- accumulate via closure; row value unused
    end)
    return out
end

return M
