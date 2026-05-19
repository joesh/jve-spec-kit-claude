-- 018 V11 / INV-3 / FR-005: Clip.load must return source_in_subframe and
-- source_out_subframe on the loaded clip table. Pre-fix the canonical
-- CLIP_LOAD_SQL omitted these columns, so any consumer that loaded an
-- AUDIO clip via Clip.load and then re-wrote it via Clip.create (e.g.
-- undo replay through restore_clip_state, which captures from a loaded
-- clip and re-creates on restore) silently lost the subframe and
-- tripped INV-3 on the next AUDIO write.

require("test_env")
local database = require("core.database")
local Clip     = require("models.clip")

local DB = "/tmp/jve/test_clip_load_subframe_present.db"
os.remove(DB); assert(database.init(DB))
local db = database.get_connection()
local now = os.time()

assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'P', 'passthrough',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
            %d, %d);

    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        created_at, modified_at)
    VALUES ('m', 'p', 'M', 'master',   24, 1, NULL,  1920, 1080, %d, %d),
           ('e', 'p', 'E', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
    VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1),
           ('e-a1', 'e', 'A1', 'AUDIO', 1);

    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_channels, audio_sample_rate,
        created_at, modified_at)
    VALUES ('med', 'p', 'a.wav', '/tmp/a.wav', 480000, 48000, 1, 1, 48000, %d, %d);

    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr-a', 'p', 'm', 'm-a1', 'med', 0, 480000, 0, 480000,
            48000, 1, 1.0, 0, %d, %d);

    -- Audio clip with NON-ZERO subframe on both ends. At 192000 mch / 24fps
    -- video master, tpf = 8000. Use 1234 in / 5678 out — both well inside
    -- [0, tpf) so INV-4 holds and they're distinguishable values.
    INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id,
        name, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('c-a', 'p', 'e', 'e-a1', 'm', 'CA',
            10, 5, 10, 15, 1234, 5678,
            NULL, NULL, 'passthrough',
            1, 1.0, 0, %d, %d);
]],
    now, now, now, now, now, now, now, now, now, now, now, now)))

local clip = assert(Clip.load("c-a"),
    "Clip.load must return the AUDIO clip we just inserted")

-- The 018 regression pin: subframe fields are present on the loaded
-- table. Pre-fix these were nil and any restore-via-Clip.create path
-- silently dropped them, tripping INV-3 on the next AUDIO write.
assert(clip.source_in_subframe == 1234, string.format(
    "Clip.load must return source_in_subframe=1234; got %s",
    tostring(clip.source_in_subframe)))
assert(clip.source_out_subframe == 5678, string.format(
    "Clip.load must return source_out_subframe=5678; got %s",
    tostring(clip.source_out_subframe)))

-- Round-trip sanity: loaded subframes can be threaded back into
-- Clip.create without INV-3 firing. Inserts a copy on the same track at
-- a non-overlapping position, asserts the trigger doesn't reject.
local copy_id = Clip.create({
    id                    = "c-a-copy",
    project_id            = "p",
    owner_sequence_id     = "e",
    track_id              = "e-a1",
    sequence_id           = "m",
    name                  = "CA copy",
    sequence_start_frame  = 100,
    duration_frames       = 5,
    source_in_frame       = clip.source_in,
    source_out_frame      = clip.source_out,
    source_in_subframe    = clip.source_in_subframe,
    source_out_subframe   = clip.source_out_subframe,
    master_layer_track_id = nil,
    master_audio_track_id = nil,
    fps_mismatch_policy   = "passthrough",
    enabled               = 1,
    volume                = 1.0,
    playhead_frame        = 0,
})
assert(copy_id == "c-a-copy",
    "Clip.create must accept loaded subframe round-trip without INV-3 firing")

print("ok — Clip.load returns subframe; round-trip through Clip.create clean")
print("✅ test_clip_load_subframe_present.lua passed")
