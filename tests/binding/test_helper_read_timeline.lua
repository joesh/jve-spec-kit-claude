-- T051 — helper read_timeline contract
--           (spec 023, contracts/helper-protocol.md §read_timeline).
--
-- read_timeline is read-only (FR-024): manual-pull live edit state.
-- Args: `{ item_ids?: [string] }`; omit ⇒ all items. Result:
-- `{ items: [{ resolve_item_id, track_id, record_start,
-- record_duration, source_in, source_out, enabled }] }`. Video items
-- carry integer TC frames; audio items carry `{frame, subframe}` for
-- each TC field. Locale-rate guard (FR-020) applies.
--
-- This is the RED test that drives T052 — the helper-side
-- implementation that must:
--   1. Validate args at the wire boundary (bad_request for malformed
--      item_ids — wrong outer type or non-string element).
--   2. Honour the "omit ⇒ all" vs "empty list ⇒ zero" distinction.
--   3. Return the documented per-item shape (track_id is the JVE id
--      string, not a Resolve index; each TC field is integer-frame
--      for video items / {frame, subframe} for audio items).
--
-- Helper read-only contract: the helper inspects timeline state and
-- never mutates the Resolve project. The test can run against a live
-- Studio without modal popups (unlike import_timeline). When live
-- Resolve is attached, the helper returns the actual items; the test
-- asserts shape rather than count so it stays driver-independent.
--
-- Until T052 lands, the verb is wired to `_unimplemented` (returns
-- `not_implemented`), so every assertion below is RED. That is the
-- intended TDD state — running this test today MUST fail.
--
-- Run via `jve --test`.

local fixture  = require("binding.helper_fixture")
local protocol = require("core.resolve_bridge.protocol")

local fix = fixture.start("/tmp/jve-contract-read-timeline.sock")

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

local function is_video_tc(v) return type(v) == "number" end
local function is_audio_tc(v)
    return type(v) == "table"
        and type(v.frame) == "number"
        and type(v.subframe) == "number"
end

local function assert_items_shape(items, label)
    assert(type(items) == "table",
        label .. ": result.items must be an array")
    for i, item in ipairs(items) do
        assert(type(item.resolve_item_id) == "string"
            and item.resolve_item_id ~= "", string.format(
            "%s items[%d].resolve_item_id must be non-empty string",
            label, i))
        assert(type(item.track_id) == "string"
            and item.track_id ~= "", string.format(
            "%s items[%d].track_id must be non-empty string "
            .. "(JVE id, not Resolve index)", label, i))
        for _, fld in ipairs({"record_start", "record_duration",
                              "source_in", "source_out"}) do
            assert(is_video_tc(item[fld]) or is_audio_tc(item[fld]),
                string.format("%s items[%d].%s must be integer frame "
                    .. "(video) or {frame, subframe} (audio)",
                    label, i, fld))
        end
        assert(type(item.enabled) == "boolean", string.format(
            "%s items[%d].enabled must be boolean", label, i))
    end
end

-- ─── omit item_ids ⇒ ok with items array of documented shape ────────
do
    local r = fixture.request(fix, "read_timeline", {})
    assert(r.ok == true, string.format(
        "omit item_ids: expected ok=true, got %s/%s",
        r.error and r.error.code, r.error and r.error.message))
    assert(type(r.result) == "table",
        "omit item_ids: result must be a JSON object")
    assert_items_shape(r.result.items, "omit item_ids")
    print(string.format("  ✓ omit item_ids → ok, %d item(s) of valid shape",
        #r.result.items))
end

-- ─── empty item_ids list ⇒ zero items (distinct from omission) ──────
do
    local r = fixture.request(fix, "read_timeline", { item_ids = {} })
    assert(r.ok == true, string.format(
        "empty item_ids: expected ok=true, got %s/%s",
        r.error and r.error.code, r.error and r.error.message))
    assert(type(r.result.items) == "table",
        "empty item_ids: result.items must still be a table")
    assert(#r.result.items == 0, string.format(
        "empty item_ids must return zero items, got %d",
        #r.result.items))
    print("  ✓ empty item_ids → 0 items")
end

-- ─── bad_request: item_ids wrong outer type ─────────────────────────
do
    local r = fixture.request(fix, "read_timeline", {
        item_ids = "not-a-list",
    })
    assert_structured_error(r, "bad_request",
        "item_ids wrong outer type")
    assert(r.error.message:find("item_ids", 1, true),
        "bad_request should name the wrong-typed arg: "
        .. r.error.message)
    print("  ✓ item_ids wrong outer type → bad_request")
end

-- ─── bad_request: item_ids list with non-string element ─────────────
do
    local r = fixture.request(fix, "read_timeline", {
        item_ids = { "valid-id", 42 },
    })
    assert_structured_error(r, "bad_request",
        "item_ids non-string element")
    assert(r.error.message:find("item_ids", 1, true),
        "bad_request should name the wrong-typed arg: "
        .. r.error.message)
    print("  ✓ item_ids non-string element → bad_request")
end

fixture.stop(fix)

print("✅ test_helper_read_timeline.lua passed")
