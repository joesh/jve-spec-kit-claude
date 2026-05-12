#!/usr/bin/env luajit

-- Sequence.native_duration_for_medium must return a DURATION (length),
-- not an absolute end-of-timeline frame. For a master sequence whose
-- media_refs sit at timeline_start_frame = file_tc_origin (per the
-- TIMECODE-IS-TRUTH memory), the bug is:
--
--   SELECT MAX(timeline_start_frame + duration_frames) FROM media_refs
--
-- returns tc_origin + duration_frames. Callers (Overwrite via
-- place_shared.apply_nested_marks → compute_owner_duration) treat the
-- result as a duration, multiplying by the resample ratio and producing
-- clips that are off by ~tc_origin frames.
--
-- The result is the source-of-truth for "how long is this master's
-- VIDEO/AUDIO content" — must be expressed as a duration, i.e.
-- MAX(end) - MIN(start), or equivalently SUM(duration) for the
-- non-overlapping master case.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
local test_env = require("test_env")

local database = require("core.database")
local Sequence = require("models.sequence")

print("=== test_native_duration_returns_span.lua ===")

local DB = "/tmp/jve/test_native_duration_returns_span.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'Test', 'resample', %d, %d);
]], now, now))

-- 24fps source media, 100 frames, with a large TC origin like a real
-- on-set capture. 13:52:29:07 @ 24fps = 1,198,783 frames.
local FPS = 24
local DUR = 100
local TC_ORIGIN = (13*3600 + 52*60 + 29) * FPS + 7

test_env.create_test_media({
    id = "media1",
    project_id = "proj",
    file_path = "/tmp/jve/x.mov",
    name = "X",
    duration_frames = DUR,
    fps_numerator = FPS,
    fps_denominator = 1,
    audio_channels = 2,
    audio_sample_rate = 48000,
    width = 1920,
    height = 1080,
    start_tc = TC_ORIGIN,
})

local seq_id = Sequence.ensure_master("media1", "proj")

local v = Sequence.native_duration_for_medium(seq_id, "VIDEO")
print(string.format("native_duration_for_medium VIDEO: got %d, expected %d", v, DUR))
assert(v == DUR, string.format(
    "VIDEO duration: got %d, expected %d (off by %d ≈ tc_origin %d — "
    .. "MAX(end) is being returned instead of span)",
    v, DUR, v - DUR, TC_ORIGIN))

local a = Sequence.native_duration_for_medium(seq_id, "AUDIO")
-- Audio is in samples: 100 frames @ 24fps × 48000/24 = 200_000 samples.
local EXPECT_A = DUR * 48000 / FPS
print(string.format("native_duration_for_medium AUDIO: got %d, expected %d", a, EXPECT_A))
assert(a == EXPECT_A, string.format(
    "AUDIO duration: got %d, expected %d", a, EXPECT_A))

print("✅ test_native_duration_returns_span.lua passed")
