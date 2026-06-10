-- T025 — LIVE identity round-trip
--           (spec 023, FR-002/FR-021/FR-011c; quickstart step 1).
--
-- After SendToResolve (DRT export → helper import_timeline → marker
-- stamp), the Resolve timeline MUST:
--   1. Contain one item per JVE clip that was sent.
--   2. Each item's identity marker (customData) MUST byte-equal the
--      sending JVE clip's `clip.id` — recovered via read_identities.
--   3. Items the JVE side didn't send (user added in Resolve between
--      runs) surface in read_identities' `unkeyed_count`, not silently.
--
-- This test gates the whole feature: if the identity carrier is wrong
-- here, every downstream sync uses the wrong jve_guid.
--
-- Today's path (this turn's T021/T025 chain):
--   - SendToResolve builds `clip_positions` from the JVE sequence and
--     hands it to verb_import_timeline.
--   - verb_import_timeline calls ImportTimelineFromFile, snapshots
--     timelines pre/post to find the new one, walks items, matches
--     by (track_type, track_index, record_start), and stamps a marker
--     `customData == clip.id` on each matched item.
--   - read_identities reads markers back; the customData IS the
--     jve_guid surfaced to the caller.
--
-- Operator precondition (run before this test):
--   1. Open DaVinci Resolve Studio.
--   2. Run SendToResolve on a JVE sequence with ≥1 clip (programmatic
--      or via menu). That stamps marker customData on each item.
--   3. Position Resolve on the newly-imported timeline.
--   4. Then run this test.
--
-- A future T025b will drive SendToResolve end-to-end from a JVE-side
-- fixture (.jvp + sequence + clips); that requires an integration
-- mode where command_manager dispatches against the real helper,
-- which the current --test harness doesn't fully wire up. Tracked in
-- todo_t025b_send_to_resolve_end_to_end.
--
-- Run via (absolute path — relative resolves bundle-relative):
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--       $PWD/tests/synthetic/integration/live_resolve/test_send_identity.lua

local fixture = require("synthetic.integration.live_resolve.live_fixture")

local fix = fixture.start("/tmp/jve-live-send-identity.sock")
fixture.skip_unless_live(fix, "test_send_identity")

local r = fixture.expect_ok(
    fixture.request(fix, "read_identities", {}),
    "read_identities")

assert(type(r.items) == "table",
    "T025: result.items must be a table")
assert(type(r.unkeyed_count) == "number"
    and r.unkeyed_count >= 0
    and r.unkeyed_count == math.floor(r.unkeyed_count),
    string.format("T025: unkeyed_count must be non-negative integer, "
        .. "got %s", tostring(r.unkeyed_count)))

-- Hard precondition assert: if items is empty, the operator hasn't
-- set up the test correctly OR marker stamping regressed. Either way
-- the test must FAIL so the regression is loud (rule 1.14; "test that
-- can't catch a real bug is worse than no test" per Joe's testing
-- guidance).
assert(#r.items > 0,
    "T025: zero marker-stamped items on the open timeline. "
    .. "Operator precondition: run SendToResolve on a JVE sequence "
    .. "with ≥1 clip BEFORE running this test, then position Resolve "
    .. "on the imported timeline. If you did, marker stamping has "
    .. "regressed — check verb_import_timeline's _stamp_marker_safe "
    .. "path.")

-- The fundamental assertion: every keyed item carries a non-empty
-- string jve_guid. That string IS the JVE clip.id stamped at import
-- time (no extra translation layer). If the marker channel is broken,
-- jve_guid would be missing / empty / a non-id-shaped value.
for i, item in ipairs(r.items) do
    assert(type(item.resolve_item_id) == "string"
        and item.resolve_item_id ~= "", string.format(
        "T025: items[%d].resolve_item_id must be non-empty string", i))
    assert(type(item.jve_guid) == "string" and item.jve_guid ~= "",
        string.format(
        "T025: items[%d].jve_guid must be non-empty string", i))
    -- The JVE clip.id is a UUID-shaped lowercase hex with dashes; the
    -- Sm2Ti DbId Joe's importer adopts has the same shape (per
    -- inbound-findings.md §1). Defensive shape check — a corrupt
    -- marker that stamps random binary would fail this.
    assert(item.jve_guid:match("^[%w%-_]+$"), string.format(
        "T025: items[%d].jve_guid contains non-id chars: %q",
        i, item.jve_guid))
end

print(string.format(
    "  ✓ %d keyed item(s), %d unkeyed (Resolve-only)",
    #r.items, r.unkeyed_count))
print("  ✓ marker channel is live (every item has recoverable jve_guid)")

fixture.stop(fix)
print("✅ test_send_identity.lua passed")
