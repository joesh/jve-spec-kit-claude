#!/usr/bin/env luajit
--- TDD: open_sequence_ids DB round-trip — ordered list persistence.
-- Verifies that project_settings can store and retrieve ordered sequence ID
-- lists, which is the persistence layer for timeline tab state.
-- UI-level tab management (open/close/reorder) requires Qt; see integration tests.

require('test_env')

local database = require('core.database')

local TEST_DB = "/tmp/jve/test_tab_persistence.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")
assert(database.init(TEST_DB))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj1', 'Test', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
]], now, now))

local seq_ids = {}
for i = 1, 4 do
    local sid = string.format("seq_%d", i)
    db:exec(string.format([[
        INSERT INTO sequences (
            id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate,
            width, height, view_start_frame, view_duration_frames, playhead_frame,
            selected_clip_ids, selected_edge_infos, selected_gap_infos,
            current_sequence_number, created_at, modified_at
        ) VALUES (
            '%s', 'proj1', 'Seq %d', 'sequence', 24, 1, 48000,
            1920, 1080, 0, 240, 0, '[]', '[]', '[]', 0, %d, %d
        );
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
            enabled, locked, muted, soloed, volume, pan)
        VALUES ('track_v_%d', '%s', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    ]], sid, i, now, now, i, sid))
    seq_ids[i] = sid
end

print("=== test_tab_persistence.lua ===")

-- =========================================================================
-- Test 1: ordered list round-trips with preserved order
-- =========================================================================
print("Test 1: ordered list round-trips")
local saved = { seq_ids[3], seq_ids[1], seq_ids[4], seq_ids[2] }
database.set_project_setting("proj1", "open_sequence_ids", saved)
local loaded = database.get_project_setting("proj1", "open_sequence_ids")
assert(#loaded == 4, string.format("Expected 4, got %d", #loaded))
for i = 1, 4 do
    assert(loaded[i] == saved[i],
        string.format("Order[%d]: expected %s, got %s", i, saved[i], tostring(loaded[i])))
end
print("  ok")

-- =========================================================================
-- Test 2: overwrite with shorter list preserves new order
-- =========================================================================
print("Test 2: overwrite with shorter list")
local shorter = { seq_ids[2], seq_ids[3] }
database.set_project_setting("proj1", "open_sequence_ids", shorter)
loaded = database.get_project_setting("proj1", "open_sequence_ids")
assert(#loaded == 2, string.format("Expected 2, got %d", #loaded))
assert(loaded[1] == seq_ids[2], "First should be seq_2")
assert(loaded[2] == seq_ids[3], "Second should be seq_3")
print("  ok")

-- =========================================================================
-- Test 3: empty list round-trips as empty table
-- =========================================================================
print("Test 3: empty list round-trips")
database.set_project_setting("proj1", "open_sequence_ids", {})
loaded = database.get_project_setting("proj1", "open_sequence_ids")
assert(loaded and type(loaded) == "table" and #loaded == 0, "Empty list must round-trip")
print("  ok")

-- =========================================================================
-- Test 4: single-element list round-trips
-- =========================================================================
print("Test 4: single-element list")
database.set_project_setting("proj1", "open_sequence_ids", { seq_ids[4] })
loaded = database.get_project_setting("proj1", "open_sequence_ids")
assert(#loaded == 1 and loaded[1] == seq_ids[4], "Single element must round-trip")
print("  ok")

-- =========================================================================
-- Test 5: duplicate IDs round-trip (persistence layer doesn't deduplicate)
-- =========================================================================
print("Test 5: duplicate IDs preserved")
local dupes = { seq_ids[1], seq_ids[1], seq_ids[2] }
database.set_project_setting("proj1", "open_sequence_ids", dupes)
loaded = database.get_project_setting("proj1", "open_sequence_ids")
assert(#loaded == 3, string.format("Expected 3, got %d", #loaded))
assert(loaded[1] == seq_ids[1] and loaded[2] == seq_ids[1] and loaded[3] == seq_ids[2],
    "Duplicates must be preserved by persistence layer")
print("  ok")

-- =========================================================================
-- Test 6: get_open_tab_ids / restore_tab_order API surface exists
-- =========================================================================
print("Test 6: timeline_panel API surface")
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}
package.loaded["ui.focus_manager"] = {
    focus_panel = function() end,
    set_focused_panel = function() end,
    get_focused_panel = function() return "timeline" end,
}

local tp_ok, tp = pcall(require, "ui.timeline.timeline_panel")
if tp_ok then
    assert(type(tp.get_open_tab_ids) == "function", "get_open_tab_ids must be a function")
    assert(type(tp.restore_tab_order) == "function", "restore_tab_order must be a function")
    assert(type(tp.open_tab) == "function", "open_tab must be a function")
    print("  ok")
else
    print("  SKIP: timeline_panel requires Qt — " .. tostring(tp))
end

os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

print("✅ test_tab_persistence.lua passed")
