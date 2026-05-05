-- Regression: FCP7 imports stills with <in> carrying timeline TC.
-- The TMB computes speed_ratio = (source_out - source_in) / duration;
-- with source_in=720000 that ratio blows out and every timeline frame
-- maps to a source_frame far past EOF → renders offline.
-- Correct: source_in=0, source_out=1 for any 1-frame still file.
-- The hold duration on the timeline is unchanged.

require("test_env")

local database = require("core.database")
local fcp7 = require("importers.fcp7_xml_importer")

local DB_PATH = "/tmp/jve/test_fcp7_still_source_clamp.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema init failed")
local db = database.get_connection()

db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('p1', 'test', 'passthrough', 0, 0);
]])

-- Minimal parsed_result: one sequence, one video track, one still clip.
-- source_in / source_out mirror what FCP7 writes when <in> carries
-- timeline TC (e.g. 30fps sequence at frame 720000 = hour 1, take 0).
-- media.duration = 1 identifies this as a 1-frame still file.
local TIMELINE_TC = 720000   -- frame 30000 * 24 fps = 1 hour in a 24fps seq
local HOLD_DURATION = 96     -- the still is held for 4 seconds

local parsed = {
    success = true,
    media_files = {},
    errors = {},
    sequences = {
        {
            original_id = "seq1",
            name = "Test Sequence",
            frame_rate = 24,
            audio_sample_rate = 48000,
            width = 1920,
            height = 1080,
            video_tracks = {
                {
                    original_id = "v1",
                    type = "VIDEO",
                    index = 1,
                    name = "V1",
                    enabled = true,
                    locked = false,
                    clips = {
                        {
                            name = "frame.jpg",
                            original_id = "clip1",
                            start_value   = 0,
                            duration      = HOLD_DURATION,
                            source_in     = TIMELINE_TC,
                            source_out    = TIMELINE_TC + HOLD_DURATION,
                            frame_rate    = 24,
                            media_key     = "still-key",
                            media = {
                                key             = "still-key",
                                name            = "frame.jpg",
                                path            = "/tmp/frame.jpg",
                                duration        = 1,    -- 1-frame still file
                                frame_rate      = 24,
                                width           = 1920,
                                height          = 1080,
                                audio_channels  = 0,
                                audio_sample_rate = nil,
                                codec           = "jpeg",
                            },
                        },
                    },
                },
            },
            audio_tracks = {},
        },
    },
}

print("-- FCP7 still clip with timeline TC in source_in --")
local result = fcp7.create_entities(parsed, db, "p1")
assert(result.success, "create_entities failed: " .. tostring(result.error))
assert(#result.clip_ids == 1, "expected 1 clip, got " .. tostring(#result.clip_ids))

local clip_id = result.clip_ids[1]
local stmt = db:prepare(
    "SELECT source_in_frame, source_out_frame, duration_frames FROM clips WHERE id = ?")
stmt:bind_value(1, clip_id)
assert(stmt:exec() and stmt:next(), "clip not found: " .. tostring(clip_id))
local src_in  = stmt:value(0)
local src_out = stmt:value(1)
local dur     = stmt:value(2)
stmt:finalize()

assert(src_in == 0, string.format(
    "still source_in must be clamped to 0; got %d (raw FCP7 TC was %d)",
    src_in, TIMELINE_TC))
assert(src_out == 1, string.format(
    "still source_out must be clamped to 1; got %d", src_out))
assert(dur == HOLD_DURATION, string.format(
    "still hold duration must be unchanged at %d; got %d", HOLD_DURATION, dur))
print(string.format("  ok  source=[%d,%d)  hold=%d frames", src_in, src_out, dur))

-- Non-still clips (duration > 1) must NOT be clamped.
print("-- Non-still clip preserves source window --")
local parsed2 = {
    success = true,
    media_files = {},
    errors = {},
    sequences = {
        {
            original_id = "seq2",
            name = "Video Seq",
            frame_rate = 24,
            audio_sample_rate = 48000,
            width = 1920,
            height = 1080,
            video_tracks = {
                {
                    original_id = "v2",
                    type = "VIDEO",
                    index = 1,
                    name = "V1",
                    enabled = true,
                    locked = false,
                    clips = {
                        {
                            name       = "clip.mov",
                            original_id = "clip2",
                            start_value = 0,
                            duration    = 100,
                            source_in   = 50,    -- legitimate file-relative start
                            source_out  = 150,
                            frame_rate  = 24,
                            media_key   = "vid-key",
                            media = {
                                key           = "vid-key",
                                name          = "clip.mov",
                                path          = "/tmp/clip.mov",
                                duration      = 500,  -- multi-frame video
                                frame_rate    = 24,
                                width         = 1920,
                                height        = 1080,
                                audio_channels = 0,
                                codec         = "h264",
                            },
                        },
                    },
                },
            },
            audio_tracks = {},
        },
    },
}
local result2 = fcp7.create_entities(parsed2, db, "p1")
assert(result2.success, "create_entities (video) failed: " .. tostring(result2.error))
local clip_id2 = result2.clip_ids[1]
local stmt2 = db:prepare(
    "SELECT source_in_frame, source_out_frame FROM clips WHERE id = ?")
stmt2:bind_value(1, clip_id2)
assert(stmt2:exec() and stmt2:next(), "video clip not found")
local vi = stmt2:value(0)
local vo = stmt2:value(1)
stmt2:finalize()
assert(vi == 50 and vo == 150, string.format(
    "video clip source must be unchanged [50,150); got [%d,%d)", vi, vo))
print(string.format("  ok  source=[%d,%d)", vi, vo))

print("✅ test_fcp7_still_source_clamp.lua passed")
