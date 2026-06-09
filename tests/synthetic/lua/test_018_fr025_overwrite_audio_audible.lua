-- 018 FR-025 acceptance: Overwrite from a mixed-media V+A master onto a
-- record sequence produces an AUDIO clip whose source range, when fed to
-- the resolver, yields a valid audio entry pointing into the master's
-- audio media — i.e. playback receives non-silent samples.
--
-- This is the user-visible bug spec 018 was written to fix: F10
-- (Overwrite) used to write source_in in file-natural SAMPLES while the
-- resolver expected master.fps FRAMES (with subframe residual), so audio
-- playback through nested-sequence clips silently produced silence.
--
-- Lua-level proxy for "audio is audible":
--   1. After Overwrite, the AUDIO clip's source_*_frame are in master.fps
--      frames (small numbers, not sample counts).
--   2. Sequence:pick_in_range over the AUDIO clip's timeline range
--      returns an audio entry that resolves all the way to the master's
--      audio media_ref (chain leaf carries .media_id) — NOT an offline /
--      missing-media stub.
--   3. The resolved file-natural sample window matches what playback
--      would request: [0, native_audio_duration_samples).

require("test_env")
local database = require("core.database")
local Sequence = require("models.sequence")
local Overwrite = require("core.commands.overwrite")

local DB = "/tmp/jve/test_018_fr025_overwrite_audio_audible.db"
os.remove(DB)
assert(database.init(DB))
local db = database.get_connection()

-- 10s of mixed-media V+A at 24/1 + 48000 Hz.
local NATIVE_FRAMES  = 240
local NATIVE_SAMPLES = NATIVE_FRAMES * 48000 / 24  -- 480000

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'P', 'passthrough',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
            %d, %d);

    -- Master (mixed media): V1 + A1 tracks both pointing at the same media.
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        created_at, modified_at)
    VALUES ('m', 'p', 'M', 'master',  24, 1, NULL,  1920, 1080, %d, %d),
           ('e', 'p', 'E', 'sequence',24, 1, 48000, 1920, 1080, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
    VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
           ('m-a1', 'm', 'A1', 'AUDIO', 1),
           ('e-v1', 'e', 'V1', 'VIDEO', 1),
           ('e-a1', 'e', 'A1', 'AUDIO', 1);
    UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';

    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_channels, audio_sample_rate,
        created_at, modified_at)
    VALUES ('med', 'p', 'mix.mov', '/tmp/mix.mov', %d, 24, 1, 2, 48000, %d, %d);

    -- V media_ref: native frames, master.fps timebase.
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr-v', 'p', 'm', 'm-v1', 'med', 0, %d, 0, %d,
            1, 1.0, 0, %d, %d);

    -- A media_ref: source range in file-natural samples; placement
    -- (sequence_start_frame, duration_frames) in master.fps frames per
    -- post-018 unification. audio_sample_rate required (the AUDIO-mref
    -- non-NULL invariant).
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr-a', 'p', 'm', 'm-a1', 'med', 0, %d, 0, %d,
            48000, 1, 1.0, 0, %d, %d);
]],
    now, now, now, now, now, now,
    NATIVE_FRAMES, now, now,
    NATIVE_FRAMES, NATIVE_FRAMES, now, now,
    NATIVE_SAMPLES, NATIVE_FRAMES, now, now)))

require("test_env").touch_media_fixtures()

-- Execute Overwrite: place the full master at frame 0 on the record sequence.
local result = Overwrite.execute({
    sequence_id          = "e",
    source_sequence_id   = "m",
    sequence_start_frame = 0,
})
assert(type(result) == "table",
    "Overwrite.execute must return a table; got " .. type(result))
assert(result.video_clip_id, "Overwrite must create a video clip")
assert(result.audio_clip_id, "Overwrite must create an audio clip")

-- (1) The audio clip's source range is in master.fps frames (NOT samples).
--     Pre-018 bug: source_out_frame would be 480000 (samples).
local s = db:prepare([[
    SELECT source_in_frame, source_out_frame,
           source_in_subframe, source_out_subframe,
           sequence_id, sequence_start_frame, duration_frames
    FROM clips WHERE id = ?
]])
s:bind_value(1, result.audio_clip_id)
assert(s:exec() and s:next(), "audio clip row must exist")
local a = {
    in_frame  = s:value(0),
    out_frame = s:value(1),
    in_sub    = s:value(2),
    out_sub   = s:value(3),
    nested_id = s:value(4),
    seq_start = s:value(5),
    duration  = s:value(6),
}
s:finalize()

assert(a.in_frame == 0, string.format(
    "audio clip source_in_frame must be in master.fps frames; got %s",
    tostring(a.in_frame)))
assert(a.out_frame == NATIVE_FRAMES, string.format(
    "audio clip source_out_frame must be master.fps frames (%d); "
    .. "got %s — pre-018 bug stored samples here",
    NATIVE_FRAMES, tostring(a.out_frame)))
assert(a.in_sub == 0 and a.out_sub == 0,
    "audio clip subframes must be 0 (frame-aligned at 24/48k)")
assert(a.nested_id == "m", "audio clip must reference master 'm'")

-- (2) Resolver returns a non-offline audio chain leaf for the clip's range.
local entries = Sequence:pick_in_range("e", a.seq_start, a.seq_start + a.duration, {
    recursing_into = {},
    depth = 0,
    export_mode = false,
    project_fps_mismatch_policy = "passthrough",
})
assert(type(entries) == "table" and #entries > 0,
    "resolver must return at least one entry for the placed audio range")

local audio_entry
for _, e in ipairs(entries) do
    if e.owner_track_type == "AUDIO" or e.media_kind == "audio" then
        audio_entry = e
        break
    end
end
assert(audio_entry, "resolver must produce at least one AUDIO entry")
assert(audio_entry.media_id == "med",
    "audio entry must resolve to the master's audio media (id=med); "
    .. "offline / missing-media stub means audio would be silent")
assert(audio_entry.media_path == "/tmp/mix.mov",
    "audio entry must carry the resolved media path for decoder to open; got "
    .. tostring(audio_entry.media_path))

-- (3) The file-natural sample window is [0, NATIVE_SAMPLES). source_in /
-- source_out on the resolver entry are in FILE-NATURAL UNITS (samples for
-- audio). Pre-018 this could come back wrong because the clip's
-- source_*_frame was in samples and the resolver multiplied AGAIN.
assert(audio_entry.source_in == 0, string.format(
    "audio entry source_in must be file sample 0; got %s",
    tostring(audio_entry.source_in)))
assert(audio_entry.source_out == NATIVE_SAMPLES, string.format(
    "audio entry source_out must be %d file samples (full master placed at 0); "
    .. "got %s — wrong unit means decoder reads the wrong window and you "
    .. "either get silence or the wrong content",
    NATIVE_SAMPLES, tostring(audio_entry.source_out)))

print("✅ test_018_fr025_overwrite_audio_audible.lua passed")
