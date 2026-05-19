-- 018 NSF audit: model layer must NOT silently default missing audio
-- subframes (V1), missing audio_sample_rate on AUDIO media_refs (V3), and
-- the schema must enforce V5 (audio media_refs require non-NULL audio rate).
--
-- Each case proves a current silent-default behavior is a bug, then the
-- implementation flips to assert. Test is the spec.

require("test_env")
local database = require("core.database")
local Clip     = require("models.clip")
local MediaRef = require("models.media_ref")

local DB_PATH = "/tmp/jve/test_018_nsf_no_silent_defaults.db"
os.remove(DB_PATH); os.remove(DB_PATH .. "-wal"); os.remove(DB_PATH .. "-shm")
assert(database.init(DB_PATH))
local db = database.get_connection()

-- Minimal fixture: project, master, sequence, audio + video track on the sequence.
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'p', 'passthrough', '%s', 0, 0);
]], '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}')))
assert(db:exec([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('m', 'p', 'm', 'master', 24, 1, NULL, 1920, 1080, 0, 0),
           ('s', 'p', 's', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
    VALUES ('s-v', 's', 'V1', 'VIDEO', 1),
           ('s-a', 's', 'A1', 'AUDIO', 1),
           ('m-v', 'm', 'V1', 'VIDEO', 1),
           ('m-a', 'm', 'A1', 'AUDIO', 1);
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_sample_rate, audio_channels, created_at, modified_at)
    VALUES ('med', 'p', 'a.mov', '/tmp/a.mov', 1000, 24, 1, 48000, 2, 0, 0);
]]))

local function expect_error(label, fn, pattern)
    local ok, err = pcall(fn)
    assert(not ok, label .. ": expected error, got success")
    assert(tostring(err):match(pattern),
        string.format("%s: error %q must match %q", label, tostring(err), pattern))
end

-- ===========================================================================
-- V1: Clip._create_v13_row must NOT silently default audio subframes to 0.
-- Caller that omits source_in_subframe / source_out_subframe on an AUDIO
-- clip is a bug — surface it loudly.
-- ===========================================================================

expect_error("V1: audio clip without source_in_subframe is refused",
    function()
        Clip.create({
            id = "v1-audio-no-in-sub",
            project_id = "p",
            owner_sequence_id = "s",
            track_id = "s-a",
            sequence_id = "m",
            name = "a",
            sequence_start_frame = 0,
            duration_frames = 100,
            source_in_frame = 0,
            source_out_frame = 100,
            -- source_in_subframe omitted!
            source_out_subframe = 0,
            fps_mismatch_policy = "passthrough",
            enabled = true,
            volume = 1.0,
            playhead_frame = 0,
        })
    end, "source_in_subframe")

expect_error("V1: audio clip without source_out_subframe is refused",
    function()
        Clip.create({
            id = "v1-audio-no-out-sub",
            project_id = "p",
            owner_sequence_id = "s",
            track_id = "s-a",
            sequence_id = "m",
            name = "a",
            sequence_start_frame = 0,
            duration_frames = 100,
            source_in_frame = 0,
            source_out_frame = 100,
            source_in_subframe = 0,
            -- source_out_subframe omitted!
            fps_mismatch_policy = "passthrough",
            enabled = true,
            volume = 1.0,
            playhead_frame = 0,
        })
    end, "source_out_subframe")

-- Happy path: AUDIO clip with explicit subframes succeeds.
local audio_ok = Clip.create({
    id = "v1-audio-ok",
    project_id = "p",
    owner_sequence_id = "s",
    track_id = "s-a",
    sequence_id = "m",
    name = "a",
    sequence_start_frame = 0,
    duration_frames = 100,
    source_in_frame = 0,
    source_out_frame = 100,
    source_in_subframe = 0,
    source_out_subframe = 0,
    fps_mismatch_policy = "passthrough",
    enabled = true,
    volume = 1.0,
    playhead_frame = 0,
})
assert(audio_ok == "v1-audio-ok", "V1 happy path: audio clip create returns id")

-- VIDEO clips continue to refuse subframe args.
expect_error("V1: video clip with non-NULL subframe is refused",
    function()
        Clip.create({
            id = "v1-video-bad",
            project_id = "p",
            owner_sequence_id = "s",
            track_id = "s-v",
            sequence_id = "m",
            name = "v",
            sequence_start_frame = 0,
            duration_frames = 100,
            source_in_frame = 0,
            source_out_frame = 100,
            source_in_subframe = 0,  -- forbidden on video
            source_out_subframe = 0,
            fps_mismatch_policy = "passthrough",
            enabled = true,
            volume = 1.0,
            playhead_frame = 0,
        })
    end, "video clip")

-- ===========================================================================
-- V3: MediaRef.create must refuse audio_sample_rate=nil when track is AUDIO.
-- Currently allows it silently (downstream lookups then fail with cryptic
-- errors). Surface the writer-side bug at insert time.
-- ===========================================================================

expect_error("V3: audio media_ref without audio_sample_rate is refused",
    function()
        MediaRef.create({
            project_id = "p",
            owner_sequence_id = "m",
            track_id = "m-a",
            media_id = "med",
            source_in_frame = 0,
            source_out_frame = 1000,
            sequence_start_frame = 0,
            duration_frames = 1000,
            -- audio_sample_rate omitted on an AUDIO media_ref
            enabled = true,
            volume = 1.0,
            playhead_frame = 0,
        })
    end, "audio_sample_rate")

-- Happy path: AUDIO media_ref with rate succeeds.
local mr_ok = MediaRef.create({
    project_id = "p",
    owner_sequence_id = "m",
    track_id = "m-a",
    media_id = "med",
    source_in_frame = 0,
    source_out_frame = 1000,
    sequence_start_frame = 0,
    duration_frames = 1000,
    audio_sample_rate = 48000,
    enabled = true,
    volume = 1.0,
    playhead_frame = 0,
})
assert(mr_ok, "V3 happy: audio media_ref with rate created")

-- VIDEO media_ref with rate=nil is fine.
local mr_v_ok = MediaRef.create({
    project_id = "p",
    owner_sequence_id = "m",
    track_id = "m-v",
    media_id = "med",
    source_in_frame = 0,
    source_out_frame = 1000,
    sequence_start_frame = 0,
    duration_frames = 1000,
    -- no audio_sample_rate on video media_ref
    enabled = true,
    volume = 1.0,
    playhead_frame = 0,
})
assert(mr_v_ok, "V3 happy: video media_ref without rate created")

-- ===========================================================================
-- V5: schema INV-8 must forbid NULL audio_sample_rate on AUDIO media_refs.
-- Direct SQL INSERT bypassing MediaRef.create is the test — schema-layer
-- enforcement is stronger than model-layer (rule 2.21).
-- ===========================================================================

do
    -- Create a fresh AUDIO track to insert against without unique-id collisions.
    assert(db:exec([[
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-a-inv8', 'm', 'A2', 'AUDIO', 2);
    ]]))
end

local ok = db:exec([[
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        audio_sample_rate,
        enabled, volume, mark_in_frame, mark_out_frame, playhead_frame,
        created_at, modified_at)
    VALUES ('mr-inv8-bad', 'p', 'm', 'm-a-inv8', 'med',
            0, 1000, 0, 1000, NULL, 1, 1.0, NULL, NULL, 0, 0, 0);
]])
assert(not ok, "V5: expected schema ABORT on AUDIO media_ref with NULL audio_sample_rate")
local err = db:last_error() or ""
assert(err:match("audio_sample_rate"),
    "V5: expected audio_sample_rate in error message, got: " .. err)

print("✅ test_018_nsf_no_silent_defaults.lua passed")
