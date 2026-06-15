#!/usr/bin/env luajit
--- Regression: a media file with NO embedded source timecode (offline VFX
--- render, render-output .mov, etc.) must still yield a master source
--- sequence — placed at timecode origin 00:00:00:00 — instead of crashing
--- the whole project open.
---
--- Domain (NLE convention, Resolve/Premiere/FCP): a file that carries no
--- source-timecode track starts at 00:00:00:00. Its master therefore spans
--- [0 .. duration] in both video frames and audio samples. If the file is
--- later relinked/probed and a real TC appears, the relink TC-sync path
--- shifts the origin; nothing here depends on the file being on disk.
---
--- Before the fix, Sequence.ensure_master asserted "has no video TC origin"
--- (and, for media with audio, "has no audio TC origin") and aborted the
--- open — observed opening `anamnesis joe edit.drp`, whose timeline
--- references `A026_..._VFX_V3.mov` (a VFX render with no source TC).
require("test_env")

print("=== test_master_no_source_tc_origin_zero.lua ===")

local database = require("core.database")
local Sequence = require("models.sequence")

local TEST_DB = "/tmp/jve/test_master_no_source_tc_origin_zero.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
local project_id = "proj-no-tc"
local media_id = "media-vfx-render"

-- A 9.6s VFX render at 25 fps, 48 kHz stereo, with NO source TC in the
-- project file (metadata carries no start_tc_value / start_tc_audio_samples).
-- file_path points at a non-existent file so no probe can backfill TC.
local DURATION_FRAMES = 240          -- 9.6 s @ 25 fps
local SAMPLE_RATE     = 48000
local DURATION_SAMPLES = 460800      -- 9.6 s * 48000 Hz (domain math, not code)

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
    VALUES ('%s', 'No-TC Project', 'resample', %d, %d, '{}');

    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels,
        audio_sample_rate, codec, created_at, modified_at, metadata)
    VALUES ('%s', '%s', 'A026_VFX_V3.mov', '/tmp/does-not-exist-vfx.mov', %d,
        25, 1, 1920, 1080, 2, %d, 'prores', %d, %d, '{}');
]], project_id, now, now,
    media_id, project_id, DURATION_FRAMES, SAMPLE_RATE, now, now))

-- Must not crash.
local master_id = Sequence.ensure_master(media_id, project_id)
assert(master_id and master_id ~= "",
    "ensure_master must return a master id for no-TC media")

-- The master's declared TC origin is 00:00:00:00 in both unit systems.
local srow = db:prepare(
    "SELECT video_start_tc_frame, audio_start_tc_samples, start_timecode_frame "
    .. "FROM sequences WHERE id = ?")
srow:bind_value(1, master_id)
assert(srow:exec(), "sequence query exec failed")
assert(srow:next(), "master sequence row not found")
local v_origin = srow:value(0)
local a_origin = srow:value(1)
local start_tc = srow:value(2)
srow:finalize()
assert(v_origin == 0, string.format(
    "no-TC master video origin must be frame 0, got %s", tostring(v_origin)))
assert(a_origin == 0, string.format(
    "no-TC master audio origin must be sample 0, got %s", tostring(a_origin)))
assert(start_tc == 0, string.format(
    "no-TC master start timecode must be frame 0, got %s", tostring(start_tc)))

-- The video media_ref covers the whole file from frame 0.
local vref = db:prepare([[
    SELECT mr.source_in_frame, mr.source_out_frame, mr.sequence_start_frame
      FROM media_refs mr JOIN tracks t ON t.id = mr.track_id
     WHERE mr.owner_sequence_id = ? AND t.track_type = 'VIDEO'
]])
vref:bind_value(1, master_id)
assert(vref:exec(), "video media_ref query exec failed")
assert(vref:next(), "no video media_ref created for no-TC master")
local v_in, v_out, v_start = vref:value(0), vref:value(1), vref:value(2)
vref:finalize()
assert(v_in == 0 and v_out == DURATION_FRAMES and v_start == 0, string.format(
    "video media_ref must span [0..%d] at sequence_start 0; got in=%s out=%s start=%s",
    DURATION_FRAMES, tostring(v_in), tostring(v_out), tostring(v_start)))

-- Each audio media_ref covers the whole file from sample 0.
local aref = db:prepare([[
    SELECT mr.source_in_frame, mr.source_out_frame, mr.sequence_start_frame
      FROM media_refs mr JOIN tracks t ON t.id = mr.track_id
     WHERE mr.owner_sequence_id = ? AND t.track_type = 'AUDIO'
]])
aref:bind_value(1, master_id)
assert(aref:exec(), "audio media_ref query exec failed")
local audio_count = 0
while aref:next() do
    audio_count = audio_count + 1
    local a_in, a_out, a_start = aref:value(0), aref:value(1), aref:value(2)
    assert(a_in == 0 and a_out == DURATION_SAMPLES and a_start == 0, string.format(
        "audio media_ref must span [0..%d] samples at sequence_start 0; "
        .. "got in=%s out=%s start=%s",
        DURATION_SAMPLES, tostring(a_in), tostring(a_out), tostring(a_start)))
end
aref:finalize()
assert(audio_count == 2, string.format(
    "expected 2 audio media_refs (stereo), got %d", audio_count))

print("  ✓ no-TC media yields a master at origin 0 spanning the full file")
print("\n✅ test_master_no_source_tc_origin_zero.lua passed")
