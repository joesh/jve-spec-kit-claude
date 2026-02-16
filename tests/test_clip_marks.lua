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

print("✅ test_clip_marks.lua passed")
os.remove(DB_PATH)
