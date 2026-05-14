#!/usr/bin/env luajit

-- 015 / FR-010, FR-010a — Patch drag-drop wiring contract.
--
-- This test describes the NEW (Option C, row-level QDrag/QDropEvent)
-- drag-and-drop dispatch contract. It is a layer-2 test: pure-Lua
-- decision + wiring logic, NO Qt widgets, NO --test mode.
--
-- Architectural invariants:
--   - Drag source emits a self-contained JSON payload carrying the full
--     source-row identity at gesture-start time. The drop target reads
--     that payload — it does NOT re-query "what was the drag source".
--   - Drop targets are row-level: a track HEADER widget OR a position
--     within a timeline STRIP widget (Y → track via view layout cache).
--     The narrow rec_btn rectangle is NOT the hit target.
--   - Decision logic is unchanged from the existing pure resolver
--     (compute_patch_drop_action). The new code only adds:
--       * build_payload(source)  → mime string
--       * parse_payload(string)  → source table  (asserts on malformed)
--       * derive_target_from_strip(view, local_y, sequence_id, ...)
--                                → target table
--   - Cross-type, cross-sequence, self-drop refusals propagate from the
--     existing resolver — this test verifies the wiring DOES NOT swallow
--     or re-classify them.
--
-- This test currently FAILS because build_payload/parse_payload/
-- derive_target_from_strip don't exist yet. Once Option C lands they
-- pass. Pure-resolver tests (test_patch_drop_action.lua) stay green
-- throughout — the resolver is reused, not replaced.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local patch_drag_logic = require("ui.timeline.patch_drag_logic")
local compute          = patch_drag_logic.compute_patch_drop_action

print("=== test_patch_drag_drop_dispatch.lua ===")

-- ============================================================================
-- build_payload / parse_payload — round-trip the drag-source identity
-- ============================================================================

assert(type(patch_drag_logic.build_payload) == "function",
    "patch_drag_logic must expose build_payload (Option C)")
assert(type(patch_drag_logic.parse_payload) == "function",
    "patch_drag_logic must expose parse_payload (Option C)")

-- Build + parse round-trip preserves all source identity fields.
do
    local source = {
        sequence_id          = "seq-uuid-aaa",
        track_type           = "VIDEO",
        source_shape         = 3,
        source_track_index   = 1,
        home_rec_track_index = 1,
        project_id           = "proj-uuid",
    }
    local payload = patch_drag_logic.build_payload(source)
    assert(type(payload) == "string" and #payload > 0,
        "build_payload must return a non-empty string (mime payload)")
    local parsed = patch_drag_logic.parse_payload(payload)
    assert(parsed.sequence_id == source.sequence_id, "sequence_id roundtrip")
    assert(parsed.track_type == source.track_type, "track_type roundtrip")
    assert(parsed.source_shape == source.source_shape, "source_shape roundtrip")
    assert(parsed.source_track_index == source.source_track_index,
        "source_track_index roundtrip")
    assert(parsed.home_rec_track_index == source.home_rec_track_index,
        "home_rec_track_index roundtrip")
    assert(parsed.project_id == source.project_id, "project_id roundtrip")
    print("  ✓ payload round-trip preserves all source fields")
end

-- parse_payload must assert on malformed input (fail-fast, ENGINEERING 1.14).
-- Drop handlers receive payloads from QMimeData — a missing field is a
-- broken invariant, not a recoverable user error.
do
    local ok = pcall(patch_drag_logic.parse_payload, "")
    assert(not ok, "parse_payload must assert on empty payload")
    local ok2 = pcall(patch_drag_logic.parse_payload, "{not-json")
    assert(not ok2, "parse_payload must assert on malformed JSON")
    local ok3 = pcall(patch_drag_logic.parse_payload, '{"sequence_id":"x"}')
    assert(not ok3, "parse_payload must assert on missing required fields")
    print("  ✓ parse_payload fails fast on empty/malformed/incomplete payloads")
end

-- build_payload must assert on missing source fields (fail-fast at gesture
-- start — the bug should surface where the user can correlate it).
do
    local ok = pcall(patch_drag_logic.build_payload, {
        track_type = "VIDEO", source_track_index = 1,
        home_rec_track_index = 1, project_id = "p",
        -- sequence_id intentionally missing
    })
    assert(not ok, "build_payload must assert on missing sequence_id")
    print("  ✓ build_payload fails fast on missing source fields")
end

-- ============================================================================
-- derive_target_from_strip — Y→track lookup at strip drop site
-- ============================================================================
--
-- The strip-widget drop handler receives the local Y coordinate of the
-- drop. It resolves Y → track_id via the view's layout cache, then must
-- produce a target table {sequence_id, track_type, rec_track_index} for
-- compute_patch_drop_action.
--
-- This function is the SEAM between strip-widget event coords and the
-- pure resolver. Test it with a stub view, no Qt required.

assert(type(patch_drag_logic.derive_target_from_strip) == "function",
    "patch_drag_logic must expose derive_target_from_strip (Option C)")

-- Build a stub "view" that maps Y ranges to track_ids the same way the
-- real timeline_view does. The contract is `view:get_track_id_at_y(y, h)`.
-- The widget_height is passed THROUGH the args (not stashed on the view) —
-- derive_target_from_strip is a pure data transform; view is read-only.
local function stub_view(rows)
    return {
        get_track_id_at_y = function(_, y, _h)
            for _, row in ipairs(rows) do
                if y >= row.y and y < row.y + row.height then
                    return row.track_id
                end
            end
            return nil
        end,
    }
end

-- Track-info lookup: pure function the caller injects so this module
-- never reaches into the Track model directly (testable + decoupled).
-- Real callsite uses a closure over Track.load.
local function track_info_lookup(track_index_by_id, type_by_id)
    return function(track_id)
        return {
            track_index = track_index_by_id[track_id],
            track_type  = type_by_id[track_id],
        }
    end
end

do
    -- Three video tracks stacked: V3 (y=0..40), V2 (y=40..80), V1 (y=80..120).
    -- A drop at y=60 lands inside V2's strip row.
    local view = stub_view({
        { y = 0,  height = 40, track_id = "tv3" },
        { y = 40, height = 40, track_id = "tv2" },
        { y = 80, height = 40, track_id = "tv1" },
    })
    local info = track_info_lookup(
        { tv1 = 1, tv2 = 2, tv3 = 3 },
        { tv1 = "VIDEO", tv2 = "VIDEO", tv3 = "VIDEO" })
    local target = patch_drag_logic.derive_target_from_strip({
        view              = view,
        local_y           = 60,
        widget_height     = 120,
        sequence_id       = "seq-rec",
        info_lookup     = info,
    })
    assert(target, "derive_target_from_strip must return a target table for in-row Y")
    assert(target.sequence_id == "seq-rec", "target.sequence_id propagates")
    assert(target.track_type == "VIDEO", "target.track_type from track info")
    assert(target.rec_track_index == 2, "target.rec_track_index from track info")
    print("  ✓ strip Y→target lookup picks correct row")
end

-- Y outside any row → returns nil (caller treats as ignored drop, not assert:
-- the user releasing outside any track is a user-input case, not invariant).
do
    local view = stub_view({
        { y = 0, height = 40, track_id = "tv3" },
    })
    local info = track_info_lookup({ tv3 = 3 }, { tv3 = "VIDEO" })
    local target = patch_drag_logic.derive_target_from_strip({
        view = view, local_y = 150, widget_height = 200,
        sequence_id = "seq-rec", info_lookup = info,
    })
    assert(target == nil, "Y outside all rows must return nil (drop ignored)")
    print("  ✓ Y outside all rows returns nil (caller ignores)")
end

-- ============================================================================
-- End-to-end wiring: payload → parse → derive → compute_patch_drop_action
-- The wiring must NOT mutate or re-classify the resolver's verdict.
-- ============================================================================

do
    -- Source: V1 src_btn on its home row (rec_idx 1). Drag drops on V3's
    -- strip at y=10 (inside V3's row in this layout — V3 stacked at top).
    -- source_shape=3 reflects a hypothetical 3-track source.
    local source = {
        sequence_id          = "seq-rec",
        track_type           = "VIDEO",
        source_shape         = 3,
        source_track_index   = 1,
        home_rec_track_index = 1,
        project_id           = "proj",
    }
    local payload = patch_drag_logic.build_payload(source)
    local parsed  = patch_drag_logic.parse_payload(payload)

    local view = stub_view({
        { y = 0,  height = 40, track_id = "tv3" },
        { y = 40, height = 40, track_id = "tv2" },
        { y = 80, height = 40, track_id = "tv1" },
    })
    local info = track_info_lookup(
        { tv1 = 1, tv2 = 2, tv3 = 3 },
        { tv1 = "VIDEO", tv2 = "VIDEO", tv3 = "VIDEO" })

    local target = patch_drag_logic.derive_target_from_strip({
        view = view, local_y = 10, widget_height = 120,
        sequence_id = "seq-rec", info_lookup = info,
    })
    local result = compute(parsed, target)
    assert(result.params, "end-to-end happy path must produce SetPatch params")
    assert(result.params.source_track_index == 1, "src_idx 1 preserved")
    assert(result.params.record_track_index == 3, "rec_idx 3 from Y-lookup")
    assert(result.params.track_type == "VIDEO", "track_type matches")
    assert(result.params.enabled == true, "drag-redirect enables routing")
    print("  ✓ end-to-end: V1 src_btn → strip drop at V3 produces SetPatch v1→v3")
end

-- Cross-type wiring: video source dropped on audio strip → resolver refusal
-- propagates unchanged (wiring does not silently swallow it).
do
    local source = {
        sequence_id = "seq-rec", track_type = "VIDEO", source_shape = 1,
        source_track_index = 1, home_rec_track_index = 1, project_id = "proj",
    }
    local view = stub_view({
        { y = 0, height = 40, track_id = "ta1" },
    })
    local info = track_info_lookup({ ta1 = 1 }, { ta1 = "AUDIO" })
    local target = patch_drag_logic.derive_target_from_strip({
        view = view, local_y = 10, widget_height = 40,
        sequence_id = "seq-rec", info_lookup = info,
    })
    local parsed = patch_drag_logic.parse_payload(
        patch_drag_logic.build_payload(source))
    local result = compute(parsed, target)
    assert(result.refusal, "cross-type drag must surface refusal")
    assert(result.params == nil, "cross-type must not produce params")
    print("  ✓ end-to-end: cross-type drop surfaces refusal, no SetPatch")
end

-- Self-drop wiring: V1 src_btn dropped on V1's own strip row → refusal.
do
    local source = {
        sequence_id = "seq-rec", track_type = "VIDEO", source_shape = 1,
        source_track_index = 1, home_rec_track_index = 1, project_id = "proj",
    }
    local view = stub_view({
        { y = 0, height = 40, track_id = "tv1" },
    })
    local info = track_info_lookup({ tv1 = 1 }, { tv1 = "VIDEO" })
    local target = patch_drag_logic.derive_target_from_strip({
        view = view, local_y = 20, widget_height = 40,
        sequence_id = "seq-rec", info_lookup = info,
    })
    local parsed = patch_drag_logic.parse_payload(
        patch_drag_logic.build_payload(source))
    local result = compute(parsed, target)
    assert(result.refusal, "self-drop must refuse (no-op)")
    assert(result.refusal:match("self.drop"),
        "self-drop refusal must say so: " .. tostring(result.refusal))
    print("  ✓ end-to-end: self-row strip drop refuses (no-op)")
end

print("✅ test_patch_drag_drop_dispatch.lua passed")
