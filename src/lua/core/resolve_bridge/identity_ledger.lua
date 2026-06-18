--- Identity ledger — `resolve_bridge_link` read/write (spec 023, T016, FR-011).
---
--- One row per JVE clip mapping `jve_clip_uuid` → `resolve_item_id`. For
--- imported clips (FR-011b) `resolve_item_id == jve_clip_uuid` (the importer
--- adopts the Resolve timeline-item DbId as the clip id). For UUID-minted
--- clips (FR-011c) `resolve_item_id` is matched positionally/by content by
--- the auto-discovery that runs at the start of every sync
--- (core/resolve_bridge/discovery.lua).
---
--- This module owns read/write of `resolve_bridge_link`. The pure-data
--- match algorithm lives in core/resolve_bridge/discovery.lua (direct-id /
--- marker / content / position channels); callers persist via M.upsert.

local database = require("core.database")

local M = {}

local function read_row(clip_id, db)
    local sql = [[
        SELECT resolve_item_id, grade_fingerprint, edit_fingerprint
        FROM resolve_bridge_link WHERE jve_clip_uuid = ?
    ]]
    local rows = database.select_rows(db, sql, { clip_id }, function(stmt)
        return {
            resolve_item_id   = stmt:value(0),
            grade_fingerprint = stmt:value(1),
            edit_fingerprint  = stmt:value(2),
        }
    end)
    return rows[1]
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
local LINK_KEYS = {
    resolve_item_id   = true,
    grade_fingerprint = true,
    edit_fingerprint  = true,
}

function M.upsert(clip_id, link, db)
    assert(type(clip_id) == "string" and clip_id ~= "",
        "identity_ledger.upsert: clip_id required")
    assert(db, "identity_ledger.upsert: db connection required")
    assert(type(link) == "table",
        "identity_ledger.upsert: link table required")
    for k in pairs(link) do
        assert(LINK_KEYS[k], string.format(
            "identity_ledger.upsert: unknown link key %q (closed set: "
            .. "resolve_item_id, grade_fingerprint, edit_fingerprint)", k))
    end
    assert(type(link.resolve_item_id) == "string"
        and link.resolve_item_id ~= "",
        "identity_ledger.upsert: link.resolve_item_id required")
    -- Fingerprint columns are nil-or-non-empty by contract: "" is a
    -- malformed signal that would force the classifier into bootstrap
    -- forever. Force callers to pass nil when they mean "no fingerprint."
    assert(link.grade_fingerprint == nil
            or (type(link.grade_fingerprint) == "string"
                and link.grade_fingerprint ~= ""),
        "identity_ledger.upsert: grade_fingerprint must be nil or non-empty")
    assert(link.edit_fingerprint == nil
            or (type(link.edit_fingerprint) == "string"
                and link.edit_fingerprint ~= ""),
        "identity_ledger.upsert: edit_fingerprint must be nil or non-empty")

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
    -- Rule 2.32: No silent failure of the driver. assert(stmt:exec())
    -- ensures we don't return success when the write failed.
    assert(stmt:exec(), "identity_ledger.upsert: stmt:exec failed for clip "
        .. tostring(clip_id))
    stmt:finalize()
end

--- Load the link row for a clip; returns nil if no row.
function M.load(clip_id, db)
    assert(type(clip_id) == "string" and clip_id ~= "",
        "identity_ledger.load: clip_id required")
    assert(db, "identity_ledger.load: db connection required")
    return read_row(clip_id, db)
end

--- Reverse-direction lookup: given a Resolve item id, return the JVE
--- clip_id it maps to (or nil if no row). Used by SyncEditsFromResolve
--- to translate read_timeline response rows (keyed on resolve_item_id)
--- back to JVE clip ids (FR-011c — UUID-minted clips where
--- resolve_item_id ≠ jve_clip_uuid).
function M.lookup_clip_id(resolve_item_id, db)
    assert(type(resolve_item_id) == "string" and resolve_item_id ~= "",
        "identity_ledger.lookup_clip_id: resolve_item_id required")
    assert(db, "identity_ledger.lookup_clip_id: db connection required")
    
    local sql = "SELECT jve_clip_uuid FROM resolve_bridge_link WHERE resolve_item_id = ?"
    local rows = database.select_rows(db, sql, { resolve_item_id }, function(stmt)
        return stmt:value(0)
    end)
    
    -- Multi-row defensive assert. One resolve_item_id should map to
    -- at most one clip; multiple ledger rows means reconcile produced
    -- a bad state (blade-inherit fragments should be read-time
    -- decorations, not persisted ledger rows — see data-model.md
    -- §reconcile bladed-inherit).
    if #rows > 1 then
        error(string.format(
            "identity_ledger.lookup_clip_id: multiple clip mappings "
            .. "for resolve_item_id=%s (found %d: e.g. %s and %s)",
            resolve_item_id, #rows, tostring(rows[1]), tostring(rows[2])))
    end
    
    return rows[1]
end

--- Iterate all ledger links for clips in a given JVE sequence.
--- Returns an array of {clip_id, resolve_item_id, grade_fingerprint, edit_fingerprint}.
--- @param sequence_id string
--- @param db          table  open SQLite connection
function M.iter_links_for_sequence(sequence_id, db)
    assert(type(sequence_id) == "string" and sequence_id ~= "",
        "identity_ledger.iter_links_for_sequence: sequence_id required")
    assert(db, "identity_ledger.iter_links_for_sequence: db connection required")
    
    local sql = [[
        SELECT l.jve_clip_uuid, l.resolve_item_id, 
               l.grade_fingerprint, l.edit_fingerprint
        FROM resolve_bridge_link l
        JOIN clips c ON l.jve_clip_uuid = c.id
        JOIN tracks t ON c.track_id = t.id
        WHERE t.sequence_id = ?
    ]]
    
    return database.select_rows(db, sql, { sequence_id }, function(stmt)
        return {
            clip_id           = stmt:value(0),
            resolve_item_id   = stmt:value(1),
            grade_fingerprint = stmt:value(2),
            edit_fingerprint  = stmt:value(3),
        }
    end)
end

-- The source-clip-identity + source-TC-overlap match ("content_match")
-- and bladed-inherit logic that once lived here as a pure-data
-- `M.reconcile` are now LIVE in core/resolve_bridge/discovery.lua: the
-- `match_by_content` channel runs in `discovery.match` between the marker
-- and position channels, keyed on the master's `import_uuid`. reconcile
-- was never wired into a live caller (only its own test), so it was
-- deleted with the wiring (2026-06-17) rather than left as a second,
-- diverging matcher. blade_inherit has no live analog yet — defer until a
-- real Resolve-side split case needs it (design-content-match-wiring.md).

return M
