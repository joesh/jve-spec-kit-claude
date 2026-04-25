#!/usr/bin/env luajit

-- Clipboard timeline operations: copy, paste (with undo/redo), cut, ripple-delete.
-- Uses REAL timeline_state — no mock. Verifies DB side effects (black-box).
-- All coordinates are integer frames. No ms conversion anywhere.

local test_env = require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mocks needed: panel_manager (Qt), project_browser (Qt)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}
package.loaded["ui.project_browser"] = false

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local clipboard = require('core.clipboard')
local timeline_state = require("ui.timeline.timeline_state")
local focus_manager = require("ui.focus_manager")

local SCHEMA_SQL = require("import_schema")

local now = os.time()
-- 25fps sequence (not 30!) — catches bugs where fps accidentally matches frame values
local BASE_DATA_SQL = string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) VALUES ('proj', 'Test Project', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, playhead_frame, view_start_frame, view_duration_frames, created_at, modified_at)
    VALUES ('seq', 'proj', 'Timeline', 'nested', 25, 1, 48000, 1920, 1080, 0, 0, 8000, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('a1', 'seq', 'A1', 'AUDIO', 1, 1);
]], now, now, now, now)

local clipboard_actions = require('core.clipboard_actions')

-- Cache masterclip IDs by media_id to avoid recreating
local masterclip_cache = {}

local function setup_database(path)
    os.remove(path)
    os.remove(path .. "-wal")
    os.remove(path .. "-shm")
    assert(database.init(path))
    local conn = database.get_connection()
    assert(conn:exec(SCHEMA_SQL))
    assert(conn:exec([[
        CREATE TABLE IF NOT EXISTS properties (
            id TEXT PRIMARY KEY,
            clip_id TEXT NOT NULL,
            property_name TEXT NOT NULL,
            property_value TEXT,
            property_type TEXT,
            default_value TEXT
        );
    ]]))
    assert(conn:exec(BASE_DATA_SQL))
    command_manager.init('seq', 'proj')
    timeline_state.set_playhead_position(0)
    timeline_state.set_selection({})
    clipboard.clear()
    masterclip_cache = {}
end

local function reopen_database(path)
    assert(database.set_path(path))
    command_manager.init('seq', 'proj')
    timeline_state.set_playhead_position(0)
    timeline_state.set_selection({})
end

--- Create media + masterclip with duration in frames at 25fps
local function create_media_and_masterclip(media_id, duration_frames)
    if masterclip_cache[media_id] then
        return masterclip_cache[media_id]
    end
    local Media = require('models.media')
    local media = Media.create({
        id = media_id,
        project_id = 'proj',
        file_path = '/tmp/jve/' .. media_id .. '.mov',
        name = media_id,
        duration_frames = duration_frames,
        fps_numerator = 25,
        fps_denominator = 1,
    })
    media:save(database.get_connection())
    local master_clip_id = test_env.create_test_masterclip_sequence(
        'proj', media_id .. ' MC', 25, 1, duration_frames, media_id)
    masterclip_cache[media_id] = master_clip_id
    return master_clip_id
end

--- Insert a clip directly via Insert command. All values are integer frames.
-- Sets marks on the masterclip sequence to define the source range.
local function insert_clip(params)
    local Sequence = require("models.sequence")
    local master_clip_id = create_media_and_masterclip(params.media_id, params.media_duration)

    -- Set in/out marks on the masterclip sequence (the source range)
    if params.source_in or params.source_out then
        local mc_seq = assert(Sequence.load(master_clip_id), "insert_clip: masterclip not found")
        mc_seq.mark_in = params.source_in
        mc_seq.mark_out = params.source_out
        assert(mc_seq:save(), "insert_clip: failed to save masterclip marks")
    end

    local cmd = Command.create("Insert", "proj")
    cmd:set_parameters({
        master_clip_id = master_clip_id,
        track_id = params.track_id,
        sequence_id = "seq",
        insert_time = params.timeline_start,
        clip_id = params.clip_id,
        advance_playhead = false,
    })
    local result = command_manager.execute(cmd)
    assert(result.success, result.error_message or "Insert command failed")
end

--- Count timeline clips (excludes masterclip stream clips)
local function count_timeline_clips()
    local conn = database.get_connection()
    local stmt = conn:prepare("SELECT COUNT(*) FROM clips WHERE owner_sequence_id = 'seq'")
    assert(stmt:exec() and stmt:next())
    local n = stmt:value(0)
    stmt:finalize()
    return n
end

--- Find a timeline clip by its timeline_start_frame
local function find_clip_at_frame(frame)
    local conn = database.get_connection()
    local stmt = conn:prepare([[
        SELECT id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame
        FROM clips WHERE owner_sequence_id = 'seq' AND timeline_start_frame = ?
    ]])
    stmt:bind_value(1, frame)
    local found = stmt:exec() and stmt:next()
    local result = found and {
        id = stmt:value(0),
        timeline_start = stmt:value(1),
        duration = stmt:value(2),
        source_in = stmt:value(3),
        source_out = stmt:value(4),
    } or nil
    stmt:finalize()
    return result
end

--- Get clip start frame from DB
local function get_clip_start_frame(clip_id)
    local conn = database.get_connection()
    local stmt = conn:prepare("SELECT timeline_start_frame FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    if not (stmt:exec() and stmt:next()) then
        stmt:finalize()
        error("clip not found: " .. tostring(clip_id))
    end
    local f = stmt:value(0)
    stmt:finalize()
    return f
end

----------------------------------------------------------------------
-- Test 1: Copy/paste lands at exact playhead frame + undo removes it
----------------------------------------------------------------------

local TEST1_DB = "/tmp/jve/test_clipboard_paste_position.db"
setup_database(TEST1_DB)

-- Non-trivial values: source_in=50 (not 0), duration=120, at frame 300
-- At 25fps, frame 300 = 12 seconds. If paste code divides by 1000 and
-- multiplies by fps, frame 750 becomes floor(750/1000*25)=18 — very wrong.
insert_clip({
    clip_id = "orig",
    media_id = "media_a",
    media_duration = 500,
    track_id = "v1",
    timeline_start = 300,
    duration = 120,
    source_in = 50,
    source_out = 170,
})

-- Copy the clip
local orig = timeline_state.get_clip_by_id("orig")
assert(orig, "orig should exist in timeline_state")
timeline_state.set_selection({orig})
focus_manager.set_focused_panel("timeline")
assert(clipboard_actions.copy())

-- Paste at frame 750 — deliberately chosen to catch ms/frame confusion.
-- If code treats 750 as ms: floor(750/1000 * 25) = 18. Test would catch this.
timeline_state.set_playhead_position(750)
timeline_state.set_selection({})

local paste_ok, paste_err = clipboard_actions.paste()
assert(paste_ok, paste_err or "paste failed")

-- Verify: pasted clip should be at frame 750 with same duration and source coords
local pasted = find_clip_at_frame(750)
assert(pasted, "pasted clip should land at frame 750 (exact playhead position)")
assert(pasted.duration == 120,
    string.format("pasted duration should be 120 (got %d)", pasted.duration))
assert(pasted.source_in == 50,
    string.format("pasted source_in should be 50 (got %d)", pasted.source_in))
assert(pasted.source_out == 170,
    string.format("pasted source_out should be 170 (got %d)", pasted.source_out))

-- Original should still be at frame 300
local orig_after = find_clip_at_frame(300)
assert(orig_after and orig_after.id == "orig",
    "original clip should still be at frame 300")

-- Undo: pasted clip should be removed, original untouched
local undo_ok = command_manager.undo()
assert(undo_ok.success, "Undo Paste should succeed")

local pasted_after_undo = find_clip_at_frame(750)
assert(not pasted_after_undo, "pasted clip should be gone after undo")

local orig_after_undo = find_clip_at_frame(300)
assert(orig_after_undo and orig_after_undo.id == "orig",
    "original clip should survive undo")
assert(count_timeline_clips() == 1, "only original clip should remain after undo")

-- Redo: pasted clip should reappear at frame 750
local redo_ok = command_manager.redo()
assert(redo_ok.success, redo_ok.error_message or "Redo Paste should succeed")

local pasted_after_redo = find_clip_at_frame(750)
assert(pasted_after_redo, "pasted clip should reappear at frame 750 after redo")
assert(pasted_after_redo.duration == 120,
    "redo should restore same duration")
assert(count_timeline_clips() == 2, "two clips should exist after redo")

print("✅ Paste lands at exact playhead frame, undo removes it, redo restores it")

----------------------------------------------------------------------
-- Test 2: Paste with overwrite trims existing clip, undo restores it
----------------------------------------------------------------------

local TEST2_DB = "/tmp/jve/test_clipboard_paste_overwrite.db"
setup_database(TEST2_DB)

-- Clip A at [100, 300) on v1
insert_clip({
    clip_id = "clip_a",
    media_id = "media_b",
    media_duration = 500,
    track_id = "v1",
    timeline_start = 100,
    duration = 200,
    source_in = 0,
    source_out = 200,
})

-- Clip B at [500, 600) on v1 (will be copied and pasted overlapping A)
insert_clip({
    clip_id = "clip_b",
    media_id = "media_c",
    media_duration = 500,
    track_id = "v1",
    timeline_start = 500,
    duration = 100,
    source_in = 10,
    source_out = 110,
})

-- Copy clip_b
local cb = timeline_state.get_clip_by_id("clip_b")
assert(cb, "clip_b should exist")
timeline_state.set_selection({cb})
focus_manager.set_focused_panel("timeline")
assert(clipboard_actions.copy())

-- Paste at frame 200 — overlaps clip_a's [200,300) region
timeline_state.set_playhead_position(200)
timeline_state.set_selection({})
assert(clipboard_actions.paste())

-- clip_a should be trimmed (overwrite carves out [200,300))
-- Pasted clip should be at [200, 300)
local pasted_clip = find_clip_at_frame(200)
assert(pasted_clip, "pasted clip should be at frame 200")
assert(pasted_clip.id ~= "clip_a", "pasted clip should not be clip_a")

-- Undo: clip_a should be restored to original [100, 300)
assert(command_manager.undo().success, "Undo should succeed")

local restored_a = find_clip_at_frame(100)
assert(restored_a and restored_a.id == "clip_a", "clip_a should be restored at frame 100")
assert(restored_a.duration == 200,
    string.format("clip_a should have original duration 200 (got %d)", restored_a.duration))

print("✅ Paste overwrite trims existing clip, undo restores original")

----------------------------------------------------------------------
-- Test 3: Undo/Redo regression — downstream clips stay put
----------------------------------------------------------------------

local TEST3_DB = "/tmp/jve/test_clipboard_paste_downstream.db"
setup_database(TEST3_DB)

-- Three clips on v1, well separated
insert_clip({
    clip_id = "d_src", media_id = "media_d1", media_duration = 500,
    track_id = "v1", timeline_start = 0, duration = 100, source_in = 0, source_out = 100,
})
insert_clip({
    clip_id = "d_mid", media_id = "media_d2", media_duration = 500,
    track_id = "v1", timeline_start = 5000, duration = 100, source_in = 0, source_out = 100,
})
insert_clip({
    clip_id = "d_tail", media_id = "media_d3", media_duration = 500,
    track_id = "v1", timeline_start = 10000, duration = 100, source_in = 0, source_out = 100,
})

local baseline_tail = get_clip_start_frame("d_tail")

-- Copy d_src, paste far away
local d_src = timeline_state.get_clip_by_id("d_src")
assert(d_src)
timeline_state.set_selection({d_src})
focus_manager.set_focused_panel("timeline")
assert(clipboard_actions.copy())

timeline_state.set_playhead_position(20000)
timeline_state.set_selection({})
assert(clipboard_actions.paste())

-- Undo and redo
assert(command_manager.undo().success)
reopen_database(TEST3_DB)
assert(command_manager.redo().success, "Redo should succeed")

local post_redo_tail = get_clip_start_frame("d_tail")
assert(post_redo_tail == baseline_tail,
    string.format("downstream clip should not move (expected %d, got %d)",
        baseline_tail, post_redo_tail))

print("✅ Redo after paste preserves downstream clip positions")

----------------------------------------------------------------------
-- Test 4: Cut removes clip + places on clipboard
----------------------------------------------------------------------

local TEST4_DB = "/tmp/jve/test_clipboard_cut.db"
setup_database(TEST4_DB)

insert_clip({
    clip_id = "cut_clip",
    media_id = "media_cut",
    media_duration = 500,
    track_id = "v1",
    timeline_start = 250,
    duration = 80,
    source_in = 30,
    source_out = 110,
})

local cut_c = timeline_state.get_clip_by_id("cut_clip")
assert(cut_c)
timeline_state.set_selection({cut_c})

local cut_cmd = Command.create("Cut", "proj")
assert(command_manager.execute(cut_cmd).success, "Cut should succeed")

-- Clip removed from DB
assert(count_timeline_clips() == 0, "cut clip should be removed")

-- Clipboard has the clip data
local cut_payload = clipboard.get()
assert(cut_payload and cut_payload.kind == "timeline_clips",
    "Cut should place clip data on clipboard")
assert(cut_payload.clips and #cut_payload.clips == 1)

print("✅ Cut removes clip and places data on clipboard")

----------------------------------------------------------------------
-- Test 5: RippleDelete shifts downstream, undo restores
----------------------------------------------------------------------

local TEST5_DB = "/tmp/jve/test_clipboard_ripple.db"
setup_database(TEST5_DB)

insert_clip({
    clip_id = "r_a", media_id = "media_r1", media_duration = 500,
    track_id = "v1", timeline_start = 0, duration = 75, source_in = 0, source_out = 75,
})
insert_clip({
    clip_id = "r_b", media_id = "media_r2", media_duration = 500,
    track_id = "v1", timeline_start = 200, duration = 100, source_in = 0, source_out = 100,
})

local orig_b_start = get_clip_start_frame("r_b")

local ripple_cmd = Command.create("RippleDeleteSelection", "proj")
ripple_cmd:set_parameter("clip_ids", {"r_a"})
ripple_cmd:set_parameter("sequence_id", "seq")
assert(command_manager.execute(ripple_cmd).success, "RippleDelete should succeed")

-- r_a deleted, r_b shifted left
local clips_after = database.load_clips("seq")
local r_a_exists = false
local r_b_after = nil
for _, c in ipairs(clips_after) do
    if c.id == "r_a" then r_a_exists = true end
    if c.id == "r_b" then r_b_after = c end
end
assert(not r_a_exists, "r_a should be deleted")
assert(r_b_after, "r_b should still exist")
assert(r_b_after.timeline_start < orig_b_start,
    string.format("r_b should shift left (was %d, now %d)", orig_b_start, r_b_after.timeline_start))

-- Undo restores both
assert(command_manager.undo().success)
local undo_clips = database.load_clips("seq")
local undo_a_found, undo_b_start = false, nil
for _, c in ipairs(undo_clips) do
    if c.id == "r_a" then undo_a_found = true end
    if c.id == "r_b" then undo_b_start = c.timeline_start end
end
assert(undo_a_found, "r_a should be restored")
assert(undo_b_start == orig_b_start,
    string.format("r_b should return to %d (got %d)", orig_b_start, undo_b_start))

print("✅ RippleDelete shifts downstream, undo restores both")
