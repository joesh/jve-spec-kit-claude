-- 018 T050 / FR-034: multi-rate audio master.
--
-- Build a master with one VIDEO media_ref and TWO AUDIO media_refs at
-- DIFFERENT sample rates (48 kHz + 96 kHz), each backed by its own
-- audio file. A clip pointing at this master must produce resolver
-- entries that:
--   1. carry each audio media_ref's NATIVE rate (no silent resampling
--      to a single bus rate baked into the entry).
--   2. point at the correct file for each entry (no cross-wiring).
--   3. yield correct file-sample ranges for each rate.
--
-- This pins INV-7 (rate is per-media_ref, not per-master) end-to-end
-- and verifies the resolver threads both rates through correctly.

require("test_env")
local database = require("core.database")
local Sequence = require("models.sequence")

local DB = "/tmp/jve/test_multi_rate_audio_master.db"
os.remove(DB)
assert(database.init(DB))
local db = database.get_connection()

-- 10s of content at 24fps. The 48k audio media is 480000 samples; the
-- 96k audio media is 960000 samples (same wall-clock duration).
local NATIVE_V_FRAMES   = 240
local NATIVE_A48_SAMPLES = NATIVE_V_FRAMES * 48000 / 24   -- 480000
local NATIVE_A96_SAMPLES = NATIVE_V_FRAMES * 96000 / 24   -- 960000

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
    VALUES ('m-v1',  'm', 'V1',  'VIDEO', 1),
           ('m-a48', 'm', 'A48', 'AUDIO', 1),
           ('m-a96', 'm', 'A96', 'AUDIO', 2),
           ('e-v1',  'e', 'V1',  'VIDEO', 1),
           ('e-a48', 'e', 'A1',  'AUDIO', 1),
           ('e-a96', 'e', 'A2',  'AUDIO', 2);
    UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';

    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_channels, audio_sample_rate,
        created_at, modified_at)
    VALUES ('vm',     'p', 'v.mov',  '/tmp/v.mov',  %d,  24, 1, 0,    NULL,  %d, %d),
           ('a48wav', 'p', 'a48.wav','/tmp/a48.wav',%d,  48000, 1, 1, 48000, %d, %d),
           ('a96wav', 'p', 'a96.wav','/tmp/a96.wav',%d,  96000, 1, 1, 96000, %d, %d);

    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('vref', 'p', 'm', 'm-v1', 'vm', 0, %d, 0, %d,
            1, 1.0, 0, %d, %d);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('a48ref', 'p', 'm', 'm-a48', 'a48wav', 0, %d, 0, %d,
            48000, 1, 1.0, 0, %d, %d),
           ('a96ref', 'p', 'm', 'm-a96', 'a96wav', 0, %d, 0, %d,
            96000, 1, 1.0, 0, %d, %d);
]],
    now, now, now, now, now, now,
    NATIVE_V_FRAMES, now, now,
    NATIVE_A48_SAMPLES, now, now,
    NATIVE_A96_SAMPLES, now, now,
    NATIVE_V_FRAMES, NATIVE_V_FRAMES, now, now,
    NATIVE_A48_SAMPLES, NATIVE_A48_SAMPLES, now, now,
    NATIVE_A96_SAMPLES, NATIVE_A96_SAMPLES, now, now)))

-- One clip on each edit-side track. Source range is the full master
-- (master.fps frames, subframe=0 — frame-aligned at both rates since
-- 48000 and 96000 both divide cleanly into 24fps frames).
assert(db:exec(string.format([[
    INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id,
        name, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('c-v',  'p', 'e', 'e-v1',  'm', 'CV',
            0, %d, 0, %d, NULL, NULL,
            NULL, NULL,    'passthrough',
            1, 1.0, 0, %d, %d),
           ('c-a48','p', 'e', 'e-a48', 'm', 'C48',
            0, %d, 0, %d, 0, 0,
            NULL, 'm-a48', 'passthrough',
            1, 1.0, 0, %d, %d),
           ('c-a96','p', 'e', 'e-a96', 'm', 'C96',
            0, %d, 0, %d, 0, 0,
            NULL, 'm-a96', 'passthrough',
            1, 1.0, 0, %d, %d);
]],
    NATIVE_V_FRAMES, NATIVE_V_FRAMES, now, now,
    NATIVE_V_FRAMES, NATIVE_V_FRAMES, now, now,
    NATIVE_V_FRAMES, NATIVE_V_FRAMES, now, now)))

require("test_env").touch_media_fixtures()

local entries = Sequence:pick_in_range("e", 0, NATIVE_V_FRAMES, {
    recursing_into = {},
    depth = 0,
    export_mode = false,
    project_fps_mismatch_policy = "passthrough",
})
assert(type(entries) == "table" and #entries > 0,
    "resolver must return entries for the placed range")

-- Bucket by (track_type, expected media). Use owner_track_id to
-- distinguish the 48k and 96k AUDIO entries.
local v_entries, a48, a96 = {}, {}, {}
for _, e in ipairs(entries) do
    if e.owner_track_type == "VIDEO" then
        v_entries[#v_entries+1] = e
    elseif e.media_id == "a48wav" then
        a48[#a48+1] = e
    elseif e.media_id == "a96wav" then
        a96[#a96+1] = e
    else
        error(string.format("unexpected entry: track_type=%s media_id=%s",
            tostring(e.owner_track_type), tostring(e.media_id)))
    end
end

-- (1) Exactly one VIDEO entry pointing at vm.
assert(#v_entries == 1, string.format("expected 1 VIDEO entry; got %d", #v_entries))
assert(v_entries[1].media_id == "vm", string.format(
    "video must resolve to 'vm'; got %s", tostring(v_entries[1].media_id)))
assert(v_entries[1].media_path == "/tmp/v.mov", "video media_path correct")

-- (2) At least one AUDIO entry per rate, each pointing at the correct
-- file.
assert(#a48 > 0, "no AUDIO entries resolved to 48k media (cross-wired?)")
assert(#a96 > 0, "no AUDIO entries resolved to 96k media (cross-wired?)")

-- (3) Each AUDIO entry's source_in/out is in FILE-NATURAL SAMPLES at
-- that media's native rate.
for _, e in ipairs(a48) do
    assert(e.media_id == "a48wav", "48k entry must reference a48wav")
    assert(e.media_path == "/tmp/a48.wav", "48k entry path correct")
    assert(e.source_in == 0, string.format(
        "48k source_in must be 0; got %s", tostring(e.source_in)))
    assert(e.source_out == NATIVE_A48_SAMPLES, string.format(
        "48k source_out must be %d (file samples at 48k); got %s",
        NATIVE_A48_SAMPLES, tostring(e.source_out)))
end
for _, e in ipairs(a96) do
    assert(e.media_id == "a96wav", "96k entry must reference a96wav")
    assert(e.media_path == "/tmp/a96.wav", "96k entry path correct")
    assert(e.source_in == 0, string.format(
        "96k source_in must be 0; got %s", tostring(e.source_in)))
    assert(e.source_out == NATIVE_A96_SAMPLES, string.format(
        "96k source_out must be %d (file samples at 96k); got %s — "
        .. "if this reads %d the 96k stream got resampled to 48k",
        NATIVE_A96_SAMPLES, tostring(e.source_out), NATIVE_A48_SAMPLES))
end

-- (4) The two AUDIO entries are NOT collapsed — distinct media files,
-- distinct sample ranges.
assert(a48[1].media_id ~= a96[1].media_id,
    "48k and 96k entries must reference different media files")
assert(a48[1].source_out ~= a96[1].source_out, string.format(
    "48k (%s samples) and 96k (%s samples) ranges must differ at native rates",
    tostring(a48[1].source_out), tostring(a96[1].source_out)))

print(string.format("ok — V=1 A48=%d (range=%d) A96=%d (range=%d)",
    #a48, a48[1].source_out, #a96, a96[1].source_out))
print("✅ test_multi_rate_audio_master.lua passed")
