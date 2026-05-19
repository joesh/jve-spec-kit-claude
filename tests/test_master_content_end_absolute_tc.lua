#!/usr/bin/env luajit
--- Master sequence content-end must be in absolute TC frame space.
---
--- Domain contract: a master sequence's media_refs sit at
--- timeline_start_frame = file_tc_origin (TIMECODE-IS-TRUTH). For
--- playback, the engine treats start_frame = master.start_timecode_frame
--- (the TC origin) and total_frames = "absolute end frame in the same TC
--- space." `Sequence:compute_content_end()` is the canonical source of
--- that end frame.
---
--- Regression (2026-05-15): after `native_duration_for_medium` was
--- correctly changed to return a SPAN (not an absolute end), the master
--- branch of `compute_content_end` started returning the SPAN too,
--- because it delegates to `content_duration`. So for a master with
--- TC_ORIGIN=2036608 and duration=426 frames, playback bounds became
--- [2036608, 426) instead of [2036608, 2036608+426). The playhead lands
--- at 2036608, the boundary check `frame >= total_frames - 1` fires on
--- the very first tick, and Play immediately Stops — exactly the
--- "source tab won't play" symptom.
---
--- Contract: compute_content_end on a master with tc_origin=T,
--- duration=D must return T+D, not D.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
local test_env = require("test_env")

local database = require("core.database")
local Sequence = require("models.sequence")

print("=== test_master_content_end_absolute_tc.lua ===")

local DB = "/tmp/jve/test_master_content_end_absolute_tc.db"
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

local FPS       = 24
local DUR       = 426
local TC_ORIGIN = 2036608

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
local seq = Sequence.load(seq_id)
assert(seq, "loaded master sequence is nil")
assert(seq:is_master(), "expected master sequence")
assert(seq.start_timecode_frame == TC_ORIGIN, string.format(
    "master start_timecode_frame: got %s, expected %d",
    tostring(seq.start_timecode_frame), TC_ORIGIN))

local end_frame = seq:compute_content_end()
print(string.format("compute_content_end: got %d, expected %d (tc=%d + dur=%d)",
    end_frame, TC_ORIGIN + DUR, TC_ORIGIN, DUR))
assert(end_frame == TC_ORIGIN + DUR, string.format(
    "master compute_content_end must be absolute TC end (tc_origin + duration). "
    .. "Got %d, expected %d. With this regression, playback bounds collapse to "
    .. "[tc_origin, dur) which is empty when tc_origin > dur, so Play stops on "
    .. "the first tick.", end_frame, TC_ORIGIN + DUR))

print("✅ test_master_content_end_absolute_tc.lua passed")
