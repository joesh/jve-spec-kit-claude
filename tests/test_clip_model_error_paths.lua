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
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test Project', %d, %d);
]], now, now))

db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator,
                           audio_rate, width, height, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Test Seq', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now))

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track1', 'seq1', 'V1', 'VIDEO', 1, 1);
]])

db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
                       fps_numerator, fps_denominator, width, height, created_at, modified_at)
    VALUES ('media1', 'proj1', 'Test', '/tmp/test.mp4', 1000, 24, 1, 1920, 1080, %d, %d);
]], now, now))

-- ============================================================================
-- create(): Required fps fields
-- ============================================================================

print("\n--- create: required fps fields ---")

expect_error("missing fps_numerator", function()
    Clip.create("TestClip", "media1", {
        id = "test_clip",
        project_id = "proj1",
        clip_kind = "timeline",
        timeline_start = 0,
        duration = 100,
        fps_denominator = 1,
    })
end, "fps_numerator")

expect_error("missing fps_denominator", function()
    Clip.create("TestClip", "media1", {
        id = "test_clip",
        project_id = "proj1",
        clip_kind = "timeline",
        timeline_start = 0,
        duration = 100,
        fps_numerator = 24,
    })
end, "fps_denominator")

-- ============================================================================
-- create(): Valid integer coordinates work
-- ============================================================================

print("\n--- create: valid integer coordinates ---")

local clip = Clip.create("ValidClip", "media1", {
    id = "valid_clip_1",
    project_id = "proj1",
    clip_kind = "timeline",
    track_id = "track1",
    timeline_start = 0,
    duration = 100,
    source_in = 0,
    source_out = 100,
    fps_numerator = 24,
    fps_denominator = 1,
})
check("create with integers succeeds", clip ~= nil)
check("timeline_start is integer", type(clip.timeline_start) == "number")
check("timeline_start value is 0", clip.timeline_start == 0)
check("duration is integer", type(clip.duration) == "number")
check("duration value is 100", clip.duration == 100)

-- ============================================================================
-- save(): Integer validation
-- ============================================================================

print("\n--- save: integer validation ---")

local bad_clip = Clip.create("BadClip", "media1", {
    id = "bad_clip_1",
    project_id = "proj1",
    clip_kind = "timeline",
    track_id = "track1",
    timeline_start = 0,
    duration = 100,
    source_in = 0,
    source_out = 100,
    fps_numerator = 24,
    fps_denominator = 1,
})

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

-- First save a valid clip via raw SQL
db:exec(string.format([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id,
                       timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                       fps_numerator, fps_denominator, enabled, created_at, modified_at)
    VALUES ('load_test_1', 'proj1', 'timeline', 'LoadTest', 'track1', 'media1',
            100, 50, 10, 60, 24, 1, 1, %d, %d);
]], now, now))

local loaded = Clip.load("load_test_1", db)
check("load returns clip", loaded ~= nil)
check("loaded timeline_start is integer", type(loaded.timeline_start) == "number")
check("loaded timeline_start value", loaded.timeline_start == 100)
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
