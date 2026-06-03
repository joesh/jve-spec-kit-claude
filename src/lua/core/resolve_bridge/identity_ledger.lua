--- Identity ledger — `resolve_bridge_link` read/write (spec 023, T016, FR-011).
---
--- One row per JVE clip mapping `jve_clip_uuid` → `resolve_item_id`. For
--- imported clips (FR-011b) `resolve_item_id == jve_clip_uuid` (the importer
--- adopts the Resolve timeline-item DbId as the clip id). For UUID-minted
--- clips (FR-011c) `resolve_item_id` is matched positionally/by content at
--- connect time.
---
--- This module owns read/write of `resolve_bridge_link` AND the pure-data
--- reconcile algorithm (M.reconcile — direct / content_match /
--- blade_inherit, no DB writes; callers persist via M.upsert).

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

--- Reverse-direction lookup: given a Resolve item id, return the JVE
--- clip_id it maps to (or nil if no row). Used by SyncEditsFromResolve
--- to translate read_timeline response rows (keyed on resolve_item_id)
--- back to JVE clip ids (FR-011c — UUID-minted clips where
--- resolve_item_id ≠ jve_clip_uuid).
function M.lookup_clip_id(resolve_item_id, db)
    assert(type(resolve_item_id) == "string" and resolve_item_id ~= "",
        "identity_ledger.lookup_clip_id: resolve_item_id required")
    assert(db, "identity_ledger.lookup_clip_id: db connection required")
    local stmt = assert(db:prepare([[
        SELECT jve_clip_uuid FROM resolve_bridge_link
        WHERE resolve_item_id = ?
    ]]), "identity_ledger.lookup_clip_id: prepare failed")
    stmt:bind_value(1, resolve_item_id)
    local clip_id
    if stmt:exec() and stmt:next() then
        clip_id = stmt:value(0)
        -- Multi-row defensive assert. One resolve_item_id should map to
        -- at most one clip; multiple ledger rows means reconcile produced
        -- a bad state (blade-inherit fragments should be read-time
        -- decorations, not persisted ledger rows — see data-model.md
        -- §reconcile bladed-inherit).
        if stmt:next() then
            local second = stmt:value(0)
            stmt:finalize()
            error(string.format(
                "identity_ledger.lookup_clip_id: multiple clip mappings "
                .. "for resolve_item_id=%s (at least %s and %s)",
                resolve_item_id, tostring(clip_id), tostring(second)))
        end
    end
    stmt:finalize()
    return clip_id
end

--- Reconcile algorithm (spec 023 T036, FR-012, data-model.md §reconcile).
---
--- Pure data: takes the current JVE clip list + the current Resolve item
--- list, returns { mapped, unmatched }. NO DB writes — callers persist
--- via M.upsert.
---
--- Strategy precedence (strongest first):
---   1. `direct` — JVE clip.id == Resolve item.jve_guid. Wins over any
---      other candidate (FR-011).
---   2. `content_match` — same media file_uuid AND overlapping source
---      TC range. Used when JVE-originated clips are roundtripped
---      through Resolve without an id (FR-011c positional fallback).
---   3. `blade_inherit` — the JVE clip is a fragment whose source range
---      sits ENTIRELY WITHIN some other JVE clip's range on the same
---      media (file_uuid), AND that parent clip got a direct match.
---      Both parent + fragment(s) inherit the parent's resolve_item_id
---      (bladed both-inherit, data-model.md).
---   4. unmatched — reported, never silently dropped (FR-007 / FR-011).
---
--- @param jve_clips     array of {id, file_uuid, source_in, source_out}
--- @param resolve_items array of {resolve_item_id, jve_guid, file_uuid,
---                                source_in, source_out}
--- @return table { mapped = [{clip_id, resolve_item_id, source}, ...],
---                 unmatched = [{clip_id}, ...] }
local function ranges_overlap(a_in, a_out, b_in, b_out)
    return a_in < b_out and b_in < a_out
end

local function range_contains(parent_in, parent_out, child_in, child_out)
    return parent_in <= child_in and child_out <= parent_out
end

local function find_direct(jve_clip, by_jve_guid)
    local hit = by_jve_guid[jve_clip.id]
    if hit then return hit end
    return nil
end

local function find_content_match(jve_clip, resolve_items)
    for _, rs in ipairs(resolve_items) do
        if rs.file_uuid == jve_clip.file_uuid
            and (rs.jve_guid == nil or rs.jve_guid == "")
            and ranges_overlap(jve_clip.source_in, jve_clip.source_out,
                rs.source_in, rs.source_out) then
            return rs
        end
    end
    return nil
end

-- Build the file_uuid → directly-matched-candidates index used by
-- find_parent_with_direct. Building once and bucketing collapses the
-- naive O(N²) outer×inner scan into O(N + Σ children_per_file): each
-- unmatched child consults only the candidates that share its file
-- (bladed children always share the parent's source file, so each
-- bucket is typically tiny — one parent spawning a handful of
-- children, not the whole timeline).
local function build_direct_candidates_by_file_uuid(jve_clips,
                                                     direct_by_clip)
    local by_file = {}
    for _, candidate in ipairs(jve_clips) do
        local rid = direct_by_clip[candidate.id]
        if rid then
            local bucket = by_file[candidate.file_uuid]
            if bucket == nil then
                bucket = {}
                by_file[candidate.file_uuid] = bucket
            end
            bucket[#bucket + 1] = {
                id              = candidate.id,
                source_in       = candidate.source_in,
                source_out      = candidate.source_out,
                resolve_item_id = rid,
            }
        end
    end
    return by_file
end

local function find_parent_with_direct(jve_clip,
                                        direct_candidates_by_file_uuid)
    local bucket = direct_candidates_by_file_uuid[jve_clip.file_uuid]
    if bucket == nil then return nil end
    for _, candidate in ipairs(bucket) do
        if candidate.id ~= jve_clip.id
            and range_contains(candidate.source_in, candidate.source_out,
                jve_clip.source_in, jve_clip.source_out) then
            return candidate.resolve_item_id
        end
    end
    return nil
end

function M.reconcile(jve_clips, resolve_items)
    assert(type(jve_clips) == "table",
        "identity_ledger.reconcile: jve_clips array required")
    assert(type(resolve_items) == "table",
        "identity_ledger.reconcile: resolve_items array required")

    -- Pass 1: build the by-jve_guid index and resolve direct matches.
    local by_jve_guid = {}
    for _, rs in ipairs(resolve_items) do
        if type(rs.jve_guid) == "string" and rs.jve_guid ~= "" then
            by_jve_guid[rs.jve_guid] = rs
        end
    end

    local direct_by_clip = {}      -- clip_id → resolve_item_id
    local pending_no_direct = {}   -- jve clips still seeking a match
    local mapped = {}

    for _, jve_clip in ipairs(jve_clips) do
        local hit = find_direct(jve_clip, by_jve_guid)
        if hit then
            direct_by_clip[jve_clip.id] = hit.resolve_item_id
            mapped[#mapped+1] = {
                clip_id         = jve_clip.id,
                resolve_item_id = hit.resolve_item_id,
                source          = "direct",
            }
        else
            pending_no_direct[#pending_no_direct+1] = jve_clip
        end
    end

    -- Pass 2: for unresolved clips try content_match, then blade_inherit.
    -- Pre-build the per-file_uuid bucket of directly-matched candidates
    -- ONCE so blade_inherit lookups cost O(bucket) per child instead of
    -- O(jve_clips) — bladed children always share their parent's
    -- file_uuid, so buckets stay small in realistic timelines.
    local direct_candidates_by_file_uuid =
        build_direct_candidates_by_file_uuid(jve_clips, direct_by_clip)
    local unmatched = {}
    for _, jve_clip in ipairs(pending_no_direct) do
        local content = find_content_match(jve_clip, resolve_items)
        if content then
            mapped[#mapped+1] = {
                clip_id         = jve_clip.id,
                resolve_item_id = content.resolve_item_id,
                source          = "content_match",
            }
        else
            local parent_resolve_id = find_parent_with_direct(
                jve_clip, direct_candidates_by_file_uuid)
            if parent_resolve_id then
                mapped[#mapped+1] = {
                    clip_id         = jve_clip.id,
                    resolve_item_id = parent_resolve_id,
                    source          = "blade_inherit",
                }
            else
                unmatched[#unmatched+1] = { clip_id = jve_clip.id }
            end
        end
    end

    return { mapped = mapped, unmatched = unmatched }
end

return M
