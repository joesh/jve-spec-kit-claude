#!/usr/bin/env luajit

-- Regression: ConnectToResolveProject.load_jve_clips_for_sequence
-- returned 0 even when the sequence had clips, because the internal
-- load_clips_on_track did `db:prepare → bind_value → stmt:next()` and
-- skipped the `stmt:exec()` step. Every other query in the codebase
-- follows prepare → bind → exec → next; without exec, stmt:next() is
-- false-from-the-start and the iterator exits empty.
--
-- This test exercises the JVE-side loader end-to-end against a real
-- SQLite DB with a populated sequence (1 video track + 1 audio track,
-- one clip each) and asserts the loader sees the video clip and the
-- audio clip is surfaced via the V1-scope `audio_skipped` list (FR-024).
-- Black-box: makes no assumption about the internal SQL pattern; just
-- "given a sequence with N clips, the loader returns N video clips".

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database       = require("core.database")
local Clip           = require("models.clip")
local Media          = require("models.media")
local Sequence       = require("models.sequence")
local Track          = require("models.track")
local command_manager = require("core.command_manager")
local connect = require("core.commands.connect_to_resolve_project")
local dkjson = require("dkjson")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== ConnectToResolveProject.load_jve_clips_for_sequence Tests ===\n")

local db_path = "/tmp/jve/test_connect_load_clips.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'Test Project', 'resample',
        '{"master_clock_hz":192000,"default_fps":{"num":25,"den":1}}', %d, %d);
]], now, now))

local seq = Sequence.create("Test Seq", "p",
    { fps_numerator = 25, fps_denominator = 1 }, 1920, 1080,
    { audio_sample_rate = 48000, id = "seq", kind = "sequence" })
assert(seq:save(), "save sequence failed")

command_manager.init("seq", "p")

-- Master media + master sequence so clips reference a valid source.
local media = Media.create({
    id = "media",
    project_id = "p",
    file_path = "/tmp/jve/_placeholder.mov",
    name = "Placeholder",
    duration_frames = 10000,
    fps_numerator = 25,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 2,
    audio_sample_rate = 48000,
    metadata = dkjson.encode({
        start_tc_value = 0,
        start_tc_rate = 25,
        start_tc_audio_samples = 0,
        start_tc_audio_rate = 48000,
    }),
})
assert(media:save(), "save media failed")
local MC = Sequence.ensure_master("media", "p")

local v_track = Track.create_video("V1", "seq", { id = "vtrack", index = 1 })
assert(v_track:save(), "save video track failed")
local a_track = Track.create_audio("A1", "seq", { id = "atrack", index = 1 })
assert(a_track:save(), "save audio track failed")

-- Sequence-spanning clip with non-trivial source coords (so a future
-- "returns the wrong field" bug wouldn't sneak through with all-zero
-- placeholders).
local v_clip = Clip.create({
    name = "Vid Clip",
    id = "v_clip",
    project_id = "p",
    track_id = v_track.id,
    owner_sequence_id = "seq",
    sequence_id = MC,
    sequence_start_frame = 100,
    duration_frames = 250,
    source_in_frame = 4000,
    source_out_frame = 4250,
    enabled = true,
    fps_mismatch_policy = "resample",
    volume = 1.0,
    playhead_frame = 0,
})
assert(v_clip ~= nil, "create video clip failed")

local a_clip = Clip.create({
    name = "Aud Clip",
    id = "a_clip",
    project_id = "p",
    track_id = a_track.id,
    owner_sequence_id = "seq",
    sequence_id = MC,
    sequence_start_frame = 0,
    duration_frames = 100,
    source_in_frame = 0,
    source_out_frame = 100,
    source_in_subframe = 0,
    source_out_subframe = 0,
    enabled = true,
    fps_mismatch_policy = "resample",
    volume = 1.0,
    playhead_frame = 0,
})
assert(a_clip ~= nil, "create audio clip failed")

-- Sanity: the clips actually landed via the models.
do
    local sanity_track = Track.find_by_sequence("seq", "VIDEO")
    assert(#sanity_track == 1, "expected 1 video track, got " .. #sanity_track)
end

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

-- ── The regression: loader returns the populated video clip ────────
local video_clips, audio_skipped =
    connect.load_jve_clips_for_sequence("seq", db)

check("load returns one video clip (not 0 — exec-after-prepare bug)",
    #video_clips == 1)
check("video clip id preserved",
    video_clips[1] and video_clips[1].id == "v_clip")
check("video clip name preserved",
    video_clips[1] and video_clips[1].name == "Vid Clip")
check("video clip sequence_start preserved",
    video_clips[1] and video_clips[1].sequence_start == 100)
check("video clip source_in preserved",
    video_clips[1] and video_clips[1].source_in == 4000)
check("video clip source_out preserved",
    video_clips[1] and video_clips[1].source_out == 4250)
check("video clip wire track_type lowercase",
    video_clips[1] and video_clips[1].track_type == "video")
check("video clip track_index preserved",
    video_clips[1] and video_clips[1].track_index == 1)

-- ── V1 audio-skipped reporting (FR-024) ────────────────────────────
check("audio_skipped has the audio clip (V1 scope)",
    #audio_skipped == 1)
check("audio_skipped names the clip",
    audio_skipped[1] and audio_skipped[1].clip_id == "a_clip")
check("audio_skipped carries the structured reason",
    audio_skipped[1] and audio_skipped[1].reason == "audio_v1_unsupported")

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0,
    "test_connect_to_resolve_project_load_clips.lua: failures present")
print("✅ test_connect_to_resolve_project_load_clips.lua passed")
