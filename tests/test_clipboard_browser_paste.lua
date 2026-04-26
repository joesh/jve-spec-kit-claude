#!/usr/bin/env luajit

-- Black-box: browser copy/paste via clipboard_actions.
-- Verifies: copy captures masterclip snapshots, paste creates new masterclips
-- in DB via DuplicateMasterClip, undo removes them.
--
-- NOTE: This exercises the nested DuplicateMasterClip path in paste_browser().

require("test_env")

_G.qt_create_single_shot_timer = function() end

-- We need a controllable project_browser mock BEFORE clipboard_actions loads
local browser_selection = {}
local browser_refreshed
package.loaded["ui.project_browser"] = {
    get_selection_snapshot = function() return browser_selection end,
    get_selected_bin = function() return nil end,
    refresh = function() browser_refreshed = true end,
}
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require("core.database")
local command_manager = require("core.command_manager")
local clipboard = require("core.clipboard")
local clipboard_actions = require("core.clipboard_actions")
local focus_manager = require("ui.focus_manager")
local timeline_state = require("ui.timeline.timeline_state")
local Clip = require("models.clip")
local test_env = require("test_env")

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
            fps_numerator, fps_denominator, audio_rate,
            width, height, playhead_frame,
            view_start_frame, view_duration_frames,
            created_at, modified_at)
        VALUES ('seq', 'proj', 'Timeline', 'nested',
            24, 1, 48000, 1920, 1080, 0, 0, 10000, %d, %d);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1);
    ]], now, now, now, now)))

    command_manager.init('seq', 'proj')
    timeline_state.set_playhead_position(0)
    timeline_state.set_selection({})
    clipboard.clear()
    browser_selection = {}
    browser_refreshed = false
    return conn
end

-- V13: a "master clip" is a master Sequence with at least one media_ref.
local function count_master_clips(conn)
    local q = conn:prepare([[
        SELECT COUNT(DISTINCT s.id)
          FROM sequences s
          JOIN media_refs mr ON mr.owner_sequence_id = s.id
         WHERE s.kind = 'master'
    ]])
    assert(q:exec() and q:next())
    local c = q:value(0)
    q:finalize()
    return c
end

----------------------------------------------------------------------
-- Test 1: Browser copy + paste duplicates master clips, undo removes them
----------------------------------------------------------------------

local DB = "/tmp/jve/test_clipboard_browser_paste.db"
local conn = setup_db(DB)

-- Create two media files and masterclip sequences
local function create_media(media_id, dur_frames)
    assert(conn:exec(string.format([[
        INSERT INTO media (id, project_id, name, file_path,
            duration_frames, fps_numerator, fps_denominator,
            width, height, audio_channels, codec,
            created_at, modified_at, metadata)
        VALUES ('%s', 'proj', '%s.mov', '/tmp/jve/%s.mov',
            %d, 24, 1, 1920, 1080, 0, 'prores',
            0, 0, '{}')
    ]], media_id, media_id, media_id, dur_frames)))
end

create_media("media_a", 120)
create_media("media_b", 240)

local mc_a_seq_id = test_env.create_test_masterclip_sequence(
    "proj", "Clip A", 24, 1, 120, "media_a")
local mc_b_seq_id = test_env.create_test_masterclip_sequence(
    "proj", "Clip B", 24, 1, 240, "media_b")

-- V13: master clip ID == master sequence ID.
local mc_a_clip_id = mc_a_seq_id
local mc_b_clip_id = mc_b_seq_id

local initial_master_count = count_master_clips(conn)
assert(initial_master_count == 2,
    string.format("precondition: 2 master clips (got %d)", initial_master_count))

-- Set up browser selection snapshot (what project_browser.get_selection_snapshot returns)
browser_selection = {
    {
        type = "master_clip",
        clip_id = mc_a_clip_id,
        bin_id = nil,
        name = "Clip A",
        project_id = "proj",
    },
    {
        type = "master_clip",
        clip_id = mc_b_clip_id,
        bin_id = nil,
        name = "Clip B",
        project_id = "proj",
    },
}

-- Copy from browser
focus_manager.set_focused_panel("project_browser")
local ok, err = clipboard_actions.copy()
assert(ok, "browser copy should succeed: " .. tostring(err))

local payload = clipboard.get()
assert(payload, "clipboard should have content after copy")
assert(payload.kind == "browser_master_clips", "clipboard kind should be browser_master_clips")
assert(payload.count == 2, string.format("clipboard should have 2 items (got %d)", payload.count))

-- Paste via clipboard_actions (focus-aware dispatch — browser paste goes through DuplicateMasterClip)
browser_refreshed = false
local paste_ok, paste_err = clipboard_actions.paste()
assert(paste_ok, "browser paste should succeed: " .. tostring(paste_err))
assert(browser_refreshed, "paste should trigger project_browser.refresh()")

-- Verify: 2 new master clips created (4 total)
local after_paste_count = count_master_clips(conn)
assert(after_paste_count == 4,
    string.format("paste should create 2 new master clips (expected 4, got %d)", after_paste_count))

-- New master sequences should have the " copy" suffix.
local q = conn:prepare([[
    SELECT DISTINCT s.name
      FROM sequences s
      JOIN media_refs mr ON mr.owner_sequence_id = s.id
     WHERE s.kind = 'master' AND s.id NOT IN (?, ?)
     ORDER BY s.name
]])
q:bind_value(1, mc_a_clip_id)
q:bind_value(2, mc_b_clip_id)
assert(q:exec())
local new_names = {}
while q:next() do
    new_names[#new_names + 1] = q:value(0)
end
q:finalize()
assert(#new_names == 2, string.format("expected 2 new clips, got %d", #new_names))

-- Undo: new master clips removed
local undo = command_manager.undo()
assert(undo.success, "undo browser paste should succeed: " .. tostring(undo.error_message))

local after_undo_count = count_master_clips(conn)
assert(after_undo_count == 2,
    string.format("undo should restore to 2 master clips (got %d)", after_undo_count))

-- V13: originals are master sequences.
do
    local Sequence = require("models.sequence")
    assert(Sequence.load(mc_a_clip_id), "original mc_a master should survive undo")
    assert(Sequence.load(mc_b_clip_id), "original mc_b master should survive undo")
end

-- Redo: clips come back
local redo = command_manager.redo()
assert(redo.success, "redo browser paste should succeed: " .. tostring(redo.error_message))
assert(count_master_clips(conn) == 4,
    string.format("redo should restore to 4 master clips (got %d)", count_master_clips(conn)))

print("✅ test_clipboard_browser_paste.lua: copy/paste 2 master clips + undo/redo")

----------------------------------------------------------------------
-- Test 2: Paste with empty clipboard fails gracefully
----------------------------------------------------------------------

clipboard.clear()
focus_manager.set_focused_panel("project_browser")
local empty_ok, empty_err = clipboard_actions.paste()
assert(not empty_ok, "paste with empty clipboard should fail")
assert(empty_err and empty_err:find("empty"), "error should mention empty clipboard")

print("✅ test_clipboard_browser_paste.lua: empty clipboard paste returns error")

print("\n✅ test_clipboard_browser_paste.lua passed")
