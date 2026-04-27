require("test_env")

local database = require("core.database")
local Clip = require("models.clip")

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
    return err
end

print("\n=== Clip Model Error Paths Tests (Integer Architecture) ===")

-- Set up database
local db_path = "/tmp/jve/test_clip_model_error_paths.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

local now = os.time()

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj1', 'Test Project', 'resample', %d, %d);
]], now, now))

db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
                           audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Test Seq', 'nested', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now))

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track1', 'seq1', 'V1', 'VIDEO', 1, 1);
]])

db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
                       fps_numerator, fps_denominator, width, height, created_at, modified_at, metadata)
    VALUES ('media1', 'proj1', 'Test', '/tmp/test.mp4', 1000, 24, 1, 1920, 1080, %d, %d,
            '{"start_tc_value":0,"start_tc_rate":24}');
]], now, now))

-- V13: build a master sequence wrapping media1 so clips can reference it.
local Sequence = require("models.sequence")
Sequence.ensure_master("media1", "proj1", { id = "mc1" })

-- ============================================================================
-- create(): Required fps fields
-- ============================================================================

print("\n--- create: required fps fields ---")

-- V13 schema dropped fps_numerator/fps_denominator/media_id from clips —
-- the clip's source-side timebase is read from its nested sequence; media
-- comes via the master sequence's media_ref. The pre-013 "missing fps"
-- and "missing media_id auto-resolve master_clip_id" error paths are
-- therefore no longer applicable. Coverage moved to nested_sequence_id +
-- INV-2 / INV-4 model assertions.

-- ============================================================================
-- create(): Timeline clips require track_id, owner_sequence_id, etc.
-- ============================================================================

print("\n--- create: timeline clip required fields ---")

expect_error("timeline clip missing track_id", function()
    Clip.create({
        name = "TestClip",
        project_id = "proj1",
        nested_sequence_id = "mc1",
        owner_sequence_id = "seq1",
        timeline_start_frame = 0,
        duration_frames = 100,
        source_in_frame = 0,
        source_out_frame = 100,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
        enabled = 1,
    })
end, "track_id")

expect_error("timeline clip missing owner_sequence_id", function()
    Clip.create({
        name = "TestClip",
        project_id = "proj1",
        track_id = "track1",
        nested_sequence_id = "mc1",
        timeline_start_frame = 0,
        duration_frames = 100,
        source_in_frame = 0,
        source_out_frame = 100,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
        enabled = 1,
    })
end, "owner_sequence_id")

-- V13: master clips no longer exist (master sequences hold media_refs, not
-- stream clips). The pre-013 "master clip without master_clip_id" path is
-- gone; that scenario is now Sequence.ensure_master + media_ref insert.

-- ============================================================================
-- create(): Valid integer coordinates work
-- ============================================================================

print("\n--- create: valid integer coordinates ---")

local valid_id = Clip.create({
        name = "ValidClip",
        id = "valid_clip_1",
        project_id = "proj1",
        track_id = "track1",
        nested_sequence_id = "mc1",
        owner_sequence_id = "seq1",
        timeline_start_frame = 0,
        duration_frames = 100,
        source_in_frame = 0,
        source_out_frame = 100,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
        enabled = 1,
    })
local clip = Clip.load(valid_id)
check("create with integers succeeds", clip ~= nil)
check("timeline_start is integer", type(clip.timeline_start) == "number")
check("timeline_start value is 0", clip.timeline_start == 0)
check("duration is integer", type(clip.duration) == "number")
check("duration value is 100", clip.duration == 100)

-- ============================================================================
-- save(): Integer validation
-- ============================================================================

print("\n--- save: integer validation ---")

local bad_clip_id = Clip.create({
        name = "BadClip",
        id = "bad_clip_1",
        project_id = "proj1",
        track_id = "track1",
        nested_sequence_id = "mc1",
        owner_sequence_id = "seq1",
        timeline_start_frame = 200,
        duration_frames = 100,
        source_in_frame = 0,
        source_out_frame = 100,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
        enabled = 1,
    })

local bad_clip = Clip.load(bad_clip_id)

-- Corrupt the clip by setting a table value
bad_clip.timeline_start = { frames = 50 }
expect_error("save with table timeline_start asserts", function()
    bad_clip:save(db)
end, "must be integer")

-- Fix it and try again
bad_clip.timeline_start = 50
bad_clip.duration = { frames = 100 }
expect_error("save with table duration asserts", function()
    bad_clip:save(db)
end, "must be integer")

-- ============================================================================
-- load(): Returns integers
-- ============================================================================

print("\n--- load: returns integers ---")

-- First save a valid clip via raw SQL (mc1 master sequence already exists from earlier ensure_master)
db:exec(string.format([[
INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id, nested_sequence_id,
                    timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                    enabled, created_at, modified_at,
                    master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
                    volume, playhead_frame)
VALUES
    ('load_test_1', 'proj1', 'LoadTest', 'track1', 'seq1', 'mc1',
     500, 50, 10, 60, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now))

local loaded = Clip.load("load_test_1", db)
check("load returns clip", loaded ~= nil)
check("loaded timeline_start is integer", type(loaded.timeline_start) == "number")
check("loaded timeline_start value", loaded.timeline_start == 500)
check("loaded duration is integer", type(loaded.duration) == "number")
check("loaded duration value", loaded.duration == 50)
check("loaded source_in is integer", type(loaded.source_in) == "number")
check("loaded source_in value", loaded.source_in == 10)
check("loaded source_out is integer", type(loaded.source_out) == "number")
check("loaded source_out value", loaded.source_out == 60)

-- ============================================================================
-- Summary
-- ============================================================================

print("\n--- Summary ---")
if fail_count > 0 then
    print(string.format("❌ test_clip_model_error_paths.lua: %d passed, %d FAILED", pass_count, fail_count))
    os.exit(1)
end
print(string.format("✅ test_clip_model_error_paths.lua passed (%d assertions)", pass_count))
