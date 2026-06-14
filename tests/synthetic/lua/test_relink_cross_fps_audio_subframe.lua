#!/usr/bin/env luajit
-- Relinking an audio clip to a source whose master has a DIFFERENT fps must
-- preserve the clip's audio content position — not crash, and not move the audio.
--
-- Domain: an audio clip's source position is an absolute offset in the project's
-- master clock (ticks), encoded as (source_in_frame in the master's fps timebase,
-- source_in_subframe = leftover ticks, 0 <= subframe < ticks_per_frame). Ticks-per-
-- frame depends on the MASTER's fps. Relinking points the clip at a different
-- media whose master may run at a different fps, which changes ticks_per_frame —
-- so a subframe valid under the old fps can exceed the new fps's frame size. The
-- schema enforces 0 <= subframe < ticks_per_frame (trg_clips_subframe_bound_update),
-- so the rebind aborts. The fix must re-express the SAME absolute tick position
-- under the new fps (recompute frame + subframe), leaving the audio where it was.
--
-- Master clock 705600000 Hz: ticks_per_frame = 29 400 000 @24fps, 28 224 000 @25fps.
-- A subframe of 29 000 000 is legal @24 but >= 28 224 000, illegal @25.

require("test_env")
print("=== test_relink_cross_fps_audio_subframe.lua ===")

local database     = require("core.database")
local Clip         = require("models.clip")
local Sequence     = require("models.sequence")
local subframe_math = require("core.subframe_math")
local json         = require("dkjson")

local MCH   = subframe_math.MASTER_CLOCK_HZ          -- 705600000
local TPF24 = subframe_math.ticks_per_frame(MCH, 24, 1)  -- 29 400 000
local TPF25 = subframe_math.ticks_per_frame(MCH, 25, 1)  -- 28 224 000
local SUB   = 29000000  -- valid @24 (< TPF24), illegal @25 (>= TPF25)
assert(SUB < TPF24 and SUB >= TPF25, "fixture math: subframe must straddle the fps boundary")

local DB = "/tmp/jve/test_relink_cross_fps_audio_subframe.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format(
    "INSERT INTO projects (id, name, settings, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p', 'X', '%s', 'resample', %d, %d)",
    (string.format('{"master_clock_hz":%d,"default_fps":{"num":24,"den":1}}', MCH)):gsub("'", "''"),
    now, now))

-- Two audio media at DIFFERENT fps. TC in metadata → ensure_master needs no probe.
local function make_audio_media(id, fps_num)
    local meta = json.encode({ start_tc_audio_samples = 0, start_tc_audio_rate = 48000 })
    db:exec(string.format(
        "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
        .. "fps_numerator, fps_denominator, audio_channels, audio_sample_rate, "
        .. "width, height, metadata, created_at, modified_at) VALUES "
        .. "('%s','p','%s.wav','/tmp/%s.wav', 1000, %d, 1, 2, 48000, 0, 0, '%s', %d, %d)",
        id, id, id, fps_num, meta:gsub("'", "''"), now, now))
end
make_audio_media("mediaA", 24)
make_audio_media("mediaB", 25)

-- Master for A (fps 24); clip will reference it. B's master is created on relink.
local masterA = Sequence.ensure_master("mediaA", "p")
assert(masterA, "ensure_master(mediaA) failed")

-- Timeline + audio track holding the clip.
db:exec("INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, playhead_frame, view_start_frame, view_duration_frames, "
    .. "start_timecode_frame, created_at, modified_at) VALUES "
    .. "('tl','p','TL','sequence',24,1,48000,1920,1080,0,0,300,0," .. now .. "," .. now .. ")")
db:exec("INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) "
    .. "VALUES ('a1','tl','A1','AUDIO',1,1)")

assert(Clip.create({
    id = "clip1", name = "aud", project_id = "p",
    track_id = "a1", owner_sequence_id = "tl", sequence_id = masterA,
    sequence_start_frame = 0, duration_frames = 100,
    source_in_frame = 100, source_out_frame = 200,
    source_in_subframe = SUB, source_out_subframe = SUB,
    volume = 1.0, playhead_frame = 0, enabled = 1,
    fps_mismatch_policy = "resample",
}))

-- Absolute tick position of the in-point BEFORE relink (audio content position).
local before = Clip.load("clip1")
local abs_in_before  = subframe_math.pack(before.source_in,  before.source_in_subframe,  TPF24)
local abs_out_before = subframe_math.pack(before.source_out, before.source_out_subframe, TPF24)

-- Relink clip to mediaB (fps-25 master). batch_update_source rebinds sequence_id.
Clip.batch_update_source({
    clip1 = { media_id = "mediaB", source_in = before.source_in, source_out = before.source_out },
})

-- After relink: the clip points at mediaB's master, and its absolute audio
-- position is UNCHANGED (relink doesn't move audio). Re-express under fps-25.
local after = Clip.load("clip1")
assert(after.source_in_subframe ~= nil, "audio clip must keep non-NULL subframe after relink")
assert(after.source_in_subframe < TPF25 and after.source_in_subframe >= 0,
    string.format("source_in_subframe must be re-expressed valid under fps-25 (< %d), got %d",
        TPF25, after.source_in_subframe))

local abs_in_after  = subframe_math.pack(after.source_in,  after.source_in_subframe,  TPF25)
local abs_out_after = subframe_math.pack(after.source_out, after.source_out_subframe, TPF25)
assert(abs_in_after == abs_in_before, string.format(
    "relink must preserve the absolute audio in-position: before=%d after=%d",
    abs_in_before, abs_in_after))
assert(abs_out_after == abs_out_before, string.format(
    "relink must preserve the absolute audio out-position: before=%d after=%d",
    abs_out_before, abs_out_after))

print("✅ test_relink_cross_fps_audio_subframe.lua passed")
