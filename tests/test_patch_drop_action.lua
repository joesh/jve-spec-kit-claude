#!/usr/bin/env luajit

-- T039 (015) — src-btn drag drop-resolution logic. Pure unit test for the
-- helper that decides what SetPatch a drag-drop should produce.
--
-- Architectural invariants (FR-010, FR-010a, spec §F2):
--   - cross-type drag refused (audio source onto video record, vice versa)
--   - cross-sequence drag refused
--   - self-drop (onto own home row) is a no-op (refusal, but not an error)
--   - happy path produces SetPatch{record_track_index = target.rec_idx,
--                                  source_track_index = source.src_idx,
--                                  track_type = matching}
--   - modifier-drag stacking has IDENTICAL data-layer behavior (UNIQUE on
--     (seq, src_idx) means stacking is just multiple patches with same
--     record_track_index — the helper doesn't need a modifier branch).

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local compute = require("ui.timeline.patch_drag_logic").compute_patch_drop_action
assert(type(compute) == "function",
    "patch_drag_logic must expose compute_patch_drop_action")

print("=== test_patch_drop_action.lua ===")

-- Happy path: A2 (source_track_index=1) dragged onto A4 (rec_track_index=3).
do
    local result = compute(
        { sequence_id = "rec", track_type = "AUDIO",
          source_track_index = 1, home_rec_track_index = 1,
          project_id = "proj" },
        { sequence_id = "rec", track_type = "AUDIO", rec_track_index = 3 })
    assert(result.params, "happy path must return params, got: "
        .. tostring(result.refusal))
    assert(result.params.record_track_index == 3,
        "record_track_index must be target.rec_track_index")
    assert(result.params.source_track_index == 1,
        "source_track_index must be dragged source")
    assert(result.params.track_type == "AUDIO", "track_type must propagate")
    assert(result.params.sequence_id == "rec", "sequence_id must be target's")
    assert(result.params.project_id == "proj", "project_id must propagate")
    assert(result.params.enabled == true,
        "drag-redirect should enable the routing (override the previous "
        .. "destination implies the user wants it on)")
    print("  ✓ plain-drag redirect produces correct SetPatch params")
end

-- Cross-type refused: audio source onto video record.
do
    local result = compute(
        { sequence_id = "rec", track_type = "AUDIO",
          source_track_index = 0, home_rec_track_index = 0,
          project_id = "proj" },
        { sequence_id = "rec", track_type = "VIDEO", rec_track_index = 0 })
    assert(result.refusal, "cross-type must refuse")
    assert(result.refusal:match("cross.type"),
        "refusal must mention cross-type: " .. tostring(result.refusal))
    assert(result.params == nil, "refusal must not also return params")
    print("  ✓ cross-type drag refused")
end

-- Cross-type refused: video source onto audio record.
do
    local result = compute(
        { sequence_id = "rec", track_type = "VIDEO",
          source_track_index = 0, home_rec_track_index = 0,
          project_id = "proj" },
        { sequence_id = "rec", track_type = "AUDIO", rec_track_index = 0 })
    assert(result.refusal, "reverse cross-type must also refuse")
    print("  ✓ video→audio drag refused symmetrically")
end

-- Cross-sequence refused.
do
    local result = compute(
        { sequence_id = "rec_a", track_type = "AUDIO",
          source_track_index = 0, home_rec_track_index = 0,
          project_id = "proj" },
        { sequence_id = "rec_b", track_type = "AUDIO", rec_track_index = 0 })
    assert(result.refusal, "cross-sequence must refuse")
    print("  ✓ cross-sequence drag refused")
end

-- Self-drop: dragging onto own home row is a refusal (no-op).
do
    local result = compute(
        { sequence_id = "rec", track_type = "AUDIO",
          source_track_index = 1, home_rec_track_index = 2,
          project_id = "proj" },
        { sequence_id = "rec", track_type = "AUDIO", rec_track_index = 2 })
    assert(result.refusal, "self-drop must refuse (no-op)")
    print("  ✓ self-drop is a no-op refusal")
end

-- Modifier-drag stacking: same data-layer call as plain drag. Two drags
-- from different sources onto the same target row produce two SetPatch
-- params with same record_track_index, different source_track_index.
do
    local r1 = compute(
        { sequence_id = "rec", track_type = "AUDIO",
          source_track_index = 0, home_rec_track_index = 0,
          project_id = "proj" },
        { sequence_id = "rec", track_type = "AUDIO", rec_track_index = 0 })
    local r2 = compute(
        { sequence_id = "rec", track_type = "AUDIO",
          source_track_index = 1, home_rec_track_index = 1,
          project_id = "proj" },
        { sequence_id = "rec", track_type = "AUDIO", rec_track_index = 0 })
    -- r1 is self-drop (src=0, home=0, target=0) → refusal. Use src=2 home=2 instead.
    local r1b = compute(
        { sequence_id = "rec", track_type = "AUDIO",
          source_track_index = 2, home_rec_track_index = 2,
          project_id = "proj" },
        { sequence_id = "rec", track_type = "AUDIO", rec_track_index = 0 })
    assert(r1b.params and r2.params, "both stacking drops must return params")
    assert(r1b.params.record_track_index == 0
        and r2.params.record_track_index == 0,
        "stacking: both drops produce same record_track_index")
    assert(r1b.params.source_track_index ~= r2.params.source_track_index,
        "stacking: different source_track_index (UNIQUE constraint allows both rows)")
    -- Suppress unused-warning on r1 (kept for documenting the self-drop case)
    local _ = r1
    print("  ✓ modifier-drag stacking: identical data-layer action, 2 patch rows")
end

print("✅ test_patch_drop_action.lua passed")
