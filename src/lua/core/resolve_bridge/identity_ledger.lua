--- Identity ledger — `resolve_bridge_link` read/write (spec 023, T016, FR-011).
---
--- One row per JVE clip mapping `jve_clip_uuid` → `resolve_item_id`. For
--- imported clips (FR-011b) `resolve_item_id == jve_clip_uuid` (the importer
--- adopts the Resolve timeline-item DbId as the clip id). For UUID-minted
--- clips (FR-011c) `resolve_item_id` is matched positionally/by content at
--- connect time.
---
--- This module owns read/write ONLY. Reconcile (blade-fragment recognition
--- by content identity) lands whole in T036 — no stub here, per ENGINEERING
--- 2.17 (no partial implementations).

local M = {}

local function read_row(clip_id, db)
    local stmt = assert(db:prepare([[
        SELECT resolve_item_id, grade_fingerprint, edit_fingerprint
        FROM resolve_bridge_link WHERE jve_clip_uuid = ?
    ]]), "identity_ledger: prepare(load) failed")
    stmt:bind_value(1, clip_id)
    local existing
    if stmt:exec() and stmt:next() then
        existing = {
            resolve_item_id   = stmt:value(0),
            grade_fingerprint = stmt:value(1),
            edit_fingerprint  = stmt:value(2),
        }
    end
    stmt:finalize()
    return existing
end

--- Insert or update the link row for a clip.
---
--- Required: `link.resolve_item_id` (every link points at a Resolve item).
--- Optional: `grade_fingerprint`, `edit_fingerprint` — preserved from the
--- existing row if absent on this call, so fingerprint updates and link
--- updates compose without one stomping the other (FR-025).
---
--- @param clip_id string                JVE clip id (= clips.id)
--- @param link    table {resolve_item_id, [grade_fingerprint],
---                       [edit_fingerprint]}
--- @param db      table  open SQLite connection
function M.upsert(clip_id, link, db)
    assert(type(clip_id) == "string" and clip_id ~= "",
        "identity_ledger.upsert: clip_id required")
    assert(db, "identity_ledger.upsert: db connection required")
    assert(type(link) == "table",
        "identity_ledger.upsert: link table required")
    assert(type(link.resolve_item_id) == "string"
        and link.resolve_item_id ~= "",
        "identity_ledger.upsert: link.resolve_item_id required")

    local existing = read_row(clip_id, db)
    local grade_fp = link.grade_fingerprint
    local edit_fp  = link.edit_fingerprint
    if existing then
        if grade_fp == nil then grade_fp = existing.grade_fingerprint end
        if edit_fp  == nil then edit_fp  = existing.edit_fingerprint  end
    end

    local stmt = assert(db:prepare([[
        INSERT OR REPLACE INTO resolve_bridge_link
            (jve_clip_uuid, resolve_item_id, grade_fingerprint, edit_fingerprint)
        VALUES (?, ?, ?, ?)
    ]]), "identity_ledger.upsert: prepare(upsert) failed")
    stmt:bind_value(1, clip_id)
    stmt:bind_value(2, link.resolve_item_id)
    stmt:bind_value(3, grade_fp)
    stmt:bind_value(4, edit_fp)
    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, "identity_ledger.upsert: exec failed for clip " .. clip_id)
end

--- Load the link row for a clip; returns nil if no row.
function M.load(clip_id, db)
    assert(type(clip_id) == "string" and clip_id ~= "",
        "identity_ledger.load: clip_id required")
    assert(db, "identity_ledger.load: db connection required")
    return read_row(clip_id, db)
end

return M
