--- Integration test: tab order must be preserved across restore.
--
-- Exercises the real timeline_panel.restore_tab_order() and
-- timeline_panel.get_open_tab_ids() with actual Qt widgets.
--
-- Scenarios:
--   1. Saved tab order [A, B, C] with B active → restore preserves [A, B, C]
--   2. DeleteSequence closes tab and persists updated list
--
-- Run: ./build/bin/jve --test tests/integration/test_tab_order_restore.lua

local ui = require("integration.ui_test_env")

print("=== test_tab_order_restore ===")

-- =========================================================================
-- Set up: 3-sequence project with tabs saved as [A, B, C], B active
-- =========================================================================
local _, info = ui.launch({
    project_name = "Tab Order Restore",
    num_sequences = 3,
    sequence_names = {"Alpha", "Bravo", "Charlie"},
    active_sequence = 2,  -- Bravo is the active tab
})

local database = require("core.database")
local timeline_panel = require("ui.timeline.timeline_panel")
local state = require("ui.timeline.state.timeline_core_state")

local seqs = info.sequences
local project_id = info.project.id

-- Save the tab order we want to restore: [Alpha, Bravo, Charlie]
local desired_order = { seqs[1].id, seqs[2].id, seqs[3].id }
database.set_project_setting(project_id, "open_sequence_ids", desired_order)

-- =========================================================================
-- Test 1: After launch, open tabs for all 3 sequences
-- =========================================================================
print("Test 1: open tabs for all sequences")

-- layout.lua opens the active sequence; open the rest
for _, seq in ipairs(seqs) do
    timeline_panel.open_tab(seq.id)
end
ui.pump(100)

local ids_before = timeline_panel.get_open_tab_ids()
assert(#ids_before == 3,
    string.format("Expected 3 open tabs, got %d", #ids_before))
print("  ok: 3 tabs open")

-- =========================================================================
-- Test 2: restore_tab_order reorders to match saved order
-- =========================================================================
print("Test 2: restore_tab_order reorders to [Alpha, Bravo, Charlie]")

timeline_panel.restore_tab_order(desired_order)
ui.pump(50)

local ids_after = timeline_panel.get_open_tab_ids()
assert(#ids_after == 3, string.format("Expected 3 tabs, got %d", #ids_after))
for i = 1, 3 do
    assert(ids_after[i] == desired_order[i],
        string.format("Tab[%d]: expected %s (%s), got %s",
            i, desired_order[i], seqs[i].name,
            tostring(ids_after[i])))
end
print("  ok: order matches [Alpha, Bravo, Charlie]")

-- =========================================================================
-- Test 3: restore_tab_order asserts on stale ID (no silent cleanup)
-- =========================================================================
print("Test 3: restore_tab_order asserts on stale ID")

local stale_order = { seqs[1].id, "nonexistent_seq_id", seqs[3].id }
local ok, err = pcall(function()
    timeline_panel.restore_tab_order(stale_order)
end)
assert(not ok, "Should have asserted on stale ID")
assert(err:find("no open tab"), "Error should mention 'no open tab', got: " .. tostring(err))
print("  ok: assert fired for stale ID")

-- =========================================================================
-- Test 4: Verify persisted open_sequence_ids matches current tab state
-- =========================================================================
print("Test 4: persisted state matches tab state")

local persisted = database.get_project_setting(project_id, "open_sequence_ids")
local current_tabs = timeline_panel.get_open_tab_ids()
assert(#persisted == #current_tabs,
    string.format("Persisted %d tabs vs %d open", #persisted, #current_tabs))
for i = 1, #current_tabs do
    assert(persisted[i] == current_tabs[i],
        string.format("Persisted[%d] %s != open[%d] %s",
            i, tostring(persisted[i]), i, tostring(current_tabs[i])))
end
print("  ok: DB matches open tabs")

-- =========================================================================
-- Test 5: Active sequence unchanged by restore_tab_order
-- =========================================================================
print("Test 5: active sequence unchanged after restore")

local active_before = state.get_sequence_id and state.get_sequence_id()
-- Restore with a different order (Charlie first)
local reversed = { seqs[3].id, seqs[1].id, seqs[2].id }
timeline_panel.restore_tab_order(reversed)
ui.pump(50)
local active_after = state.get_sequence_id and state.get_sequence_id()
assert(active_before == active_after,
    string.format("Active changed: %s -> %s", tostring(active_before), tostring(active_after)))
print("  ok: active sequence preserved")

print("✅ test_tab_order_restore.lua passed")
