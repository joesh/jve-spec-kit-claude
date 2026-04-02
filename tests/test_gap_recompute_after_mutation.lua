#!/usr/bin/env luajit

-- Regression: gap clips must be recomputed after any mutation that changes
-- clip positions. Without recomputation, gap clips have stale positions
-- after delete, nudge, ripple, etc.

require("test_env")

local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")
local ripple_layout = require("tests.helpers.ripple_layout")
local Clip = require("models.clip")

local TEST_DB = "/tmp/jve/test_gap_recompute_after_mutation.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        order = {"v1_left", "v1_mid", "v1_right"},
        v1_left = { timeline_start = 0, duration = 500, source_in = 100 },
        v1_mid = { id = "clip_v1_mid", timeline_start = 700, duration = 300, source_in = 100 },
        v1_right = { timeline_start = 1200, duration = 500, source_in = 100 },
    }
})
local ts = layout:init_timeline_state()
local tracks = layout.tracks

-- Initial state: gaps at [500,700] and [1000,1200]
local gap1_id = layout:gap_id("v1", 500)
local gap2_id = layout:gap_id("v1", 1000)
local gap1 = ts.get_clip_by_id(gap1_id)
local gap2 = ts.get_clip_by_id(gap2_id)
assert(gap1 and gap1.duration == 200, "Initial gap1 at 500 should have duration 200")
assert(gap2 and gap2.duration == 200, "Initial gap2 at 1000 should have duration 200")

-- ─────────────────────────────────────────────────────────────────────────
-- Test 1: After deleting middle clip, gaps must merge into one
-- Before: [left 0-500] [gap 500-700] [mid 700-1000] [gap 1000-1200] [right 1200-1700]
-- After:  [left 0-500] [gap 500-1200] [right 1200-1700]
-- ─────────────────────────────────────────────────────────────────────────
print("--- Test 1: Gaps recompute after DeleteClip ---")

local delete_result = command_manager.execute("DeleteClip", {
    project_id = layout.project_id,
    sequence_id = layout.sequence_id,
    clip_id = "clip_v1_mid",
})
assert(delete_result.success, "Delete should succeed: " .. tostring(delete_result.error_message))

-- After delete, the two gaps + deleted clip space should merge into one gap [500, 1200]
local merged_gap_id = layout:gap_id("v1", 500)
local merged_gap = ts.get_clip_by_id(merged_gap_id)
assert(merged_gap, "Merged gap clip should exist at position 500 after delete")
assert(merged_gap.duration == 700,
    string.format("Merged gap should be 700 frames (500 to 1200), got %d", merged_gap.duration))

-- Old gap2 at 1000 should no longer exist (merged)
local old_gap2 = ts.get_clip_by_id(gap2_id)
assert(old_gap2 == nil, "Old gap2 at 1000 should be gone after merge")

print("  ✓ Gaps recomputed after delete — two gaps merged into one")

-- ─────────────────────────────────────────────────────────────────────────
-- Test 2: After nudging a clip, gap sizes must update
-- ─────────────────────────────────────────────────────────────────────────
print("--- Test 2: Gaps recompute after Nudge ---")

-- Undo the delete first to restore the original layout
local undo_result = command_manager.undo()
assert(undo_result.success, "Undo should succeed")

-- Verify mid clip is back
local mid_restored = Clip.load_optional("clip_v1_mid")
assert(mid_restored, "Mid clip should be restored after undo")

-- Nudge v1_right to the right by 100 frames
ts.set_selection({ts.get_clip_by_id(layout.clips.v1_right.id)})
local nudge_result = command_manager.execute("Nudge", {
    project_id = layout.project_id,
    sequence_id = layout.sequence_id,
    nudge_amount = 100,
    selected_clip_ids = {layout.clips.v1_right.id},
})
assert(nudge_result.success, "Nudge should succeed")

-- Gap2 was [1000, 1200]. After nudging right clip to 1300, gap2 should be [1000, 1300] = 300 frames
local gap2_after_nudge = ts.get_clip_by_id(layout:gap_id("v1", 1000))
assert(gap2_after_nudge, "Gap2 should still exist after nudge")
assert(gap2_after_nudge.duration == 300,
    string.format("Gap2 should be 300 frames after nudge, got %d", gap2_after_nudge.duration))

print("  ✓ Gaps recomputed after nudge — gap size updated")

layout:cleanup()
print("✅ test_gap_recompute_after_mutation.lua passed")
