-- T051 — helper read_timeline contract
--           (spec 023, contracts/helper-protocol.md §read_timeline).
--
-- read_timeline is read-only (FR-024): manual-pull live edit state.
-- Args: `{ item_ids?: [string] }`; omit ⇒ all items. Result:
-- `{ items: [{ resolve_item_id, track_type, track_index,
-- record_start, record_duration, source_in, source_out, enabled }] }`.
-- Track identity is positional (`track_type` ∈ {"video","audio"} +
-- 1-based `track_index`) — Resolve preserves DRT track order through
-- import, so JVE-side callers translate via
-- `Track.find_by_sequence(seq_id, track_type)[track_index]`. The
-- helper has no JVE state and deliberately doesn't invent JVE ids.
-- Video items carry integer TC frames; audio items carry
-- `{frame, subframe}` for each TC field. Locale-rate guard (FR-020)
-- applies.
--
-- This is the RED test that drives T052 — the helper-side
-- implementation that must:
--   1. Validate args at the wire boundary (bad_request for malformed
--      item_ids — wrong outer type or non-string element).
--   2. Honour the "omit ⇒ all" vs "empty list ⇒ zero" distinction.
--   3. Return the documented per-item shape: closed-set track_type,
--      1-based integer track_index, each TC field integer-frame for
--      video items / {frame, subframe} for audio items.
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

local fix = fixture.start("/tmp/jve-contract-read-timeline.sock")

local function is_video_tc(v) return type(v) == "number" end
local function is_audio_tc(v)
    return type(v) == "table"
        and type(v.frame) == "number"
        and type(v.subframe) == "number"
end

local TRACK_TYPES = { video = true, audio = true }

local function assert_items_shape(items, label)
    assert(type(items) == "table",
        label .. ": result.items must be an array")
    for i, item in ipairs(items) do
        assert(type(item.resolve_item_id) == "string"
            and item.resolve_item_id ~= "", string.format(
            "%s items[%d].resolve_item_id must be non-empty string",
            label, i))
        -- Per contract: track identity is positional (track_type +
        -- 1-based track_index), not a carried id. JVE-side translates
        -- via Track.find_by_sequence; helper does not invent JVE ids.
        assert(type(item.track_type) == "string"
            and TRACK_TYPES[item.track_type], string.format(
            "%s items[%d].track_type %q not in closed set {video, audio}",
            label, i, tostring(item.track_type)))
        assert(type(item.track_index) == "number"
            and item.track_index >= 1
            and item.track_index == math.floor(item.track_index),
            string.format("%s items[%d].track_index must be 1-based "
                .. "integer, got %s",
                label, i, tostring(item.track_index)))
        -- record-side fields are present on every item (every Resolve
        -- TimelineItem has a record-side position, even generators).
        for _, fld in ipairs({"record_start", "record_duration"}) do
            assert(is_video_tc(item[fld]) or is_audio_tc(item[fld]),
                string.format("%s items[%d].%s must be integer frame "
                    .. "(video) or {frame, subframe} (audio)",
                    label, i, fld))
        end
        assert(type(item.enabled) == "boolean", string.format(
            "%s items[%d].enabled must be boolean", label, i))
        -- kind discriminator: source_in/source_out present iff
        -- kind=="media" (helper-protocol.md §read_timeline). Non-media
        -- items (generators, transitions, adjustment clips, some
        -- Fusion comps) carry no indexable source range.
        assert(item.kind == "media" or item.kind == "non_media",
            string.format("%s items[%d].kind must be \"media\" or "
                .. "\"non_media\", got %q",
                label, i, tostring(item.kind)))
        if item.kind == "media" then
            for _, fld in ipairs({"source_in", "source_out"}) do
                assert(is_video_tc(item[fld]) or is_audio_tc(item[fld]),
                    string.format("%s items[%d].%s must be integer "
                        .. "frame (video) or {frame, subframe} (audio) "
                        .. "for kind=media", label, i, fld))
            end
            for _, fld in ipairs({"name", "media_file_path"}) do
                assert(type(item[fld]) == "string",
                    string.format("%s items[%d].%s must be string "
                        .. "for kind=media", label, i, fld))
            end
        else
            assert(item.source_in == nil and item.source_out == nil,
                string.format("%s items[%d] kind=non_media must NOT "
                    .. "carry source_in/source_out", label, i))
        end
    end
end

-- ─── bad_request: item_ids wrong outer type ─────────────────────────
-- Wire-discipline paths (don't need a live Resolve handle).
do
    local r = fixture.request(fix, "read_timeline", {
        item_ids = "not-a-list",
    })
    fixture.assert_structured_error(r, "bad_request",
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
    fixture.assert_structured_error(r, "bad_request",
        "item_ids non-string element")
    assert(r.error.message:find("item_ids", 1, true),
        "bad_request should name the wrong-typed arg: "
        .. r.error.message)
    print("  ✓ item_ids non-string element → bad_request")
end

-- Live-Resolve section gate.
fixture.skip_unless_resolve(fix, "test_helper_read_timeline.lua")

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

fixture.stop(fix)

print("✅ test_helper_read_timeline.lua passed")
