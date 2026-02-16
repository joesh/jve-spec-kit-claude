require("test_env")

local database = require("core.database")
local Sequence = require("models.sequence")
local Media = require("models.media")
local Track = require("models.track")
local Clip = require("models.clip")

local pass_count = 0
local fail_count = 0

local function check(label, condition, detail)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label .. (detail and (" — " .. detail) or ""))
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

print("\n=== ensure_masterclip Tests (NSF Compliance) ===")

-- Set up database
local db_path = "/tmp/jve/test_ensure_masterclip.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

local now = os.time()

-- Create project
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test Project', %d, %d);
]], now, now))

--------------------------------------------------------------------------------
-- Error paths (ensure_masterclip input validation)
--------------------------------------------------------------------------------

print("\n--- ensure_masterclip: input validation ---")

expect_error("nil media_id asserts", function()
    Sequence.ensure_masterclip(nil, "proj1")
end, "media_id is required")

expect_error("empty media_id asserts", function()
    Sequence.ensure_masterclip("", "proj1")
end, "media_id is required")

expect_error("nil project_id asserts", function()
    Sequence.ensure_masterclip("some_media", nil)
end, "project_id is required")

expect_error("empty project_id asserts", function()
    Sequence.ensure_masterclip("some_media", "")
end, "project_id is required")

expect_error("nonexistent media_id asserts", function()
    Sequence.ensure_masterclip("nonexistent_media_id", "proj1")
end, "Media record not found")

--------------------------------------------------------------------------------
-- Happy path: video+audio media
--------------------------------------------------------------------------------

print("\n--- ensure_masterclip: video+audio media ---")

local media_va = Media.create({
    id = "media_va",
    project_id = "proj1",
    name = "VideoAudio",
    file_path = "synthetic://video_audio.mov",
    duration_frames = 240,
    fps_numerator = 24,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 2,
    codec = "prores",
})
assert(media_va:save(), "Failed to save video+audio media")

local mc_id = Sequence.ensure_masterclip("media_va", "proj1")
check("returns non-nil ID", mc_id ~= nil)
check("returns string ID", type(mc_id) == "string")

-- Verify sequence structure
local mc_seq = Sequence.load(mc_id)
check("masterclip sequence exists", mc_seq ~= nil)
check("kind is masterclip", mc_seq.kind == "masterclip",
    "got: " .. tostring(mc_seq and mc_seq.kind))
check("name matches media", mc_seq.name == "VideoAudio",
    "got: " .. tostring(mc_seq and mc_seq.name))
check("fps matches media",
    mc_seq.frame_rate.fps_numerator == 24 and mc_seq.frame_rate.fps_denominator == 1,
    string.format("got: %s/%s",
        tostring(mc_seq.frame_rate and mc_seq.frame_rate.fps_numerator),
        tostring(mc_seq.frame_rate and mc_seq.frame_rate.fps_denominator)))
check("dimensions match media", mc_seq.width == 1920 and mc_seq.height == 1080)

-- Verify tracks: 1 video + 2 audio = 3
local tracks_stmt = assert(db:prepare(
    "SELECT id, name, track_type, track_index FROM tracks WHERE sequence_id = ? ORDER BY track_type, track_index"))
tracks_stmt:bind_value(1, mc_id)
assert(tracks_stmt:exec())
local tracks = {}
while tracks_stmt:next() do
    tracks[#tracks + 1] = {
        id = tracks_stmt:value(0),
        name = tracks_stmt:value(1),
        track_type = tracks_stmt:value(2),
        track_index = tracks_stmt:value(3),
    }
end
tracks_stmt:finalize()

check("3 tracks created (1V + 2A)", #tracks == 3,
    "got: " .. #tracks)

-- Find video and audio tracks
local video_tracks, audio_tracks = {}, {}
for _, t in ipairs(tracks) do
    if t.track_type == "AUDIO" then
        audio_tracks[#audio_tracks + 1] = t
    elseif t.track_type == "VIDEO" then
        video_tracks[#video_tracks + 1] = t
    end
end
check("1 video track", #video_tracks == 1)
check("2 audio tracks", #audio_tracks == 2)

-- Verify stream clips
local clips_stmt = assert(db:prepare([[
    SELECT id, name, media_id, clip_kind, track_id, timeline_start_frame,
           duration_frames, source_in_frame, source_out_frame,
           fps_numerator, fps_denominator, owner_sequence_id
    FROM clips WHERE owner_sequence_id = ?
    ORDER BY fps_numerator DESC
]]))
clips_stmt:bind_value(1, mc_id)
assert(clips_stmt:exec())
local stream_clips = {}
while clips_stmt:next() do
    stream_clips[#stream_clips + 1] = {
        id = clips_stmt:value(0),
        name = clips_stmt:value(1),
        media_id = clips_stmt:value(2),
        clip_kind = clips_stmt:value(3),
        track_id = clips_stmt:value(4),
        timeline_start = clips_stmt:value(5),
        duration = clips_stmt:value(6),
        source_in = clips_stmt:value(7),
        source_out = clips_stmt:value(8),
        fps_numerator = clips_stmt:value(9),
        fps_denominator = clips_stmt:value(10),
        owner_sequence_id = clips_stmt:value(11),
    }
end
clips_stmt:finalize()

check("3 stream clips created", #stream_clips == 3,
    "got: " .. #stream_clips)

-- Separate video and audio clips
local video_clips, audio_clips = {}, {}
for _, c in ipairs(stream_clips) do
    if c.fps_numerator == 24 and c.fps_denominator == 1 then
        video_clips[#video_clips + 1] = c
    elseif c.fps_numerator == 48000 and c.fps_denominator == 1 then
        audio_clips[#audio_clips + 1] = c
    end
end

check("1 video stream clip", #video_clips == 1)
check("2 audio stream clips", #audio_clips == 2)

-- Video stream clip properties
if #video_clips > 0 then
    local vc = video_clips[1]
    check("video clip_kind is master", vc.clip_kind == "master")
    check("video clip media_id", vc.media_id == "media_va")
    check("video clip timeline_start = 0", vc.timeline_start == 0)
    check("video clip duration = 240", vc.duration == 240,
        "got: " .. tostring(vc.duration))
    check("video clip source_in = 0", vc.source_in == 0)
    check("video clip source_out = 240", vc.source_out == 240,
        "got: " .. tostring(vc.source_out))
    check("video clip fps = 24/1", vc.fps_numerator == 24 and vc.fps_denominator == 1)
end

-- Audio stream clip properties
if #audio_clips > 0 then
    local ac = audio_clips[1]
    check("audio clip_kind is master", ac.clip_kind == "master")
    check("audio clip media_id", ac.media_id == "media_va")
    check("audio clip timeline_start = 0", ac.timeline_start == 0)
    check("audio clip duration = 240 (timeline frames)", ac.duration == 240,
        "got: " .. tostring(ac.duration))
    check("audio clip source_in = 0", ac.source_in == 0)
    -- Audio source_out should be duration in samples: 240 * 48000 / 24 = 480000
    local expected_samples = math.floor(240 * 48000 * 1 / 24 + 0.5)
    check("audio clip source_out = 480000 (samples)", ac.source_out == expected_samples,
        string.format("expected %d, got %s", expected_samples, tostring(ac.source_out)))
    check("audio clip fps = 48000/1", ac.fps_numerator == 48000 and ac.fps_denominator == 1)
end

--------------------------------------------------------------------------------
-- Happy path: idempotent (second call returns same ID)
--------------------------------------------------------------------------------

print("\n--- ensure_masterclip: idempotent ---")

local mc_id2 = Sequence.ensure_masterclip("media_va", "proj1")
check("second call returns same ID", mc_id2 == mc_id,
    string.format("first=%s, second=%s", tostring(mc_id), tostring(mc_id2)))

-- Verify no duplicate tracks or clips were created
local count_stmt = assert(db:prepare("SELECT COUNT(*) FROM tracks WHERE sequence_id = ?"))
count_stmt:bind_value(1, mc_id)
assert(count_stmt:exec() and count_stmt:next())
local track_count = count_stmt:value(0)
count_stmt:finalize()
check("still 3 tracks after second call", track_count == 3,
    "got: " .. tostring(track_count))

--------------------------------------------------------------------------------
-- Happy path: video-only media (no audio tracks)
--------------------------------------------------------------------------------

print("\n--- ensure_masterclip: video-only media ---")

local media_v = Media.create({
    id = "media_v_only",
    project_id = "proj1",
    name = "VideoOnly",
    file_path = "synthetic://video_only.mov",
    duration_frames = 100,
    fps_numerator = 30,
    fps_denominator = 1,
    width = 3840,
    height = 2160,
    audio_channels = 0,
    codec = "h264",
})
assert(media_v:save())

local mc_v = Sequence.ensure_masterclip("media_v_only", "proj1")
check("video-only returns ID", mc_v ~= nil)

-- Verify: 1 video track, 0 audio tracks
local tv_stmt = assert(db:prepare(
    "SELECT COUNT(*), track_type FROM tracks WHERE sequence_id = ? GROUP BY track_type ORDER BY track_type"))
tv_stmt:bind_value(1, mc_v)
assert(tv_stmt:exec())
local type_counts = {}
while tv_stmt:next() do
    type_counts[tv_stmt:value(1)] = tv_stmt:value(0)
end
tv_stmt:finalize()

check("video-only: 0 audio tracks", (type_counts["AUDIO"] or 0) == 0)
check("video-only: 1 video track", type_counts["VIDEO"] == 1,
    "got: " .. tostring(type_counts["VIDEO"]))

-- Verify dimensions preserved
local mc_v_seq = Sequence.load(mc_v)
check("video-only: width=3840", mc_v_seq.width == 3840)
check("video-only: height=2160", mc_v_seq.height == 2160)

--------------------------------------------------------------------------------
-- Happy path: audio-only media (no video track)
--------------------------------------------------------------------------------

print("\n--- ensure_masterclip: audio-only media ---")

local media_a = Media.create({
    id = "media_a_only",
    project_id = "proj1",
    name = "AudioOnly",
    file_path = "synthetic://audio_only.wav",
    duration_frames = 480000,  -- 10 seconds at 48000 samples/sec
    fps_numerator = 48000,
    fps_denominator = 1,
    width = 0,
    height = 0,
    audio_channels = 1,
    codec = "pcm",
})
assert(media_a:save())

local mc_a = Sequence.ensure_masterclip("media_a_only", "proj1")
check("audio-only returns ID", mc_a ~= nil)

-- Verify: 0 video tracks, 1 audio track
local ta_stmt = assert(db:prepare(
    "SELECT COUNT(*), track_type FROM tracks WHERE sequence_id = ? GROUP BY track_type ORDER BY track_type"))
ta_stmt:bind_value(1, mc_a)
assert(ta_stmt:exec())
local a_type_counts = {}
while ta_stmt:next() do
    a_type_counts[ta_stmt:value(1)] = ta_stmt:value(0)
end
ta_stmt:finalize()

check("audio-only: 0 video tracks", (a_type_counts["VIDEO"] or 0) == 0)
check("audio-only: 1 audio track", a_type_counts["AUDIO"] == 1,
    "got: " .. tostring(a_type_counts["AUDIO"]))

-- Verify sequence uses 1920x1080 default for audio-only
local mc_a_seq = Sequence.load(mc_a)
check("audio-only: width=1920 (default)", mc_a_seq.width == 1920)
check("audio-only: height=1080 (default)", mc_a_seq.height == 1080)

-- Audio-only: fps is sample_rate, so duration_samples should equal duration_frames
local ac_stmt = assert(db:prepare([[
    SELECT source_out_frame, fps_numerator, fps_denominator, duration_frames
    FROM clips WHERE owner_sequence_id = ? AND clip_kind = 'master'
]]))
ac_stmt:bind_value(1, mc_a)
assert(ac_stmt:exec() and ac_stmt:next())
local a_source_out = ac_stmt:value(0)
local a_fps_num = ac_stmt:value(1)
local a_fps_den = ac_stmt:value(2)
local a_duration = ac_stmt:value(3)
ac_stmt:finalize()

check("audio-only clip fps = 48000/1", a_fps_num == 48000 and a_fps_den == 1)
-- For audio-only media: duration_frames=480000 (already samples),
-- duration_samples = 480000 * 48000 * 1 / 48000 = 480000
check("audio-only clip source_out = duration_frames", a_source_out == 480000,
    string.format("expected 480000, got %s", tostring(a_source_out)))
check("audio-only clip duration = 480000", a_duration == 480000,
    "got: " .. tostring(a_duration))

--------------------------------------------------------------------------------
-- Happy path: replay IDs for redo determinism
--------------------------------------------------------------------------------

print("\n--- ensure_masterclip: replay IDs ---")

local media_replay = Media.create({
    id = "media_replay",
    project_id = "proj1",
    name = "ReplayTest",
    file_path = "synthetic://replay_test.mov",
    duration_frames = 120,
    fps_numerator = 24,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 1,
    codec = "prores",
})
assert(media_replay:save())

local mc_replay = Sequence.ensure_masterclip("media_replay", "proj1", {
    id = "fixed_seq_id",
    video_track_id = "fixed_vtrack_id",
    video_clip_id = "fixed_vclip_id",
    audio_track_ids = {"fixed_atrack_1"},
    audio_clip_ids = {"fixed_aclip_1"},
})

check("replay: sequence ID matches", mc_replay == "fixed_seq_id",
    "got: " .. tostring(mc_replay))

-- Verify the sub-entity IDs
local rt_stmt = assert(db:prepare("SELECT id FROM tracks WHERE sequence_id = ? AND track_type = 'VIDEO'"))
rt_stmt:bind_value(1, mc_replay)
assert(rt_stmt:exec() and rt_stmt:next())
check("replay: video track ID matches", rt_stmt:value(0) == "fixed_vtrack_id",
    "got: " .. tostring(rt_stmt:value(0)))
rt_stmt:finalize()

local rc_stmt = assert(db:prepare(
    "SELECT id FROM clips WHERE owner_sequence_id = ? AND fps_numerator = 24"))
rc_stmt:bind_value(1, mc_replay)
assert(rc_stmt:exec() and rc_stmt:next())
check("replay: video clip ID matches", rc_stmt:value(0) == "fixed_vclip_id",
    "got: " .. tostring(rc_stmt:value(0)))
rc_stmt:finalize()

local rat_stmt = assert(db:prepare("SELECT id FROM tracks WHERE sequence_id = ? AND track_type = 'AUDIO'"))
rat_stmt:bind_value(1, mc_replay)
assert(rat_stmt:exec() and rat_stmt:next())
check("replay: audio track ID matches", rat_stmt:value(0) == "fixed_atrack_1",
    "got: " .. tostring(rat_stmt:value(0)))
rat_stmt:finalize()

local rac_stmt = assert(db:prepare(
    "SELECT id FROM clips WHERE owner_sequence_id = ? AND fps_numerator = 48000"))
rac_stmt:bind_value(1, mc_replay)
assert(rac_stmt:exec() and rac_stmt:next())
check("replay: audio clip ID matches", rac_stmt:value(0) == "fixed_aclip_1",
    "got: " .. tostring(rac_stmt:value(0)))
rac_stmt:finalize()

--------------------------------------------------------------------------------
-- Happy path: _find_masterclip_for_media internal lookup
--------------------------------------------------------------------------------

print("\n--- _find_masterclip_for_media: lookup ---")

-- Already tested implicitly by idempotency. Test boundary: media with no masterclip.
local found = Sequence._find_masterclip_for_media(db, "nonexistent_media")
check("lookup: nonexistent media returns nil", found == nil)

local found_va = Sequence._find_masterclip_for_media(db, "media_va")
check("lookup: existing media returns correct ID", found_va == mc_id,
    string.format("expected %s, got %s", tostring(mc_id), tostring(found_va)))

--------------------------------------------------------------------------------
-- Clip.create auto-resolve: timeline clip without master_clip_id
--------------------------------------------------------------------------------

print("\n--- Clip.create auto-resolve ---")

-- Create a timeline sequence + track to put clips on
local tl_seq = Sequence.create("Timeline", "proj1",
    {fps_numerator = 24, fps_denominator = 1}, 1920, 1080, {})
assert(tl_seq:save())

local tl_track = Track.create_video("V1", tl_seq.id, {index = 1})
assert(tl_track:save())

-- Create timeline clip WITHOUT explicit master_clip_id
local auto_clip = Clip.create("AutoResolve", "media_va", {
    project_id = "proj1",
    clip_kind = "timeline",
    track_id = tl_track.id,
    owner_sequence_id = tl_seq.id,
    timeline_start = 0,
    duration = 50,
    source_in = 0,
    source_out = 50,
    fps_numerator = 24,
    fps_denominator = 1,
})

check("auto-resolve: clip created", auto_clip ~= nil)
check("auto-resolve: master_clip_id is set", auto_clip.master_clip_id ~= nil and auto_clip.master_clip_id ~= "")
check("auto-resolve: master_clip_id matches existing masterclip", auto_clip.master_clip_id == mc_id,
    string.format("expected %s, got %s", tostring(mc_id), tostring(auto_clip.master_clip_id)))

-- Create timeline clip WITH explicit master_clip_id (should skip auto-resolve)
local explicit_clip = Clip.create("Explicit", "media_va", {
    project_id = "proj1",
    clip_kind = "timeline",
    master_clip_id = "custom_mc_id",
    track_id = tl_track.id,
    owner_sequence_id = tl_seq.id,
    timeline_start = 50,
    duration = 50,
    source_in = 0,
    source_out = 50,
    fps_numerator = 24,
    fps_denominator = 1,
})
check("explicit: master_clip_id preserved", explicit_clip.master_clip_id == "custom_mc_id")

--------------------------------------------------------------------------------
-- Clip.create auto-resolve: error paths
--------------------------------------------------------------------------------

print("\n--- Clip.create auto-resolve: error paths ---")

expect_error("auto-resolve: nil media_id asserts", function()
    Clip.create("Bad", nil, {
        project_id = "proj1",
        clip_kind = "timeline",
        track_id = tl_track.id,
        owner_sequence_id = tl_seq.id,
        timeline_start = 100,
        duration = 50,
        fps_numerator = 24,
        fps_denominator = 1,
    })
end, "media_id is required to auto%-resolve")

expect_error("auto-resolve: nil project_id asserts", function()
    Clip.create("Bad", "media_va", {
        clip_kind = "timeline",
        track_id = tl_track.id,
        owner_sequence_id = tl_seq.id,
        timeline_start = 100,
        duration = 50,
        fps_numerator = 24,
        fps_denominator = 1,
    })
end, "project_id is required to auto%-resolve")

expect_error("auto-resolve: empty project_id asserts", function()
    Clip.create("Bad", "media_va", {
        project_id = "",
        clip_kind = "timeline",
        track_id = tl_track.id,
        owner_sequence_id = tl_seq.id,
        timeline_start = 100,
        duration = 50,
        fps_numerator = 24,
        fps_denominator = 1,
    })
end, "project_id is required")

--------------------------------------------------------------------------------
-- Edge case: audio duration_samples calculation with NTSC fps
--------------------------------------------------------------------------------

print("\n--- ensure_masterclip: NTSC audio duration ---")

local media_ntsc = Media.create({
    id = "media_ntsc",
    project_id = "proj1",
    name = "NTSC",
    file_path = "synthetic://ntsc.mov",
    duration_frames = 300,  -- ~10 seconds at 29.97
    fps_numerator = 30000,
    fps_denominator = 1001,
    width = 1920,
    height = 1080,
    audio_channels = 1,
    codec = "h264",
})
assert(media_ntsc:save())

local mc_ntsc = Sequence.ensure_masterclip("media_ntsc", "proj1")
check("NTSC: returns ID", mc_ntsc ~= nil)

-- Check audio source_out: 300 * 48000 * 1001 / 30000 = 480480
local ntsc_stmt = assert(db:prepare([[
    SELECT source_out_frame FROM clips
    WHERE owner_sequence_id = ? AND fps_numerator = 48000
]]))
ntsc_stmt:bind_value(1, mc_ntsc)
assert(ntsc_stmt:exec() and ntsc_stmt:next())
local ntsc_source_out = ntsc_stmt:value(0)
ntsc_stmt:finalize()

local expected_ntsc = math.floor(300 * 48000 * 1001 / 30000 + 0.5)
check("NTSC: audio source_out correct", ntsc_source_out == expected_ntsc,
    string.format("expected %d, got %s", expected_ntsc, tostring(ntsc_source_out)))

--------------------------------------------------------------------------------
-- Edge case: zero-duration media
--------------------------------------------------------------------------------

print("\n--- ensure_masterclip: zero-duration (still image) ---")

-- Media.create allows duration_frames = 0 for still images
-- But schema CHECK(duration_frames > 0) on clips... let's test
-- Actually, clips table has CHECK(duration_frames > 0), so 0-duration media
-- can't produce valid stream clips. This should fail.
-- For now, ensure_masterclip would try to create a clip with duration=0 → schema error.
-- This is correct NSF behavior (fail loudly, don't invent a duration).

-- Let's verify with a still image that has duration > 0 (e.g., 1 frame)
local media_still = Media.create({
    id = "media_still",
    project_id = "proj1",
    name = "Still",
    file_path = "synthetic://still.jpg",
    duration_frames = 1,
    fps_numerator = 24,
    fps_denominator = 1,
    width = 4000,
    height = 3000,
    audio_channels = 0,
    codec = "jpeg",
})
assert(media_still:save())

local mc_still = Sequence.ensure_masterclip("media_still", "proj1")
check("still image: returns ID", mc_still ~= nil)

local still_clip_stmt = assert(db:prepare(
    "SELECT duration_frames FROM clips WHERE owner_sequence_id = ?"))
still_clip_stmt:bind_value(1, mc_still)
assert(still_clip_stmt:exec() and still_clip_stmt:next())
check("still image: clip duration = 1", still_clip_stmt:value(0) == 1)
still_clip_stmt:finalize()

--------------------------------------------------------------------------------
-- Edge case: master clips should NOT auto-resolve master_clip_id
--------------------------------------------------------------------------------

print("\n--- Clip.create: master clips skip auto-resolve ---")

-- Master clips (clip_kind = "master") should not auto-resolve.
-- They are the stream clips inside masterclip sequences.
local master_clip = Clip.create("Master", "media_va", {
    project_id = "proj1",
    clip_kind = "master",
    track_id = tl_track.id,
    owner_sequence_id = tl_seq.id,
    timeline_start = 200,
    duration = 50,
    source_in = 0,
    source_out = 50,
    fps_numerator = 24,
    fps_denominator = 1,
})
check("master clip: no master_clip_id set", master_clip.master_clip_id == nil or master_clip.master_clip_id == "")

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------

-- database cleanup handled by test_harness

print(string.format("\n=== Results: %d passed, %d failed ===", pass_count, fail_count))
assert(fail_count == 0,
    string.format("test_ensure_masterclip.lua: %d test(s) failed", fail_count))
print("✅ test_ensure_masterclip.lua passed")
