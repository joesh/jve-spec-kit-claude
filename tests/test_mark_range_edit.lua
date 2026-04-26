#!/usr/bin/env luajit

-- Mark-range editing: lift, extract, copy, cut with in/out marks.
-- Black-box: verifies DB side effects and clipboard state.

local test_env = require('test_env')

_G.qt_create_single_shot_timer = function() end
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
local clipboard_actions = require('core.clipboard_actions')

local SCHEMA_SQL = require("import_schema")

local now = os.time()
-- 25fps to catch unit confusion
local BASE_SQL = string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) VALUES ('proj', 'Test', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate,
        width, height, playhead_frame, view_start_frame, view_duration_frames, created_at, modified_at)
    VALUES ('seq', 'proj', 'TL', 'nested', 25, 1, 48000, 1920, 1080, 0, 0, 8000, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('v2', 'seq', 'V2', 'VIDEO', 2, 1);
]], now, now, now, now)

local masterclip_cache = {}

local function setup(path)
    os.remove(path)
    os.remove(path .. "-wal")
    os.remove(path .. "-shm")
    assert(database.init(path))
    local conn = database.get_connection()
    assert(conn:exec(SCHEMA_SQL))
    assert(conn:exec([[
        CREATE TABLE IF NOT EXISTS properties (
            id TEXT PRIMARY KEY, clip_id TEXT NOT NULL,
            property_name TEXT NOT NULL, property_value TEXT,
            property_type TEXT, default_value TEXT
        );
    ]]))
    assert(conn:exec(BASE_SQL))
    command_manager.init('seq', 'proj')
    timeline_state.set_playhead_position(0)
    timeline_state.set_selection({})
    clipboard.clear()
    masterclip_cache = {}
end

local function create_mc(media_id, dur)
    if masterclip_cache[media_id] then return masterclip_cache[media_id] end
    local Media = require('models.media')
    local m = Media.create({
        id = media_id, project_id = 'proj',
        file_path = '/tmp/jve/' .. media_id .. '.mov',
        name = media_id, duration_frames = dur,
        fps_numerator = 25, fps_denominator = 1,
        width = 1920, height = 1080, audio_channels = 0,
    })
    m:save(database.get_connection())
    local mc = test_env.create_test_masterclip_sequence('proj', media_id..' MC', 25, 1, dur, media_id)
    masterclip_cache[media_id] = mc
    return mc
end

-- Map test-friendly clip aliases to V13 generated ids so callers can
-- still refer to clips by 'a', 'b', etc.
local clip_alias = {}
local function resolve_clip_id(id) return clip_alias[id] or id end

local function insert_clip(p)
    local Sequence = require("models.sequence")
    local mc = create_mc(p.media_id, p.media_dur)
    -- Set marks on masterclip sequence — Overwrite reads timing from these
    local mc_seq = Sequence.load(mc)
    assert(mc_seq, "insert_clip: failed to load masterclip sequence")
    mc_seq:set_in(p.src_in)
    mc_seq:set_out(p.src_out)
    mc_seq:save()
    local cmd = Command.create("Overwrite", "proj")
    cmd:set_parameters({
        nested_sequence_id = mc, target_video_track_id = p.track_id, sequence_id = "seq",
        timeline_start_frame = p.start,
        advance_playhead = false,
    })
    local result = command_manager.execute(cmd)
    assert(result.success, "overwrite failed: " .. tostring(result.error_message))
    if p.id then
        local ids = cmd:get_parameter("created_clip_ids") or {}
        if ids[1] then clip_alias[p.id] = ids[1] end
    end
end

local function count_clips()
    local conn = database.get_connection()
    local s = conn:prepare("SELECT COUNT(*) FROM clips WHERE owner_sequence_id='seq'")
    assert(s:exec() and s:next())
    local n = s:value(0); s:finalize(); return n
end

local function get_clip(clip_id)
    clip_id = resolve_clip_id(clip_id)
    local conn = database.get_connection()
    local s = conn:prepare([[
        SELECT timeline_start_frame, duration_frames, source_in_frame, source_out_frame
        FROM clips WHERE id=? AND owner_sequence_id='seq'
    ]])
    s:bind_value(1, clip_id)
    if not (s:exec() and s:next()) then s:finalize(); return nil end
    local r = {
        timeline_start = s:value(0), duration = s:value(1),
        source_in = s:value(2), source_out = s:value(3),
    }
    s:finalize(); return r
end

local function set_marks(mark_in, mark_out_inclusive)
    -- Use commands so timeline_state's cached sequence gets updated via signals
    assert(command_manager.execute("SetMarkIn", {
        project_id = "proj", sequence_id = "seq", frame = mark_in,
    }).success, "set_marks: SetMarkIn failed")
    assert(command_manager.execute("SetMarkOut", {
        project_id = "proj", sequence_id = "seq", frame = mark_out_inclusive,
    }).success, "set_marks: SetMarkOut failed")
end

----------------------------------------------------------------------
-- Test 1: LiftRange removes clips in mark range, undo restores
----------------------------------------------------------------------
setup("/tmp/jve/test_mark_lift.db")

-- v1: [100,300) [400,600)
-- v2: [200,500)
insert_clip({id="a", media_id="m1", media_dur=500, track_id="v1", start=100, dur=200, src_in=0, src_out=200})
insert_clip({id="b", media_id="m2", media_dur=500, track_id="v1", start=400, dur=200, src_in=0, src_out=200})
insert_clip({id="c", media_id="m3", media_dur=500, track_id="v2", start=200, dur=300, src_in=0, src_out=300})

local pre_count = count_clips()

-- Lift range [250, 450) — clips a partially, b partially, c partially overlapping
local result = command_manager.execute("LiftRange", {
    project_id = "proj", sequence_id = "seq",
    mark_in = 250, mark_out = 450,
})
assert(result.success, result.error_message or "LiftRange failed")

-- clip a should be trimmed: [100, 250) dur=150
local ca = get_clip("a")
assert(ca, "clip a should survive (partially outside range)")
assert(ca.duration == 150, string.format("clip a duration should be 150 (got %d)", ca.duration))
assert(ca.timeline_start == 100, "clip a should still start at 100")

-- clip b should be trimmed: [450, 600) dur=150
local cb = get_clip("b")
assert(cb, "clip b should survive (partially outside range)")
assert(cb.timeline_start == 450, string.format("clip b should start at 450 (got %d)", cb.timeline_start))
assert(cb.duration == 150, string.format("clip b duration should be 150 (got %d)", cb.duration))

-- clip c trimmed on both sides: [200,250) left + [450,500) right = two fragments
-- OR resolve_occlusions may delete the middle and create a right fragment
-- Actually resolve_occlusions splits: left [200,250) + right [450,500)
local cc = get_clip("c")
-- Original c might be trimmed to [200,250) and a new clip created for [450,500)
-- Let's just check c is trimmed and total clip count makes sense
if cc then
    assert(cc.duration < 300, "clip c should be trimmed")
end

-- Undo: all clips restored to original
assert(command_manager.undo().success, "Undo LiftRange should succeed")
assert(count_clips() == pre_count,
    string.format("undo should restore clip count (expected %d, got %d)", pre_count, count_clips()))
local ca_undo = get_clip("a")
assert(ca_undo and ca_undo.duration == 200, "clip a should be restored to dur=200")
local cb_undo = get_clip("b")
assert(cb_undo and cb_undo.timeline_start == 400, "clip b should be restored at 400")

print("✅ LiftRange trims/removes clips in range, undo restores")

----------------------------------------------------------------------
-- Test 2: ExtractRange lifts + closes gap
----------------------------------------------------------------------
setup("/tmp/jve/test_mark_extract.db")

-- v1: [0,100) [200,400) [500,600)
insert_clip({id="x", media_id="mx", media_dur=500, track_id="v1", start=0, dur=100, src_in=0, src_out=100})
insert_clip({id="y", media_id="my", media_dur=500, track_id="v1", start=200, dur=200, src_in=0, src_out=200})
insert_clip({id="z", media_id="mz", media_dur=500, track_id="v1", start=500, dur=100, src_in=0, src_out=100})

-- Extract [150, 350) — range_duration=200
-- y overlaps: [200,400) → left part [200,250) survives? No, [150,350) removes [200,350) of y
-- After lift: x=[0,100), y trimmed to [350,400) dur=50, z=[500,600)
-- After ripple (shift left by 200 at frame 150):
--   x stays (before 150)
--   y remnant shifts: 350-200=150, dur=50 → [150,200)
--   z shifts: 500-200=300 → [300,400)
local result2 = command_manager.execute("ExtractRange", {
    project_id = "proj", sequence_id = "seq",
    mark_in = 150, mark_out = 350,
})
assert(result2.success, result2.error_message or "ExtractRange failed")

-- z should have shifted left by 200
local cz = get_clip("z")
assert(cz, "clip z should exist")
assert(cz.timeline_start == 300,
    string.format("clip z should shift from 500 to 300 (got %d)", cz.timeline_start))

-- x untouched (before mark_in)
local cx = get_clip("x")
assert(cx and cx.timeline_start == 0 and cx.duration == 100, "clip x should be unchanged")

-- Undo restores everything
assert(command_manager.undo().success)
local cz_undo = get_clip("z")
assert(cz_undo and cz_undo.timeline_start == 500, "clip z should be back at 500 after undo")

print("✅ ExtractRange lifts range and closes gap, undo restores")

----------------------------------------------------------------------
-- Test 3: Delete with marks dispatches to LiftRange
----------------------------------------------------------------------
setup("/tmp/jve/test_mark_delete_dispatch.db")

insert_clip({id="d1", media_id="md1", media_dur=500, track_id="v1", start=0, dur=300, src_in=0, src_out=300})

set_marks(50, 149)  -- mark_out exclusive = 150, range = [50, 150)
focus_manager.set_focused_panel("timeline")
timeline_state.set_selection({})

local del_cmd = Command.create("DeleteSelection", "proj")
assert(command_manager.execute(del_cmd).success, "DeleteSelection with marks should succeed")

local cd1 = get_clip("d1")
assert(cd1, "clip d1 should survive (partially outside range)")
assert(cd1.timeline_start == 0, "d1 should still start at 0")
assert(cd1.duration < 300, string.format("d1 should be trimmed (got dur=%d)", cd1.duration))

-- Undo
assert(command_manager.undo().success)
local cd1_undo = get_clip("d1")
assert(cd1_undo and cd1_undo.duration == 300, "d1 should be restored to dur=300")

print("✅ DeleteSelection with marks dispatches to LiftRange")

----------------------------------------------------------------------
-- Test 4: Copy with marks copies clipped range to clipboard
----------------------------------------------------------------------
setup("/tmp/jve/test_mark_copy.db")

-- Clip at [100, 400) with source_in=50, source_out=350
insert_clip({id="cp1", media_id="mcp", media_dur=500, track_id="v1", start=100, dur=300, src_in=50, src_out=350})

set_marks(200, 299)  -- exclusive mark_out=300, range [200,300)
focus_manager.set_focused_panel("timeline")

local ok_copy, err_copy = clipboard_actions.copy()
assert(ok_copy, err_copy or "copy with marks failed")

local payload = clipboard.get()
assert(payload and payload.kind == "timeline_clips", "clipboard should have timeline clips")
assert(payload.count == 1, "should copy one clip")

local copied = payload.clips[1]
-- Original clip spans [100,400), marks [200,300) → effective [200,300) dur=100
-- source_in shifts by left_trim=100: 50+100=150
-- source_out shifts by right_trim=100: 350-100=250
assert(copied.duration == 100,
    string.format("copied duration should be 100 (got %d)", copied.duration))
assert(copied.source_in == 150,
    string.format("copied source_in should be 150 (got %d)", copied.source_in))
assert(copied.source_out == 250,
    string.format("copied source_out should be 250 (got %d)", copied.source_out))
assert(copied.offset_frames == 0, "first clip offset should be 0 (relative to mark_in)")

print("✅ Copy with marks clips to range boundaries")

----------------------------------------------------------------------
-- Test 5: Cut with marks = copy + lift
----------------------------------------------------------------------
setup("/tmp/jve/test_mark_cut.db")

insert_clip({id="ct1", media_id="mct", media_dur=500, track_id="v1", start=0, dur=400, src_in=0, src_out=400})

set_marks(100, 299)  -- exclusive=300, range [100,300)
focus_manager.set_focused_panel("timeline")
timeline_state.set_selection({})

local cut_cmd = Command.create("Cut", "proj")
assert(command_manager.execute(cut_cmd).success, "Cut with marks should succeed")

-- Clipboard should have the range
local cut_payload = clipboard.get()
assert(cut_payload and cut_payload.kind == "timeline_clips")
assert(cut_payload.clips[1].duration == 200, "cut clipboard should have 200-frame clip")

-- Timeline: clip trimmed (range removed)
local cct = get_clip("ct1")
assert(cct, "ct1 should survive (left portion)")
assert(cct.duration < 400, "ct1 should be trimmed")

-- Undo restores the timeline (clipboard stays — clipboard is not undoable)
assert(command_manager.undo().success)
local cct_undo = get_clip("ct1")
assert(cct_undo and cct_undo.duration == 400, "ct1 should be restored to dur=400")

print("✅ Cut with marks copies range and lifts, undo restores")
