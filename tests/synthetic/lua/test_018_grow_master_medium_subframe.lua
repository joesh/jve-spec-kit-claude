-- 018 NSF regression pin: GrowMasterMedium creates an audio companion clip
-- whose source range is expressed in master.fps frames + canonical
-- subframe ticks (FR-008). Pre-018 the command stored dur_samples in the
-- source_out_frame column directly — a kind/unit error that silently
-- produced clips that didn't decode.
--
-- This test exercises a non-divisor file rate (44.1 kHz) so the
-- conversion produces a NON-ZERO subframe. Frame-aligned cases (48 kHz at
-- 24 fps) would pass even with broken math.

require("test_env")
local database = require("core.database")
local GrowMasterMedium = require("core.commands.grow_master_medium")

local DB = "/tmp/jve/test_018_grow_master_medium_subframe.db"
os.remove(DB)
assert(database.init(DB))
local db = database.get_connection()

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'P', 'passthrough',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
            %d, %d);
    -- master sequence at 24/1; parent (record) sequence also 24/1.
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        created_at, modified_at)
    VALUES ('m', 'p', 'M', 'master',  24, 1, NULL,  1920, 1080, %d, %d),
           ('e', 'p', 'E', 'sequence',24, 1, 44100, 1920, 1080, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
    VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
           ('e-v1', 'e', 'V1', 'VIDEO', 1),
           ('e-a1', 'e', 'A1', 'AUDIO', 1);
    UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';

    -- 1-frame video media (so the audio companion math is unambiguous).
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_channels, audio_sample_rate,
        created_at, modified_at)
    VALUES ('vm', 'p', 'v.mov', '/tmp/v.mov', 1, 24, 1, 0, NULL, %d, %d);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('vmref', 'p', 'm', 'm-v1', 'vm', 0, 1, 0, 1,
            1, 1.0, 0, %d, %d);

    -- One V clip on the edit sequence pointing at the master, duration=1 frame.
    INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id,
        name, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('vc', 'p', 'e', 'e-v1', 'm', 'V',
            0, 1, 0, 1, NULL, NULL,
            NULL, NULL, 'passthrough',
            1, 1.0, 0, %d, %d);

    -- Audio-only media at 44.1k with enough duration to cover the grow.
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_channels, audio_sample_rate,
        created_at, modified_at)
    VALUES ('am', 'p', 'a.wav', '/tmp/a.wav', 44100, 44100, 1, 1, 44100, %d, %d);
]],
    now, now, now, now, now, now, now, now, now, now, now, now, now, now)))

-- Drive GrowMasterMedium directly (existing test pattern bypasses the
-- command_manager mutations-required check; we're pinning the source
-- conversion math, not the undo-replay surface).
local capture = GrowMasterMedium.execute({
    sequence_id = "m",
    medium      = "audio",
    track_spec  = { media_id = "am" },
})
assert(type(capture) == "table",
    "GrowMasterMedium.execute must return a capture table")

-- The command created one companion AUDIO clip on the parent's A1 track.
-- Math (FR-008):
--   dur_samples = round(1 * 44100 * 1 / 24) = 1838
--   tpf         = 192000 * 1 / 24            = 8000 ticks/frame
--   total_ticks = round(1838 * 192000 / 44100) = 8002
--   unpack(8002, 8000)                       = (frame=1, subframe=2)
-- → source range [0, 0) → [1, 2), with source_out_subframe=2.
local s = db:prepare([[
    SELECT id, source_in_frame, source_out_frame,
           source_in_subframe, source_out_subframe
    FROM clips WHERE track_id = 'e-a1' AND owner_sequence_id = 'e'
]])
assert(s:exec() and s:next(), "companion AUDIO clip must exist on e-a1")
local got = {
    id        = s:value(0),
    in_frame  = s:value(1),
    out_frame = s:value(2),
    in_sub    = s:value(3),
    out_sub   = s:value(4),
}
s:finalize()

assert(got.in_frame  == 0, "source_in_frame=0; got "  .. tostring(got.in_frame))
assert(got.out_frame == 1, "source_out_frame=1; got " .. tostring(got.out_frame))
assert(got.in_sub    == 0, "source_in_subframe=0; got "  .. tostring(got.in_sub))
assert(got.out_sub   == 2, string.format(
    "source_out_subframe=2 (non-divisor 44.1k → 24 fps residual); got %s",
    tostring(got.out_sub)))

print("✅ test_018_grow_master_medium_subframe.lua passed")
