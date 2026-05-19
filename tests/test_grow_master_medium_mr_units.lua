#!/usr/bin/env luajit
--- GrowMasterMedium writes the new audio media_ref in the unified
--- placement-unit convention (master.fps frames), not raw audio samples.
---
--- Domain contract (CLAUDE.md feedback_timecode_is_truth, post-unification):
---   For a V+A master (master.fps == video.fps):
---     A MR.sequence_start_frame / .duration_frames are in master.fps
---     frames — for V+A that means video-frame count, NOT samples.
---     source_in_frame / source_out_frame stay in file-natural samples.
---   Pre-unification convention stored A MR placement in samples, which
---   for a 1000-frame master @ 24fps × 48kHz produces duration_frames =
---   2,000,000 — 2000× the correct V-frame extent. The src-tab body
---   then renders that as a 2_000_000-frame-long audio strip, off-screen
---   from the visible ruler position (TSO 2026-05-16 symptom: empty
---   audio lanes on src tab).
---
--- This test grows a V-only master by adding audio and asserts the new
--- master A media_ref carries V-frame placement, sample source range.

require("test_env")

print("=== test_grow_master_medium_mr_units.lua ===")

local database = require("core.database")
local GrowMasterMedium = require("core.commands.grow_master_medium")

local TEST_DB = "/tmp/jve/test_grow_master_medium_mr_units.db"
os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(TEST_DB), "schema init failed")
local db = database.get_connection()

-- Non-trivial durations: 1000 V frames @ 24fps == 2,000,000 audio samples
-- at 48kHz. The 2000× spread between the two units makes the bug
-- numerically obvious.
local V_DUR_FRAMES = 1000
local SR, FPS      = 48000, 24
local A_DUR_SAMPLES = V_DUR_FRAMES * SR / FPS  -- 2_000_000

assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('p1', 'p', 'resample', 0, 0);
    -- 018 FR-004: masters carry NULL audio_sample_rate (per-media_ref rate).
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        created_at, modified_at)
    VALUES ('m', 'p1', 'master', 'master', %d, 1, NULL, 1920, 1080, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
    VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1);
    UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_channels,
        created_at, modified_at)
    VALUES ('vid', 'p1', 'v.mov', '/tmp/v.mov', %d, %d, 1, 0, 0, 0),
           ('aud', 'p1', 'a.wav', '/tmp/a.wav', %d, %d, 1, 1, 0, 0);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr-v', 'p1', 'm', 'm-v1', 'vid', 0, %d, 0, %d, 1, 1.0, 0, 0, 0);
]], FPS, V_DUR_FRAMES, FPS, A_DUR_SAMPLES, SR,
    V_DUR_FRAMES, V_DUR_FRAMES)))

local result = GrowMasterMedium.execute({
    sequence_id = "m",
    medium      = "audio",
    track_spec  = { media_id = "aud", sample_rate = SR },
})
assert(result and result.new_media_ref_id, "GrowMasterMedium must return new MR id")

-- Inspect the newly-created master audio media_ref.
local stmt = db:prepare([[
    SELECT sequence_start_frame, duration_frames,
           source_in_frame, source_out_frame
    FROM media_refs WHERE id = ?
]])
stmt:bind_value(1, result.new_media_ref_id)
assert(stmt:exec() and stmt:next())
local ts   = stmt:value(0)
local dur  = stmt:value(1)
local sin  = stmt:value(2)
local sout = stmt:value(3)
stmt:finalize()

-- Master starts at TC 0, so timeline_start = 0 either way (master.fps
-- frames or samples both compute to 0). The diagnostic bug is the
-- duration_frames: pre-fix stored A_DUR_SAMPLES (= 2_000_000), post-fix
-- stores V_DUR_FRAMES (= 1000) which is the canonical master.fps unit.
assert(dur == V_DUR_FRAMES, string.format(
    "audio MR.duration_frames: expected %d (master.fps frames == video "
    .. "frames for V+A master), got %d. Writing %d (samples) is the "
    .. "pre-unification overload that makes the src-tab audio lane "
    .. "appear empty / 2000× off-screen.",
    V_DUR_FRAMES, dur, A_DUR_SAMPLES))
assert(ts == 0,
    "audio MR.sequence_start_frame should be 0 for a TC=0 master")
assert(sin == 0,
    "audio MR.source_in_frame: file starts at sample 0 (no audio TC)")
assert(sout == A_DUR_SAMPLES, string.format(
    "audio MR.source_out_frame (file-natural samples): expected %d, got %d",
    A_DUR_SAMPLES, sout))

print(string.format("  ✓ A MR: ts=%d dur=%d (V frames) src=[%d,%d) (samples)",
    ts, dur, sin, sout))
print("✅ test_grow_master_medium_mr_units.lua passed")
