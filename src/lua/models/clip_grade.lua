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

--- Insert-or-replace a grade for a clip.
--- @param clip_id string                          owning clip's id
--- @param grade   table  {cdl, lut_ref, fidelity, source, stale, synced_at}
--- @param db      table  open SQLite connection
function M.upsert(clip_id, grade, db)
    assert(type(clip_id) == "string" and clip_id ~= "",
        "ClipGrade.upsert: clip_id required")
    assert(db, "ClipGrade.upsert: db connection required")
    assert_valid_grade(grade)

    local cdl = grade.cdl
    local stmt = assert(db:prepare([[
        INSERT OR REPLACE INTO clip_grade (
            clip_id,
            slope_r, slope_g, slope_b,
            offset_r, offset_g, offset_b,
            power_r, power_g, power_b,
            saturation,
            lut_ref, fidelity, source, stale, synced_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]]), "ClipGrade.upsert: prepare failed")
    stmt:bind_value(1, clip_id)
    if cdl then
        stmt:bind_value(2,  cdl.slope_r);  stmt:bind_value(3,  cdl.slope_g);  stmt:bind_value(4,  cdl.slope_b)
        stmt:bind_value(5,  cdl.offset_r); stmt:bind_value(6,  cdl.offset_g); stmt:bind_value(7,  cdl.offset_b)
        stmt:bind_value(8,  cdl.power_r);  stmt:bind_value(9,  cdl.power_g);  stmt:bind_value(10, cdl.power_b)
        stmt:bind_value(11, cdl.saturation)
    else
        for i = 2, 11 do stmt:bind_value(i, nil) end
    end
    stmt:bind_value(12, grade.lut_ref)
    stmt:bind_value(13, grade.fidelity)
    stmt:bind_value(14, grade.source)
    stmt:bind_value(15, grade.stale)
    stmt:bind_value(16, grade.synced_at)
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
function M.load(clip_id, db)
    assert(type(clip_id) == "string" and clip_id ~= "",
        "ClipGrade.load: clip_id required")
    assert(db, "ClipGrade.load: db connection required")
    local stmt = assert(db:prepare([[
        SELECT slope_r, slope_g, slope_b, offset_r, offset_g, offset_b,
               power_r, power_g, power_b, saturation,
               lut_ref, fidelity, source, stale, synced_at
        FROM clip_grade WHERE clip_id = ?
    ]]), "ClipGrade.load: prepare failed")
    stmt:bind_value(1, clip_id)
    if not stmt:exec() or not stmt:next() then
        stmt:finalize(); return nil
    end
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
    local out = {
        cdl       = cdl,
        lut_ref   = stmt:value(10),
        fidelity  = stmt:value(11),
        source    = stmt:value(12),
        stale     = stmt:value(13),
        synced_at = stmt:value(14),
    }
    stmt:finalize()
    return out
end

return M
