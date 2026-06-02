-- T028 — helper read_identities contract
--           (spec 023, contracts/helper-protocol.md §read_identities).
--
-- read_identities reconciles Resolve timeline items back to JVE clip ids
-- after manual edits in Resolve (FR-013). Args: none. Result:
-- `{ items: [{ resolve_item_id, jve_guid }], unkeyed_count }`.
--
-- Per the 2026-05-29 T047 spike (helper-protocol.md §read_identities
-- bidirectional note), the live `resolve_item_id` is
-- `TimelineItem:GetUniqueId()` — a runtime instance handle that does
-- NOT equal the DRP `Sm2Ti DbId` JVE adopted as `clip.id`. So
-- `jve_guid` here is recovered via either (a) a clip marker carrying
-- `clip.id` (id-anchored) or (b) content/position match
-- (name + record-TC + source-TC + media identity, first-connect) —
-- NOT raw id equality.
--
-- Items lacking BOTH channels (marker absent AND content match
-- ambiguous) are omitted from `items` and counted in `unkeyed_count`.
-- Closed-set discipline: structured error envelope on any failure.
--
-- This is the RED test that drives T029. The helper-side implementation
-- must:
--   1. Reject extraneous args at the wire boundary (bad_request — verb
--      contract is `args: none`, so any non-empty args is malformed).
--   2. Return the documented result shape with both `items` and
--      `unkeyed_count` populated honestly (no silent drops).
--   3. Per-item shape: `resolve_item_id` non-empty string;
--      `jve_guid` non-empty string when present in items array.
--   4. `unkeyed_count` is a non-negative integer (zero if every item
--      reconciled).
--
-- Helper read-only contract: read_identities never mutates the
-- Resolve project, so this test can run against a live Studio without
-- modal popups. Until T029 lands the verb is wired to `_unimplemented`
-- (returns `not_implemented`), so every assertion below is RED.
--
-- Run via `jve --test`.

local fixture  = require("binding.helper_fixture")
local protocol = require("core.resolve_bridge.protocol")

local fix = fixture.start("/tmp/jve-contract-read-identities.sock")

local function assert_structured_error(parsed, expected_code, label)
    assert(parsed.ok == false, label .. ": expected ok=false")
    assert(type(parsed.error) == "table", label .. ": missing error table")
    assert(type(parsed.error.code) == "string"
        and parsed.error.code ~= "",
        label .. ": error.code must be non-empty string")
    assert(type(parsed.error.message) == "string"
        and parsed.error.message ~= "",
        label .. ": error.message must be non-empty string (never bare)")
    assert(protocol.is_known_error_code(parsed.error.code), string.format(
        "%s: error code %q is not in the closed set",
        label, parsed.error.code))
    assert(parsed.error.code == expected_code, string.format(
        "%s: expected code %q, got %q (%s)",
        label, expected_code, parsed.error.code, parsed.error.message))
end

-- ─── empty args ⇒ ok with documented shape ──────────────────────────
do
    local r = fixture.request(fix, "read_identities", {})
    assert(r.ok == true, string.format(
        "empty args: expected ok=true, got %s/%s",
        r.error and r.error.code, r.error and r.error.message))
    assert(type(r.result) == "table",
        "empty args: result must be a JSON object")
    assert(type(r.result.items) == "table",
        "result.items must be an array")
    assert(type(r.result.unkeyed_count) == "number"
        and r.result.unkeyed_count >= 0
        and r.result.unkeyed_count == math.floor(r.result.unkeyed_count),
        string.format("result.unkeyed_count must be non-negative "
            .. "integer, got %s (%s)", tostring(r.result.unkeyed_count),
            type(r.result.unkeyed_count)))

    -- Per-item shape: every entry in `items` carries BOTH a non-empty
    -- resolve_item_id AND a non-empty jve_guid. Items lacking a join
    -- key are NOT in this list — they are counted in unkeyed_count.
    for i, item in ipairs(r.result.items) do
        assert(type(item.resolve_item_id) == "string"
            and item.resolve_item_id ~= "", string.format(
            "items[%d].resolve_item_id must be non-empty string", i))
        assert(type(item.jve_guid) == "string"
            and item.jve_guid ~= "", string.format(
            "items[%d].jve_guid must be non-empty string (items lacking "
            .. "a join key belong in unkeyed_count, not items)", i))
    end

    print(string.format(
        "  ✓ read_identities → %d keyed item(s), %d unkeyed",
        #r.result.items, r.result.unkeyed_count))
end

-- ─── bad_request: extraneous args ───────────────────────────────────
-- Contract: `args: none`. Any field is extraneous and must be rejected
-- at the wire boundary rather than silently ignored (rule 2.32).
do
    local r = fixture.request(fix, "read_identities", {
        item_ids = { "stray-id" },
    })
    assert_structured_error(r, "bad_request",
        "extraneous args fields")
end

fixture.stop(fix)

print("✅ test_helper_read_identities.lua passed")
