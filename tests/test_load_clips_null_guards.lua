-- Regression: load_clips must reject clips with NULL/missing required fields.
-- Originally discovered via debug scripts — NULL timeline_start caused downstream
-- arithmetic failures.
--
-- Two defense layers:
-- 1. Schema NOT NULL constraints reject NULLs at INSERT time
-- 2. load_clips() asserts on missing values (belt-and-suspenders)
--
-- This test verifies BOTH layers, plus roundtrip integrity for non-trivial values.

require("test_env")

local database = require("core.database")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

local function expect_error(label, fn, pattern)
    local ok, err = pcall(fn)
    if not ok then
        if pattern and not tostring(err):match(pattern) then
            fail_count = fail_count + 1
            print("FAIL (wrong error): " .. label .. " got: " .. tostring(err))
        else
            pass_count = pass_count + 1
        end
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
    end
end

-- Set up database
local db_path = "/tmp/jve/test_load_clips_null_guards.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

local now = os.time()

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj1', 'Test', 'resample', %d, %d);
]], now, now))

db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'nested', 25, 1, 48000, 1920, 1080,
        0, 250, 0, '[]', '[]', '[]', 0, %d, %d);
]], now, now))

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

print("\n=== load_clips NULL Guard Tests ===")

-- ── Layer 1: Schema-level NOT NULL constraints ──

-- Schema rejects NULL timeline_start_frame
local ok_ts = db:exec([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        enabled, offline, fps_numerator, fps_denominator, created_at, modified_at)
    VALUES ('null_ts', 'proj1', 'clip', 'Test', 'v1', 'seq1',
        NULL, 50, 100, 150, 1, 0, 25, 1, 0, 0);
]])
check("schema rejects NULL timeline_start", ok_ts ~= 0)

-- Schema rejects NULL duration_frames
local ok_dur = db:exec([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        enabled, offline, fps_numerator, fps_denominator, created_at, modified_at)
    VALUES ('null_dur', 'proj1', 'clip', 'Test', 'v1', 'seq1',
        100, NULL, 100, 150, 1, 0, 25, 1, 0, 0);
]])
check("schema rejects NULL duration", ok_dur ~= 0)

-- Schema rejects NULL source_in_frame
local ok_si = db:exec([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        enabled, offline, fps_numerator, fps_denominator, created_at, modified_at)
    VALUES ('null_si', 'proj1', 'clip', 'Test', 'v1', 'seq1',
        100, 50, NULL, 150, 1, 0, 25, 1, 0, 0);
]])
check("schema rejects NULL source_in", ok_si ~= 0)

-- Schema rejects NULL source_out_frame
local ok_so = db:exec([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        enabled, offline, fps_numerator, fps_denominator, created_at, modified_at)
    VALUES ('null_so', 'proj1', 'clip', 'Test', 'v1', 'seq1',
        100, 50, 100, NULL, 1, 0, 25, 1, 0, 0);
]])
check("schema rejects NULL source_out", ok_so ~= 0)

-- Schema rejects zero duration (CHECK constraint)
local ok_zero = db:exec([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        enabled, offline, fps_numerator, fps_denominator, created_at, modified_at)
    VALUES ('zero_dur', 'proj1', 'clip', 'Test', 'v1', 'seq1',
        100, 0, 100, 150, 1, 0, 25, 1, 0, 0);
]])
check("schema rejects duration=0", ok_zero ~= 0)

-- ── Layer 2: load_clips API-level guards ──

-- load_clips with nil sequence_id rejected
expect_error("nil sequence_id",
    function() database.load_clips(nil) end,
    "requires sequence_id")

-- ── Schema rejects NULL project_id ──
local ok_proj = db:exec([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        enabled, offline, fps_numerator, fps_denominator, created_at, modified_at)
    VALUES ('null_proj', NULL, 'clip', 'Test', 'v1', 'seq1',
        200, 50, 100, 150, 1, 0, 25, 1, 0, 0);
]])
check("schema rejects NULL project_id", ok_proj ~= 0)

-- ── Roundtrip: non-trivial integer values survive load_clips ──
-- Values from real DRP import: 25fps timeline, source coords in absolute TC
db:exec([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        enabled, offline, fps_numerator, fps_denominator, created_at, modified_at)
    VALUES ('precise', 'proj1', 'clip', 'Precise', 'v1', 'seq1',
        89849, 12345, 188160, 200505, 1, 0, 25, 1, 0, 0);
]])
local clips = database.load_clips("seq1")
check("roundtrip count=1", #clips == 1)
check("roundtrip timeline_start=89849", clips[1].timeline_start == 89849)
check("roundtrip duration=12345", clips[1].duration == 12345)
check("roundtrip source_in=188160", clips[1].source_in == 188160)
check("roundtrip source_out=200505", clips[1].source_out == 200505)
check("roundtrip enabled=true", clips[1].enabled == true)
check("roundtrip rate.fps_numerator=25", clips[1].rate.fps_numerator == 25)
check("roundtrip rate.fps_denominator=1", clips[1].rate.fps_denominator == 1)
db:exec("DELETE FROM clips")

-- ── Boundary: negative timeline_start (valid — pre-roll) ──
db:exec([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        enabled, offline, fps_numerator, fps_denominator, created_at, modified_at)
    VALUES ('neg_start', 'proj1', 'clip', 'PreRoll', 'v1', 'seq1',
        -100, 200, 0, 200, 1, 0, 24, 1, 0, 0);
]])
clips = database.load_clips("seq1")
check("negative timeline_start loads", #clips == 1)
check("negative timeline_start=-100", clips[1].timeline_start == -100)
db:exec("DELETE FROM clips")

-- ── Timestamp roundtrip (verify index shift didn't break created_at/modified_at) ──
db:exec("DELETE FROM clips")
db:exec([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        enabled, offline, fps_numerator, fps_denominator, created_at, modified_at)
    VALUES ('ts_clip', 'proj1', 'clip', 'Timestamps', 'v1', 'seq1',
        0, 100, 0, 100, 1, 0, 24, 1, 1700000000, 1700000100);
]])
clips = database.load_clips("seq1")
check("timestamp count=1", #clips == 1)
check("created_at preserved", clips[1].created_at == 1700000000)
check("modified_at preserved", clips[1].modified_at == 1700000100)
db:exec("DELETE FROM clips")

-- ── Boundary: large values (near 32-bit limit, hours of content) ──
-- 86400 frames @ 24fps = 1 hour; 8640000 = 100 hours
db:exec([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        enabled, offline, fps_numerator, fps_denominator, created_at, modified_at)
    VALUES ('big', 'proj1', 'clip', 'LongForm', 'v1', 'seq1',
        8640000, 2160000, 8640000, 10800000, 1, 0, 24, 1, 0, 0);
]])
clips = database.load_clips("seq1")
check("large values load", #clips == 1)
check("large timeline_start=8640000", clips[1].timeline_start == 8640000)
check("large duration=2160000", clips[1].duration == 2160000)
check("large source_out=10800000", clips[1].source_out == 10800000)

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("✅ test_load_clips_null_guards.lua passed")
