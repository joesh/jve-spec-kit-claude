-- T037 — identity_ledger.reconcile contract (spec 023, FR-012).
--
-- Per data-model.md:
--   For each current JVE clip, decide which Resolve item it links to:
--     1. Direct: clip.id == resolve_item.jve_guid
--     2. Content match: same file_uuid + overlapping source TC range
--     3. Blade inherit: clip is a fragment of a parent JVE clip whose
--        Resolve item is known — fragment inherits the parent's
--        resolve_item_id (both fragments inherit).
--     4. Unmatched: reported, not silently dropped.
--
-- Pure data: reconcile takes lists, returns a result table.
-- No DB writes — caller persists via identity_ledger.upsert.

require("test_env")
local identity_ledger = require("core.resolve_bridge.identity_ledger")

local pass = 0
local fail = 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== identity_ledger.reconcile Tests ===")

-- Common file (same source media); TC range exercises non-trivial values.
local FILE_A = "11111111-1111-4111-8111-111111111111"
local FILE_B = "22222222-2222-4222-8222-222222222222"

-- ─── 1. Direct id match wins ────────────────────────────────────────
do
    local jve = {
        { id = "clip-1", file_uuid = FILE_A, source_in = 100, source_out = 200 },
    }
    local resolve = {
        { resolve_item_id = "rs-A", jve_guid = "clip-1",
          file_uuid = FILE_A, source_in = 100, source_out = 200 },
        { resolve_item_id = "rs-B", jve_guid = "other",
          file_uuid = FILE_A, source_in = 100, source_out = 200 },
    }
    local result = identity_ledger.reconcile(jve, resolve)
    check("direct match yields one mapping",
        #result.mapped == 1 and #result.unmatched == 0)
    check("direct match selects rs-A",
        result.mapped[1].resolve_item_id == "rs-A"
        and result.mapped[1].source == "direct")
end

-- ─── 2. Content match: no jve_guid, same file_uuid, overlapping TC ──
do
    local jve = {
        { id = "clip-2", file_uuid = FILE_A, source_in = 100, source_out = 300 },
    }
    local resolve = {
        { resolve_item_id = "rs-X", jve_guid = "",
          file_uuid = FILE_A, source_in = 150, source_out = 250 },
    }
    local result = identity_ledger.reconcile(jve, resolve)
    check("content match recognised",
        #result.mapped == 1
        and result.mapped[1].resolve_item_id == "rs-X"
        and result.mapped[1].source == "content_match")
end

-- ─── 3. Different file_uuid does NOT content-match ───────────────────
do
    local jve = {
        { id = "clip-3", file_uuid = FILE_A, source_in = 0, source_out = 100 },
    }
    local resolve = {
        { resolve_item_id = "rs-Y", jve_guid = "",
          file_uuid = FILE_B, source_in = 0, source_out = 100 },
    }
    local result = identity_ledger.reconcile(jve, resolve)
    check("different file_uuid → unmatched",
        #result.mapped == 0 and #result.unmatched == 1)
    check("unmatched carries the JVE clip id",
        result.unmatched[1].clip_id == "clip-3")
end

-- ─── 4. Blade inherit: a fragment with no own match inherits parent ──
-- Parent JVE clip clip-P covers source 1000..2000 and has a direct
-- Resolve match. Sibling fragment clip-F covers 1500..1800 (a blade
-- within the parent's range) and has no own jve_guid in Resolve.
-- The fragment should inherit rs-P.
do
    local jve = {
        { id = "clip-P", file_uuid = FILE_A,
          source_in = 1000, source_out = 2000 },
        { id = "clip-F", file_uuid = FILE_A,
          source_in = 1500, source_out = 1800 },
    }
    local resolve = {
        { resolve_item_id = "rs-P", jve_guid = "clip-P",
          file_uuid = FILE_A, source_in = 1000, source_out = 2000 },
    }
    local result = identity_ledger.reconcile(jve, resolve)
    -- both fragments map; parent direct, fragment blade_inherit
    check("blade inherit: 2 mappings",
        #result.mapped == 2 and #result.unmatched == 0)
    local by_clip = {}
    for _, m in ipairs(result.mapped) do by_clip[m.clip_id] = m end
    check("parent clip-P direct → rs-P",
        by_clip["clip-P"]
        and by_clip["clip-P"].resolve_item_id == "rs-P"
        and by_clip["clip-P"].source == "direct")
    check("fragment clip-F inherits parent's rs-P (blade_inherit)",
        by_clip["clip-F"]
        and by_clip["clip-F"].resolve_item_id == "rs-P"
        and by_clip["clip-F"].source == "blade_inherit")
end

-- ─── 5. Blade-inherit only triggers when fragment's range is WITHIN
--      the parent's, not just file-shared on a different range. ──────
do
    local jve = {
        { id = "clip-P2", file_uuid = FILE_A,
          source_in = 1000, source_out = 1500 },
        { id = "clip-far", file_uuid = FILE_A,  -- disjoint range
          source_in = 5000, source_out = 5500 },
    }
    local resolve = {
        { resolve_item_id = "rs-P2", jve_guid = "clip-P2",
          file_uuid = FILE_A, source_in = 1000, source_out = 1500 },
    }
    local result = identity_ledger.reconcile(jve, resolve)
    check("disjoint range does NOT inherit",
        #result.mapped == 1
        and result.mapped[1].clip_id == "clip-P2"
        and #result.unmatched == 1
        and result.unmatched[1].clip_id == "clip-far")
end

-- ─── 6. Direct overrides every other match strategy ─────────────────
-- A clip whose id matches one Resolve item ignores content/blade
-- candidates entirely — direct is the strongest match.
do
    local jve = {
        { id = "clip-Q", file_uuid = FILE_A,
          source_in = 500, source_out = 700 },
    }
    local resolve = {
        -- direct match for clip-Q
        { resolve_item_id = "rs-direct", jve_guid = "clip-Q",
          file_uuid = FILE_A, source_in = 500, source_out = 700 },
        -- competing content match (same file, overlapping range, no
        -- jve_guid) — must NOT win.
        { resolve_item_id = "rs-content", jve_guid = "",
          file_uuid = FILE_A, source_in = 500, source_out = 700 },
    }
    local result = identity_ledger.reconcile(jve, resolve)
    check("direct beats content_match", #result.mapped == 1
        and result.mapped[1].resolve_item_id == "rs-direct"
        and result.mapped[1].source == "direct")
end

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_identity_reconcile.lua: failures present")
print("✅ test_identity_reconcile.lua passed")
