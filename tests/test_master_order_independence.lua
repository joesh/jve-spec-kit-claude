-- 018 T049 / FR-033: master-order independence.
--
-- Build two masters that hold the SAME media_refs added in DIFFERENT
-- orders. A clip pointing at master-A and a clip pointing at master-B
-- over the same range must resolve to the same media, same file sample
-- positions, same per-channel layout. Pre-018 the resolver leaned on
-- master-internal ordering in places; the canonical (frame, subframe)
-- model and the master.fps frame timebase mean order is no longer a
-- factor — this test pins that.

require("test_env")
local database = require("core.database")
local Sequence = require("models.sequence")

local DB = "/tmp/jve/test_master_order_independence.db"
os.remove(DB)
assert(database.init(DB))
local db = database.get_connection()

local NATIVE_V_FRAMES  = 240
local NATIVE_A_SAMPLES = NATIVE_V_FRAMES * 48000 / 24  -- 480000

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'P', 'passthrough',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
            %d, %d);

    -- Two masters, same content layout, opposite insertion order.
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        created_at, modified_at)
    VALUES ('m-a', 'p', 'MA', 'master',   24, 1, NULL,  1920, 1080, %d, %d),
           ('m-b', 'p', 'MB', 'master',   24, 1, NULL,  1920, 1080, %d, %d),
           ('e',   'p', 'E',  'sequence', 24, 1, 48000, 1920, 1080, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
    VALUES ('ma-v1', 'm-a', 'V1', 'VIDEO', 1),
           ('ma-a1', 'm-a', 'A1', 'AUDIO', 1),
           ('mb-v1', 'm-b', 'V1', 'VIDEO', 1),
           ('mb-a1', 'm-b', 'A1', 'AUDIO', 1),
           ('e-v1',  'e',   'V1', 'VIDEO', 1),
           ('e-a1',  'e',   'A1', 'AUDIO', 1);
    UPDATE sequences SET default_video_layer_track_id = 'ma-v1' WHERE id = 'm-a';
    UPDATE sequences SET default_video_layer_track_id = 'mb-v1' WHERE id = 'm-b';

    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_channels, audio_sample_rate,
        created_at, modified_at)
    VALUES ('med', 'p', 'mix.mov', '/tmp/mix.mov', %d, 24, 1, 2, 48000, %d, %d);
]],
    now, now, now, now, now, now, now, now, NATIVE_V_FRAMES, now, now)))

-- Master A: V inserted FIRST, then A.
assert(db:exec(string.format([[
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('ma-vref', 'p', 'm-a', 'ma-v1', 'med', 0, %d, 0, %d,
            1, 1.0, 0, %d, %d);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('ma-aref', 'p', 'm-a', 'ma-a1', 'med', 0, %d, 0, %d,
            48000, 1, 1.0, 0, %d, %d);
]], NATIVE_V_FRAMES, NATIVE_V_FRAMES, now, now,
    NATIVE_A_SAMPLES, NATIVE_A_SAMPLES, now, now)))

-- Master B: A inserted FIRST, then V.
assert(db:exec(string.format([[
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mb-aref', 'p', 'm-b', 'mb-a1', 'med', 0, %d, 0, %d,
            48000, 1, 1.0, 0, %d, %d);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mb-vref', 'p', 'm-b', 'mb-v1', 'med', 0, %d, 0, %d,
            1, 1.0, 0, %d, %d);
]], NATIVE_A_SAMPLES, NATIVE_A_SAMPLES, now, now,
    NATIVE_V_FRAMES, NATIVE_V_FRAMES, now, now)))

-- Two clips on the record sequence, one per master. Same frame window.
assert(db:exec(string.format([[
    INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id,
        name, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('clip-a-v', 'p', 'e', 'e-v1', 'm-a', 'CA-V',
              0, %d, 0, %d, NULL, NULL,
              NULL, NULL, 'passthrough',
              1, 1.0, 0, %d, %d),
           ('clip-a-a', 'p', 'e', 'e-a1', 'm-a', 'CA-A',
              0, %d, 0, %d, 0, 0,
              NULL, NULL, 'passthrough',
              1, 1.0, 0, %d, %d),
           ('clip-b-v', 'p', 'e', 'e-v1', 'm-b', 'CB-V',
            500, %d, 0, %d, NULL, NULL,
              NULL, NULL, 'passthrough',
              1, 1.0, 0, %d, %d),
           ('clip-b-a', 'p', 'e', 'e-a1', 'm-b', 'CB-A',
            500, %d, 0, %d, 0, 0,
              NULL, NULL, 'passthrough',
              1, 1.0, 0, %d, %d);
]],
    NATIVE_V_FRAMES, NATIVE_V_FRAMES, now, now,   -- clip-a-v
    NATIVE_V_FRAMES, NATIVE_V_FRAMES, now, now,   -- clip-a-a (master.fps frames)
    NATIVE_V_FRAMES, NATIVE_V_FRAMES, now, now,   -- clip-b-v
    NATIVE_V_FRAMES, NATIVE_V_FRAMES, now, now))) -- clip-b-a

require("test_env").touch_media_fixtures()

local function resolve_range_for(seq_start, dur)
    return Sequence:resolve_in_range("e", seq_start, seq_start + dur, {
        recursing_into = {},
        depth = 0,
        export_mode = false,
        project_fps_mismatch_policy = "passthrough",
    })
end

local function pick(entries, track_type)
    -- Pick the entry for the matching track_type. For multi-channel
    -- audio there can be multiple — return them as a list.
    local out = {}
    for _, e in ipairs(entries) do
        if e.owner_track_type == track_type then out[#out + 1] = e end
    end
    return out
end


-- Resolve master A's clips at [0, NATIVE_V_FRAMES) and master B's clips
-- at [500, 500+NATIVE_V_FRAMES). Both windows match the same source
-- range; expected output is identical modulo entry order.
local entries_a = resolve_range_for(0,   NATIVE_V_FRAMES)
local entries_b = resolve_range_for(500, NATIVE_V_FRAMES)

local va = pick(entries_a, "VIDEO")
local aa = pick(entries_a, "AUDIO")
local vb = pick(entries_b, "VIDEO")
local ab = pick(entries_b, "AUDIO")

assert(#va == #vb, string.format(
    "VIDEO entry count must match across masters; A=%d B=%d", #va, #vb))
assert(#aa == #ab, string.format(
    "AUDIO entry count must match across masters; A=%d B=%d", #aa, #ab))
assert(#va == 1, "expected exactly 1 VIDEO entry per clip")
assert(#aa > 0, "expected at least 1 AUDIO entry per clip")

-- VIDEO signature equivalence — sequence_start differs (0 vs 500) so we
-- compare only the file-side fields.
local function video_file_sig(e)
    return string.format("media=%s in=%s out=%s media_kind=%s",
        tostring(e.media_id), tostring(e.source_in), tostring(e.source_out),
        tostring(e.media_kind))
end
assert(video_file_sig(va[1]) == video_file_sig(vb[1]), string.format(
    "VIDEO entries differ across masters:\n  A: %s\n  B: %s",
    video_file_sig(va[1]), video_file_sig(vb[1])))

-- AUDIO entries: same channel layout, same file ranges.
local function audio_file_sig(e)
    return string.format("media=%s in=%s out=%s ch=%s media_kind=%s",
        tostring(e.media_id), tostring(e.source_in), tostring(e.source_out),
        tostring(e.channel_index), tostring(e.media_kind))
end
-- Sort both by channel_index for deterministic comparison. AUDIO entries
-- MUST carry channel_index (rule 2.13 — assert rather than fall back to a
-- sentinel that would silently mis-order on missing data).
local function assert_audio_channels(label, entries)
    for i, e in ipairs(entries) do
        assert(type(e.channel_index) == "number", string.format(
            "%s entry %d missing channel_index: %s",
            label, i, tostring(e.channel_index)))
    end
end
local function by_channel(t)
    table.sort(t, function(x, y) return x.channel_index < y.channel_index end)
    return t
end
assert_audio_channels("aa", aa)
assert_audio_channels("ab", ab)
aa = by_channel(aa); ab = by_channel(ab)
for i = 1, #aa do
    assert(audio_file_sig(aa[i]) == audio_file_sig(ab[i]), string.format(
        "AUDIO entry %d differs across masters:\n  A: %s\n  B: %s",
        i, audio_file_sig(aa[i]), audio_file_sig(ab[i])))
end

-- NSF Half 2: signature equality is vacuous if both sides happen to be
-- offline stubs (media_id=nil) — sigs match but no content actually
-- resolved. Explicitly assert that each side resolved to the master's
-- real audio media.
assert(va[1].media_id == "med", string.format(
    "master A video must resolve to 'med'; got %s", tostring(va[1].media_id)))
assert(vb[1].media_id == "med", string.format(
    "master B video must resolve to 'med'; got %s", tostring(vb[1].media_id)))
for i = 1, #aa do
    assert(aa[i].media_id == "med",
        "master A audio channel " .. tostring(aa[i].channel_index) .. " offline")
    assert(ab[i].media_id == "med",
        "master B audio channel " .. tostring(ab[i].channel_index) .. " offline")
end

print(string.format("ok — %d video + %d audio entries identical across masters",
    #va, #aa))
print("✅ test_master_order_independence.lua passed")
