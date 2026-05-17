#!/usr/bin/env luajit

-- Black-box tests for list_history_entries: grouping, arrow placement, ordinal numbering.
-- Tests execute real commands and verify the history list output.

require("test_env")

_G.qt_create_single_shot_timer = function() end

package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}
package.loaded["ui.project_browser"] = false

local database = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")
local focus_manager = require("ui.focus_manager")

local SCHEMA_SQL = require("import_schema")

local function setup_db(path)
    os.remove(path)
    os.remove(path .. "-wal")
    os.remove(path .. "-shm")
    assert(database.init(path))
    local conn = database.get_connection()
    assert(conn:exec(SCHEMA_SQL))
    local now = os.time()
    assert(conn:exec(string.format([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('proj', 'Test', 'resample', %d, %d);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate,
            width, height, playhead_frame,
            view_start_frame, view_duration_frames,
            created_at, modified_at)
        VALUES ('seq', 'proj', 'Timeline', 'sequence',
            24, 1, 48000, 1920, 1080, 0, 0, 10000, %d, %d);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1);
    ]], now, now, now, now)))
    command_manager.init('seq', 'proj')
    timeline_state.set_playhead_position(0)
    timeline_state.set_selection({})
    focus_manager.set_focused_panel("timeline")
    return conn
end

local test_env = require("test_env")

local function insert_clip(conn, id, start_frames, dur_frames, track_id)
    track_id = track_id or "v1"
    local media_id = id .. "_media"
    test_env.create_test_media({
        id = media_id,
        project_id = "proj",
        name = media_id .. ".mov",
        file_path = "/tmp/jve/" .. media_id .. ".mov",
        duration_frames = dur_frames,
        fps_numerator = 24,
        fps_denominator = 1,
        width = 1920,
        height = 1080,
        codec = "prores",
    })
    local now = os.time()
    -- V13: clip references a kind='master' sequence wrapping the media.
    local master_id = test_env.create_test_masterclip_sequence(
        "proj", media_id, 24, 1, dur_frames, media_id)
    assert(conn:exec(string.format([[
        INSERT INTO clips (id, project_id, name, track_id,
            owner_sequence_id, sequence_id, sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('%s', 'proj', '%s', '%s', 'seq', '%s',
            %d, %d, 0, %d, NULL, NULL, 'resample', 1, 1.0, 0, %d, %d)
    ]], id, id, track_id, master_id, start_frames, dur_frames, dur_frames, now, now)))
end

----------------------------------------------------------------------
-- Test 1: Empty history returns no entries
----------------------------------------------------------------------
local DB1 = "/tmp/jve/test_edit_history_1.db"
setup_db(DB1)

local entries, visible_current  -- reused across tests
entries = command_manager:list_history_entries()
assert(type(entries) == "table", "entries should be a table")
assert(#entries == 0, string.format("empty history should have 0 entries (got %d)", #entries))

print("✅ empty history returns no entries")

----------------------------------------------------------------------
-- Test 2: Single command shows one entry, arrow on it
----------------------------------------------------------------------
local DB2 = "/tmp/jve/test_edit_history_2.db"
local conn2 = setup_db(DB2)
insert_clip(conn2, "c1", 0, 100)
timeline_state.reload_clips("seq")

-- Execute a single undoable command
local c1 = timeline_state.get_clip_by_id("c1")
assert(c1, "c1 should exist")
timeline_state.set_selection({c1})
local result = command_manager.execute("DeleteSelection", {
    project_id = "proj", sequence_id = "seq",
})
assert(result.success, "delete should succeed")

entries, visible_current = command_manager:list_history_entries()
assert(#entries == 1, string.format("one command should produce 1 entry (got %d)", #entries))
assert(visible_current == entries[1].sequence_number,
    string.format("arrow should be on the command (visible_current=%s, entry seq=%s)",
        tostring(visible_current), tostring(entries[1].sequence_number)))

print("✅ single command shows one entry with arrow")

----------------------------------------------------------------------
-- Test 3: Grouped commands collapse into one entry
----------------------------------------------------------------------
local DB3 = "/tmp/jve/test_edit_history_3.db"
local conn3 = setup_db(DB3)
-- 3 clips on 3 tracks, all containing frame 50
conn3:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('v2', 'seq', 'V2', 'VIDEO', 2, 1),
           ('v3', 'seq', 'V3', 'VIDEO', 3, 1);
]])
insert_clip(conn3, "s1", 0, 100, "v1")
insert_clip(conn3, "s2", 0, 100, "v2")
insert_clip(conn3, "s3", 0, 100, "v3")

timeline_state.reload_clips("seq")

-- Blade splits all 3 at frame 50 (one per track, grouped)
timeline_state.set_playhead_position(50)
timeline_state.set_selection({})
result = command_manager.execute("Blade", {
    project_id = "proj", sequence_id = "seq",
    blade_frame = 50,
    track_ids = { "v1", "v2", "v3" },
})
assert(result.success, "blade should succeed")

entries, visible_current = command_manager:list_history_entries()
assert(#entries == 1,
    string.format("3 grouped SplitClips should collapse to 1 entry (got %d)", #entries))
-- 013: V13 Blade is a single command (not a group of 3 SplitClips); label
-- reflects the command type. Per-clip-count breakdown isn't surfaced.
assert(entries[1].label:find("Blade") or entries[1].label:find("Split"),
    string.format("group label should mention Blade or Split (got '%s')", entries[1].label))
assert(visible_current == entries[1].sequence_number,
    "arrow should be on the group representative")

print("✅ grouped commands collapse into one entry with count")

----------------------------------------------------------------------
-- Test 4: Undo moves arrow back, redo entry appears
----------------------------------------------------------------------
local undo_result = command_manager.undo()
assert(undo_result.success, "undo should succeed")

entries, visible_current = command_manager:list_history_entries()
-- After undo, the group is in the redo zone — 0 entries in the done zone
-- but the group should still appear as a redo entry
assert(#entries >= 1, "undo should still show the group as redo-able")

-- The arrow should be BEFORE the group (either 0 or nothing)
-- visible_current should not match the group entry
local group_entry = nil
for _, e in ipairs(entries) do
    if e.label and (e.label and (e.label:find("Blade") or e.label:find("Split"))) then
        group_entry = e
    end
end
assert(group_entry, "group entry should be in redo zone")
assert(visible_current ~= group_entry.sequence_number,
    "arrow should not be on the undone group")

print("✅ undo moves arrow off the group, group remains as redo")

----------------------------------------------------------------------
-- Test 5: Redo restores arrow to group
----------------------------------------------------------------------
local redo_result = command_manager.redo()
assert(redo_result.success, "redo should succeed")

entries, visible_current = command_manager:list_history_entries()
group_entry = nil
for _, e in ipairs(entries) do
    if e.label and (e.label and (e.label:find("Blade") or e.label:find("Split"))) then
        group_entry = e
    end
end
assert(group_entry, "group should be in done zone after redo")
assert(visible_current == group_entry.sequence_number,
    "arrow should be on the group after redo")

print("✅ redo restores arrow to group")

----------------------------------------------------------------------
-- Test 6: Multiple groups show correct count
----------------------------------------------------------------------
-- Split again at frame 75 (3 more splits)
timeline_state.set_playhead_position(75)
local _ = command_manager.execute("Blade", { -- luacheck: ignore 211
    project_id = "proj", sequence_id = "seq",
    blade_frame = 75,
    track_ids = { "v1", "v2", "v3" },
})
-- Some clips may not intersect at 75 (already split at 50), but at least some should
entries, visible_current = command_manager:list_history_entries()
assert(#entries >= 2,
    string.format("second blade should add another group (got %d entries)", #entries))

-- Arrow should be on the last entry
local last_entry = entries[#entries]
assert(visible_current == last_entry.sequence_number,
    "arrow should be on the latest group")

print("✅ multiple groups display correctly")

----------------------------------------------------------------------
-- Test 7: Abandoned branches are hidden from history
----------------------------------------------------------------------
-- Setup: fresh DB, execute A → B → undo B → execute C
-- Branch: root → A → B (abandoned)
--                  └→ C (active)
-- History should show [A, C] not [A, B, C]
local DB7 = "/tmp/jve/test_edit_history_7.db"
local conn7 = setup_db(DB7)
insert_clip(conn7, "b1", 0, 200, "v1")
insert_clip(conn7, "b2", 200, 200, "v1")
timeline_state.reload_clips("seq")

-- Command A: delete b1
local b1 = timeline_state.get_clip_by_id("b1")
assert(b1, "b1 should exist")
timeline_state.set_selection({b1})
result = command_manager.execute("DeleteSelection", {
    project_id = "proj", sequence_id = "seq",
})
assert(result.success, "delete b1 should succeed")

-- Command B: delete b2
timeline_state.reload_clips("seq")
local b2 = timeline_state.get_clip_by_id("b2")
assert(b2, "b2 should exist after deleting b1")
timeline_state.set_selection({b2})
result = command_manager.execute("DeleteSelection", {
    project_id = "proj", sequence_id = "seq",
})
assert(result.success, "delete b2 should succeed")

-- Undo B (back to just A done)
local undo7 = command_manager.undo()
assert(undo7.success, "undo b2 should succeed")

-- Command C: delete b2 again (creates new branch from A)
timeline_state.reload_clips("seq")
b2 = timeline_state.get_clip_by_id("b2")
assert(b2, "b2 should reappear after undo")
timeline_state.set_selection({b2})
result = command_manager.execute("DeleteSelection", {
    project_id = "proj", sequence_id = "seq",
})
assert(result.success, "delete b2 (branch C) should succeed")

-- Verify: history should show 2 entries (A and C), NOT 3 (A, B, C)
entries, visible_current = command_manager:list_history_entries()
assert(#entries == 2,
    string.format("abandoned branch B should be hidden: expected 2 entries, got %d", #entries))

-- Arrow should be on the last entry (C)
assert(visible_current == entries[#entries].sequence_number,
    "arrow should be on the latest command (C)")

-- Verify total commands in DB is 3 (A, B, C all stored — B just not displayed)
local total_q = conn7:prepare("SELECT COUNT(*) FROM commands")
assert(total_q:exec() and total_q:next())
local total_commands = total_q:value(0)
total_q:finalize()
assert(total_commands == 3,
    string.format("DB should have 3 commands (including abandoned), got %d", total_commands))

print("✅ abandoned branches hidden from history")

print("\n✅ test_edit_history_window.lua passed")
