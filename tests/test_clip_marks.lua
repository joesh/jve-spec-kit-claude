#!/usr/bin/env luajit

-- Regression: per-clip marks (mark_in_frame, mark_out_frame, playhead_frame)
-- persist independently per clip via database helpers.

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

require("test_env")

local database = require("core.database")

local DB_PATH = "/tmp/jve/test_clip_marks.db"
os.remove(DB_PATH)

assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(require("import_schema")))

-- Seed project, media, sequence, track, and two master clips
assert(db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at, settings)
    VALUES ('proj', 'Project', strftime('%s','now'), strftime('%s','now'), '{}');

    INSERT INTO media (
        id, project_id, name, file_path,
        duration_frames, fps_numerator, fps_denominator,
        width, height, audio_channels, codec,
        created_at, modified_at
    )
    VALUES (
        'media1', 'proj', 'TestMedia', '/tmp/test.mov',
        1000, 24, 1,
        1920, 1080, 2, 'h264',
        strftime('%s','now'), strftime('%s','now')
    );

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    )
    VALUES (
        'seq', 'proj', 'Sequence', 'timeline',
        24, 1, 48000,
        1920, 1080,
        0, 240, 0,
        '[]', '[]', '[]',
        0, strftime('%s','now'), strftime('%s','now')
    );

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO clips (
        id, project_id, clip_kind, name,
        track_id, media_id,
        master_clip_id, owner_sequence_id,
        timeline_start_frame, duration_frames,
        source_in_frame, source_out_frame,
        enabled, offline,
        fps_numerator, fps_denominator,
        created_at, modified_at
    )
    VALUES (
        'clipA', 'proj', 'master', 'Clip A',
        'v1', 'media1',
        NULL, 'seq',
        0, 100,
        0, 100,
        1, 0,
        24, 1,
        strftime('%s','now'), strftime('%s','now')
    );

    INSERT INTO clips (
        id, project_id, clip_kind, name,
        track_id, media_id,
        master_clip_id, owner_sequence_id,
        timeline_start_frame, duration_frames,
        source_in_frame, source_out_frame,
        enabled, offline,
        fps_numerator, fps_denominator,
        created_at, modified_at
    )
    VALUES (
        'clipB', 'proj', 'master', 'Clip B',
        'v1', 'media1',
        NULL, 'seq',
        100, 200,
        100, 300,
        1, 0,
        24, 1,
        strftime('%s','now'), strftime('%s','now')
    );
]]))

-- ======================================================================
-- Test 1: New clips have NULL marks and 0 playhead by default
-- ======================================================================
print("Test 1: default marks on new clips...")
local marks = database.load_clip_marks("clipA")
assert(marks, "load_clip_marks returned nil")
assert(marks.mark_in_frame == nil, "expected mark_in_frame nil, got " .. tostring(marks.mark_in_frame))
assert(marks.mark_out_frame == nil, "expected mark_out_frame nil, got " .. tostring(marks.mark_out_frame))
assert(marks.playhead_frame == 0, "expected playhead_frame 0, got " .. tostring(marks.playhead_frame))
print("  OK")

-- ======================================================================
-- Test 2: Save marks + playhead, reload, verify persistence
-- ======================================================================
print("Test 2: save and reload marks...")
database.save_clip_marks("clipA", 10, 50, 25)
local marks2 = database.load_clip_marks("clipA")
assert(marks2.mark_in_frame == 10, "expected mark_in 10, got " .. tostring(marks2.mark_in_frame))
assert(marks2.mark_out_frame == 50, "expected mark_out 50, got " .. tostring(marks2.mark_out_frame))
assert(marks2.playhead_frame == 25, "expected playhead 25, got " .. tostring(marks2.playhead_frame))
print("  OK")

-- ======================================================================
-- Test 3: Multiple clips maintain independent marks
-- ======================================================================
print("Test 3: independent marks per clip...")
database.save_clip_marks("clipB", 200, 280, 250)
-- clipA still has its own marks
local marksA = database.load_clip_marks("clipA")
local marksB = database.load_clip_marks("clipB")
assert(marksA.mark_in_frame == 10, "clipA mark_in changed unexpectedly")
assert(marksA.playhead_frame == 25, "clipA playhead changed unexpectedly")
assert(marksB.mark_in_frame == 200, "clipB mark_in wrong: " .. tostring(marksB.mark_in_frame))
assert(marksB.mark_out_frame == 280, "clipB mark_out wrong: " .. tostring(marksB.mark_out_frame))
assert(marksB.playhead_frame == 250, "clipB playhead wrong: " .. tostring(marksB.playhead_frame))
print("  OK")

-- ======================================================================
-- Test 4: Clear marks → nil (playhead preserved)
-- ======================================================================
print("Test 4: clear marks sets nil...")
database.save_clip_marks("clipA", nil, nil, 25)
local marks4 = database.load_clip_marks("clipA")
assert(marks4.mark_in_frame == nil, "expected mark_in nil after clear")
assert(marks4.mark_out_frame == nil, "expected mark_out nil after clear")
assert(marks4.playhead_frame == 25, "playhead should be preserved after clearing marks")
print("  OK")

-- ======================================================================
-- Test 5: load_clip_marks for nonexistent clip returns nil
-- ======================================================================
print("Test 5: nonexistent clip returns nil...")
local marks5 = database.load_clip_marks("no_such_clip")
assert(marks5 == nil, "expected nil for nonexistent clip")
print("  OK")

-- ======================================================================
-- Test 6: save_clip_marks asserts on nil clip_id
-- ======================================================================
print("Test 6: assert on nil clip_id...")
local ok6, err6 = pcall(database.save_clip_marks, nil, 0, 0, 0)
assert(not ok6, "expected assertion on nil clip_id")
assert(tostring(err6):find("clip_id"), "expected clip_id in error message, got: " .. tostring(err6))
print("  OK")

-- ======================================================================
-- Test 7: Clip.create with marks → save → load → verify round-trip
-- ======================================================================
print("Test 7: Clip model mark round-trip...")

-- Create a separate masterclip sequence + track to avoid overlap with seeded clips
assert(db:exec([[
    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    )
    VALUES (
        'mc_seq', 'proj', 'MC Seq', 'masterclip',
        24, 1, 48000,
        1920, 1080,
        0, 240, 0,
        '[]', '[]', '[]',
        0, strftime('%s','now'), strftime('%s','now')
    );

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('mc_v1', 'mc_seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]]))

local Clip = require("models.clip")
local clip7 = Clip.create("Marked Clip", "media1", {
    id = "clip7",
    project_id = "proj",
    clip_kind = "master",
    track_id = "mc_v1",
    owner_sequence_id = "mc_seq",
    timeline_start = 0,
    duration = 500,
    source_in = 0,
    source_out = 500,
    fps_numerator = 24,
    fps_denominator = 1,
    mark_in = 10,
    mark_out = 200,
    playhead_frame = 50,
})
assert(clip7.mark_in == 10, "create: mark_in not set, got " .. tostring(clip7.mark_in))
assert(clip7.mark_out == 200, "create: mark_out not set, got " .. tostring(clip7.mark_out))
assert(clip7.playhead_frame == 50, "create: playhead_frame not set, got " .. tostring(clip7.playhead_frame))
assert(clip7:save({skip_occlusion = true}))

local loaded7 = Clip.load("clip7")
assert(loaded7, "Clip.load returned nil for clip7")
assert(loaded7.mark_in == 10, "loaded mark_in wrong: " .. tostring(loaded7.mark_in))
assert(loaded7.mark_out == 200, "loaded mark_out wrong: " .. tostring(loaded7.mark_out))
assert(loaded7.playhead_frame == 50, "loaded playhead_frame wrong: " .. tostring(loaded7.playhead_frame))
print("  OK")

-- ======================================================================
-- Test 8: Clip.create WITHOUT marks → defaults (nil/nil/0)
-- ======================================================================
print("Test 8: Clip model mark defaults...")
local clip8 = Clip.create("Unmarked Clip", "media1", {
    id = "clip8",
    project_id = "proj",
    clip_kind = "master",
    track_id = "mc_v1",
    owner_sequence_id = "mc_seq",
    timeline_start = 500,
    duration = 500,
    source_in = 0,
    source_out = 500,
    fps_numerator = 24,
    fps_denominator = 1,
})
assert(clip8.mark_in == nil, "default mark_in should be nil")
assert(clip8.mark_out == nil, "default mark_out should be nil")
assert(clip8.playhead_frame == 0, "default playhead_frame should be 0, got " .. tostring(clip8.playhead_frame))
assert(clip8:save({skip_occlusion = true}))

local loaded8 = Clip.load("clip8")
assert(loaded8, "Clip.load returned nil for clip8")
assert(loaded8.mark_in == nil, "loaded default mark_in should be nil")
assert(loaded8.mark_out == nil, "loaded default mark_out should be nil")
assert(loaded8.playhead_frame == 0, "loaded default playhead_frame wrong: " .. tostring(loaded8.playhead_frame))
print("  OK")

-- ======================================================================
-- Test 9: Clip.save persists marks on UPDATE (not just INSERT)
-- ======================================================================
print("Test 9: Clip model mark update persistence...")
loaded7.mark_in = 20
loaded7.mark_out = 300
loaded7.playhead_frame = 99
assert(loaded7:save({skip_occlusion = true}))

local reloaded7 = Clip.load("clip7")
assert(reloaded7.mark_in == 20, "updated mark_in wrong: " .. tostring(reloaded7.mark_in))
assert(reloaded7.mark_out == 300, "updated mark_out wrong: " .. tostring(reloaded7.mark_out))
assert(reloaded7.playhead_frame == 99, "updated playhead_frame wrong: " .. tostring(reloaded7.playhead_frame))
print("  OK")

-- ======================================================================
-- Test 10: Clip.create rejects non-integer mark_in
-- ======================================================================
print("Test 10: reject non-integer mark_in...")
local ok10, err10 = pcall(Clip.create, "Bad Mark", "media1", {
    id = "clip_bad_mark",
    project_id = "proj",
    clip_kind = "master",
    track_id = "mc_v1",
    owner_sequence_id = "mc_seq",
    timeline_start = 1000,
    duration = 100,
    source_in = 0,
    source_out = 100,
    fps_numerator = 24,
    fps_denominator = 1,
    mark_in = "frame10",  -- string, not number
})
assert(not ok10, "expected error for string mark_in")
assert(tostring(err10):find("mark_in"), "error should mention mark_in: " .. tostring(err10))
print("  OK")

-- ======================================================================
-- Test 11: Clip.create rejects non-integer mark_out
-- ======================================================================
print("Test 11: reject non-integer mark_out...")
local ok11, err11 = pcall(Clip.create, "Bad Mark", "media1", {
    id = "clip_bad_mark2",
    project_id = "proj",
    clip_kind = "master",
    track_id = "mc_v1",
    owner_sequence_id = "mc_seq",
    timeline_start = 1100,
    duration = 100,
    source_in = 0,
    source_out = 100,
    fps_numerator = 24,
    fps_denominator = 1,
    mark_out = true,  -- boolean, not number
})
assert(not ok11, "expected error for boolean mark_out")
assert(tostring(err11):find("mark_out"), "error should mention mark_out: " .. tostring(err11))
print("  OK")

-- ======================================================================
-- Test 12: Clip.create rejects non-integer playhead_frame
-- ======================================================================
print("Test 12: reject non-integer playhead_frame...")
local ok12, err12 = pcall(Clip.create, "Bad Playhead", "media1", {
    id = "clip_bad_ph",
    project_id = "proj",
    clip_kind = "master",
    track_id = "mc_v1",
    owner_sequence_id = "mc_seq",
    timeline_start = 1200,
    duration = 100,
    source_in = 0,
    source_out = 100,
    fps_numerator = 24,
    fps_denominator = 1,
    playhead_frame = "50",  -- string, not number
})
assert(not ok12, "expected error for string playhead_frame")
assert(tostring(err12):find("playhead_frame"), "error should mention playhead_frame: " .. tostring(err12))
print("  OK")

-- ======================================================================
-- Test 13: Sequence.find_masterclip_for_media asserts on nil
-- ======================================================================
print("Test 13: find_masterclip_for_media asserts on nil...")
local Sequence = require("models.sequence")
local ok13, err13 = pcall(Sequence.find_masterclip_for_media, nil)
assert(not ok13, "expected assertion on nil media_id")
assert(tostring(err13):find("media_id"), "error should mention media_id: " .. tostring(err13))
print("  OK")

-- ======================================================================
-- Test 14: Sequence.find_masterclip_for_media asserts on empty string
-- ======================================================================
print("Test 14: find_masterclip_for_media asserts on empty string...")
local ok14, err14 = pcall(Sequence.find_masterclip_for_media, "")
assert(not ok14, "expected assertion on empty media_id")
assert(tostring(err14):find("media_id"), "error should mention media_id: " .. tostring(err14))
print("  OK")

-- ======================================================================
-- Test 15: Clip.create rejects false for playhead_frame
-- ======================================================================
print("Test 15: reject false playhead_frame...")
local ok15, err15 = pcall(Clip.create, "Bad PH", "media1", {
    id = "clip_bad_ph2",
    project_id = "proj",
    clip_kind = "master",
    track_id = "mc_v1",
    owner_sequence_id = "mc_seq",
    timeline_start = 1300,
    duration = 100,
    source_in = 0,
    source_out = 100,
    fps_numerator = 24,
    fps_denominator = 1,
    playhead_frame = false,  -- boolean, not number or nil
})
assert(not ok15, "expected error for false playhead_frame")
assert(tostring(err15):find("playhead_frame"), "error should mention playhead_frame: " .. tostring(err15))
print("  OK")

-- ======================================================================
-- Test 16: mark_in = 0 round-trips correctly (0 is NOT nil)
-- ======================================================================
print("Test 16: mark_in=0 round-trips as 0 not nil...")
local clip16 = Clip.create("Zero Mark", "media1", {
    id = "clip16",
    project_id = "proj",
    clip_kind = "master",
    track_id = "mc_v1",
    owner_sequence_id = "mc_seq",
    timeline_start = 1400,
    duration = 100,
    source_in = 0,
    source_out = 100,
    fps_numerator = 24,
    fps_denominator = 1,
    mark_in = 0,
    mark_out = 0,
})
assert(clip16.mark_in == 0, "create: mark_in=0 not preserved")
assert(clip16.mark_out == 0, "create: mark_out=0 not preserved")
assert(clip16:save({skip_occlusion = true}))
local loaded16 = Clip.load("clip16")
assert(loaded16.mark_in == 0, "loaded mark_in=0 wrong: " .. tostring(loaded16.mark_in))
assert(loaded16.mark_out == 0, "loaded mark_out=0 wrong: " .. tostring(loaded16.mark_out))
print("  OK")

-- ======================================================================
-- Test 17: Clip.save rejects corrupted playhead_frame (set to nil after create)
-- ======================================================================
print("Test 17: save rejects nil playhead_frame...")
local clip17 = Clip.create("Corrupt PH", "media1", {
    id = "clip17",
    project_id = "proj",
    clip_kind = "master",
    track_id = "mc_v1",
    owner_sequence_id = "mc_seq",
    timeline_start = 1500,
    duration = 100,
    source_in = 0,
    source_out = 100,
    fps_numerator = 24,
    fps_denominator = 1,
})
assert(clip17:save({skip_occlusion = true}))
-- Now corrupt it
clip17.playhead_frame = nil
local ok17, err17 = pcall(clip17.save, clip17, {skip_occlusion = true})
assert(not ok17, "expected error for nil playhead_frame on save")
assert(tostring(err17):find("playhead_frame"), "error should mention playhead_frame: " .. tostring(err17))
print("  OK")

-- ======================================================================
-- Test 18: Clip.save rejects corrupted mark_in (set to string after create)
-- ======================================================================
print("Test 18: save rejects string mark_in...")
local clip18 = Clip.load("clip8")
assert(clip18, "load clip8 failed")
clip18.mark_in = "bad"
local ok18, err18 = pcall(clip18.save, clip18, {skip_occlusion = true})
assert(not ok18, "expected error for string mark_in on save")
assert(tostring(err18):find("mark_in"), "error should mention mark_in: " .. tostring(err18))
print("  OK")

print("✅ test_clip_marks.lua passed")
os.remove(DB_PATH)
