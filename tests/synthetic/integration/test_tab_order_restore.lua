--- Integration test: the panel's visual tab order mirrors the strip.
--
-- Post-B1 the TimelineTabStrip is the single source of truth for which tabs
-- are open and their order; the panel's open_tabs/tab_order is a view-layer
-- mirror keyed by stable TimelineTab.id. timeline_panel.restore_tabs_from_strip()
-- re-materializes the panel tabs in strip order (source first, FR-001), and
-- the whole strip persists as the timeline_tab_strip blob.
--
-- Scenarios:
--   1. Open tabs for all sequences → strip + panel agree on count
--   2. restore_tabs_from_strip → panel tab order == strip tab order
--   3. Persisted blob reflects the open record tabs
--   4. Restore does not change the active sequence
--
-- Run: ./build/bin/jve --test tests/synthetic/integration/test_tab_order_restore.lua

local ui = require("synthetic.integration.ui_test_env")

print("=== test_tab_order_restore ===")

local _, info = ui.launch({
    project_name = "Tab Order Restore",
    num_sequences = 3,
    sequence_names = {"Alpha", "Bravo", "Charlie"},
    active_sequence = 2,  -- Bravo is the active tab
})

local database       = require("core.database")
local timeline_panel = require("ui.timeline.timeline_panel")
local timeline_state = require("ui.timeline.timeline_state")
local core_state     = require("ui.timeline.state.timeline_core_state")

local seqs = info.sequences
local project_id = info.project.id

-- =========================================================================
-- Test 1: open tabs for all sequences
-- =========================================================================
print("Test 1: open tabs for all sequences")
for _, seq in ipairs(seqs) do
    timeline_panel.open_tab(seq.id)
end
ui.pump(100)

local strip = timeline_state.get_tab_strip()
assert(#strip.tabs == 3,
    string.format("Expected 3 strip tabs, got %d", #strip.tabs))
local ids_before = timeline_panel.get_open_tab_ids()
assert(#ids_before == 3,
    string.format("Expected 3 panel tabs, got %d", #ids_before))
print("  ok: 3 tabs open in both strip and panel")

-- =========================================================================
-- Test 2: restore_tabs_from_strip makes the panel mirror the strip order
-- =========================================================================
print("Test 2: panel tab order mirrors strip order")
timeline_panel.restore_tabs_from_strip()
ui.pump(50)

local ids_after = timeline_panel.get_open_tab_ids()
assert(#ids_after == #strip.tabs,
    string.format("Expected %d tabs, got %d", #strip.tabs, #ids_after))
for i, strip_tab in ipairs(strip.tabs) do
    assert(ids_after[i] == strip_tab.id, string.format(
        "Tab[%d]: panel id %s != strip tab id %s (seq %s)",
        i, tostring(ids_after[i]), tostring(strip_tab.id),
        tostring(strip_tab.sequence_id)))
end
print("  ok: panel order matches strip order")

-- Every record sequence is represented exactly once across the open tabs.
local seen = {}
for _, strip_tab in ipairs(strip.tabs) do
    assert(strip_tab.kind == "record",
        "this fixture opens only record tabs; got kind=" .. tostring(strip_tab.kind))
    assert(strip_tab.sequence_id and not seen[strip_tab.sequence_id],
        "each sequence must appear exactly once in the strip")
    seen[strip_tab.sequence_id] = true
end
for _, seq in ipairs(seqs) do
    assert(seen[seq.id],
        string.format("sequence %s (%s) missing from the strip", seq.id, seq.name))
end
print("  ok: all 3 record sequences present, no duplicates")

-- =========================================================================
-- Test 3: persisted strip blob reflects the open tabs
-- =========================================================================
print("Test 3: persisted blob reflects open tabs")
local blob = database.get_project_setting(project_id, "timeline_tab_strip")
assert(type(blob) == "table" and type(blob.tabs) == "table",
    "timeline_tab_strip blob must persist as a table with a tabs list")
assert(#blob.tabs == #ids_after, string.format(
    "Persisted %d tabs vs %d open", #blob.tabs, #ids_after))
for i, t in ipairs(blob.tabs) do
    assert(t.id == ids_after[i], string.format(
        "blob tab[%d] id %s != open tab id %s",
        i, tostring(t.id), tostring(ids_after[i])))
end
print("  ok: blob matches open tabs")

-- =========================================================================
-- Test 4: active sequence unchanged by the restore
-- =========================================================================
print("Test 4: active sequence unchanged after restore")
local active_before = core_state.get_sequence_id and core_state.get_sequence_id()
timeline_panel.restore_tabs_from_strip()
ui.pump(50)
local active_after = core_state.get_sequence_id and core_state.get_sequence_id()
assert(active_before == active_after,
    string.format("Active changed: %s -> %s",
        tostring(active_before), tostring(active_after)))
print("  ok: active sequence preserved")

print("✅ test_tab_order_restore.lua passed")
