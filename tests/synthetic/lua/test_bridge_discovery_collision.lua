-- Regression tests: identity-channel collision handling in discovery.match
--
-- B7: Two Resolve items with DIFFERENT JVE GUIDs pointing to the SAME
--     resolve_item_id must NOT produce two ledger entries. The second
--     item must land in ambiguous, not marker_matched.
--
-- B6-marker: Two Resolve items with the SAME JVE GUID (customData
--     duplicated by a Resolve copy operation) must NOT crash via assert.
--     They must both land in ambiguous with reason "duplicate_identity_marker".

require("test_env")

local discovery = require("core.resolve_bridge.discovery")

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== discovery.match: identity-channel collision handling ===")

local function clip(id, ti, rec)
    return {
        id              = id,
        name            = "C-" .. id,
        track_id        = "v" .. ti,
        track_type      = "video",
        track_index     = ti,
        sequence_start  = rec,
        duration        = 48,
        source_in       = 0,
        source_out      = 48,
        media_file_path = "/path/" .. id .. ".mov",
    }
end

local function id_item(rid, jve_guid)
    return { resolve_item_id = rid, jve_guid = jve_guid }
end

-- ── B7: Two different GUIDs pointing to the same resolve_item_id ─────
-- GUID_A→r1 matches first. GUID_B→r1 must land in ambiguous because
-- r1 is already claimed by the marker channel (fix: already_claimed
-- updated after each match).
do
    local jve_clips = { clip("guid_a", 1, 0), clip("guid_b", 1, 48) }
    local identities = {
        id_item("r1", "guid_a"),   -- GUID_A claims r1
        id_item("r1", "guid_b"),   -- GUID_B also claims r1 — collision
    }
    local report = discovery.match(jve_clips, identities, {}, nil)

    -- Only one of the two GUIDs may land in marker_matched
    local mm_count = 0
    for _ in pairs(report.marker_matched) do mm_count = mm_count + 1 end
    check("B7: only one marker_matched entry when two GUIDs claim same item",
        mm_count == 1)
    check("B7: colliding GUID lands in ambiguous",
        #report.ambiguous == 1)
    check("B7: r1 never appears twice in marker_matched (invariant)",
        not (report.marker_matched["guid_a"] and
             report.marker_matched["guid_b"]))
end

-- ── B6-marker: Same GUID on two Resolve items (Resolve copy ──────────
-- duplicated customData). Must route both to ambiguous, not crash.
do
    local jve_clips = { clip("guid_x", 1, 0) }
    local identities = {
        id_item("r2", "guid_x"),   -- first occurrence
        id_item("r3", "guid_x"),   -- duplicate customData from Resolve copy
    }
    local ok, err = pcall(function()
        local report = discovery.match(jve_clips, identities, {}, nil)
        check("B6-marker: no crash on duplicate GUID", true)
        -- Both items claim the same JVE clip → ambiguous; marker_matched empty
        local mm_count = 0
        for _ in pairs(report.marker_matched) do mm_count = mm_count + 1 end
        check("B6-marker: duplicate-GUID items land in ambiguous, not marker_matched",
            mm_count == 0 and #report.ambiguous == 2)
    end)
    if not ok then
        fail = fail + 1
        print("FAIL: B6-marker crashed: " .. tostring(err))
    end
end

assert(fail == 0, "test_bridge_discovery_collision.lua: failures present")
print("✅ test_bridge_discovery_collision.lua passed")
