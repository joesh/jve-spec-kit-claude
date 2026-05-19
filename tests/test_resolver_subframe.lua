-- T016 (018): resolver consumes (frame, subframe) into file-natural sample
-- positions per the data-model.md § "Resolution to file-natural sample"
-- formula:
--
--     file_sample = mr.source_in
--                 + frames_to_samples(clip.source_in_frame - mr.sequence_start,
--                                     mr.audio_sample_rate,
--                                     source_seq.fps_num, source_seq.fps_den)
--                 + round_half_away_from_zero(
--                       clip.source_in_subframe * mr.audio_sample_rate
--                       / project.master_clock_hz)
--
-- Scenario domain:
--   - Master sequence at 24fps holds one AUDIO media_ref (file_path=…/a.wav)
--     starting at master-frame 0, covering 240 master frames (= 10 sec).
--   - The media_ref's file-natural source_in is 0 samples.
--   - An outer sequence at 24fps holds one AUDIO clip referencing the master
--     with source_in_frame=2, source_out_frame=10, and varying subframe values.
--
-- Pre-018 resolver computes file_in = mr.source_in + (lo - mr.sequence_start),
-- which is in master frames — wrong for audio. After T017 the resolver returns
-- file-natural samples per the formula.
--
-- Three sub-scenarios:
--   (1) subframe=0 control at file_rate=48000 (divisor of 192000)
--   (2) subframe=2000 at file_rate=48000 — exact (subframe is a multiple of 4)
--   (3) subframe=2000 at file_rate=44100 — round-half-away-from-zero applies,
--       expected sample value within 1 of the ideal computation.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolver_subframe.db"
os.remove(DB_PATH); os.remove(DB_PATH .. "-wal"); os.remove(DB_PATH .. "-shm")
assert(database.init(DB_PATH))
local db = database.get_connection()

-- Helper: seed minimal project + master(audio-mr) + outer(audio-clip) shape.
-- Returns the outer sequence id so the caller can drive resolve_in_range.
-- All ids are scenario-prefixed so the three sub-scenarios coexist in one DB.
local function seed_scenario(prefix, file_rate, subframe_in)
    local project_id   = prefix .. "_p"
    local master_id    = prefix .. "_m"
    local outer_id     = prefix .. "_e"
    local m_track      = prefix .. "_m_a1"
    local e_track      = prefix .. "_e_a1"
    local media_id     = prefix .. "_med"
    local media_ref_id = prefix .. "_mr"
    local clip_id      = prefix .. "_c"

    local settings = string.format(
        '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}')

    assert(db:exec(string.format([[
        INSERT INTO projects (id, name, fps_mismatch_policy, settings,
            created_at, modified_at)
        VALUES ('%s', '%s', 'passthrough', '%s', 0, 0);
    ]], project_id, prefix, settings)))

    assert(db:exec(string.format([[
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate,
            width, height, created_at, modified_at)
        VALUES ('%s', '%s', 'm', 'master', 24, 1, NULL, 1920, 1080, 0, 0),
               ('%s', '%s', 'e', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
    ]], master_id, project_id, outer_id, project_id)))

    assert(db:exec(string.format([[
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('%s', '%s', 'A1', 'AUDIO', 1),
               ('%s', '%s', 'A1', 'AUDIO', 1);
    ]], m_track, master_id, e_track, outer_id)))

    assert(db:exec(string.format([[
        INSERT INTO media (id, project_id, name, file_path,
            duration_frames, fps_numerator, fps_denominator,
            audio_sample_rate, audio_channels,
            created_at, modified_at)
        VALUES ('%s', '%s', 'a', '/tmp/a_%s.wav', 240, 24, 1, %d, 1, 0, 0);
    ]], media_id, project_id, prefix, file_rate)))

    -- AUDIO media_ref: source_in=0 file samples, spanning master frames [0, 240).
    -- INV-8 requires audio_sample_rate non-NULL on AUDIO media_refs.
    assert(db:exec(string.format([[
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames,
            audio_sample_rate, enabled, volume,
            playhead_frame, created_at, modified_at)
        VALUES ('%s', '%s', '%s', '%s', '%s', 0, 240, 0, 240,
                %d, 1, 1.0, 0, 0, 0);
    ]], media_ref_id, project_id, master_id, m_track, media_id, file_rate)))

    -- AUDIO clip on outer: master-frame window [2, 10), subframe = subframe_in/0.
    -- INV-3 requires non-NULL subframes on audio clips.
    assert(db:exec(string.format([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            fps_mismatch_policy, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('%s', '%s', '%s', '%s', '%s', 'c',
                0, 8, 2, 10, %d, 0,
                'passthrough', 1, 1.0, 0, 0, 0);
    ]], clip_id, project_id, outer_id, e_track, master_id, subframe_in)))

    require("test_env").touch_media_fixtures()
    return outer_id
end

local Sequence = require("models.sequence")

-- Round-half-away-from-zero — mirrors src/lua/core/subframe_math.lua. Used
-- here for expected-value computation; deriving the expected number from
-- the domain formula (not from tracing the implementation).
local function round_haz(x)
    if x >= 0 then return math.floor(x + 0.5) end
    return -math.floor(-x + 0.5)
end

local function resolve_one_audio_entry(outer_id)
    local entries = Sequence:resolve_in_range(outer_id, 0, 8, {
        recursing_into = {},
        depth = 0,
        export_mode = false,
        project_fps_mismatch_policy = "passthrough",
    })
    -- Mono media (audio_channels=1) → exactly one audio entry per clip.
    local audio = nil
    for _, e in ipairs(entries) do
        if e.media_kind == "audio" then
            assert(audio == nil, "expected exactly one audio entry")
            audio = e
        end
    end
    assert(audio, "no audio entry returned")
    return audio
end

-- ── Scenario A: subframe=0, file_rate=48000 ─────────────────────────────────
-- Expected file-natural source_in:
--   mr.source_in (0) + frames_to_samples(2-0, 48000, 24, 1) + 0
--   = 0 + 2 * 48000 / 24 = 4000 samples
-- Expected source_out (clip.source_out_subframe=0):
--   0 + frames_to_samples(10-0, 48000, 24, 1) + 0 = 20000
local outer_a = seed_scenario("s48_zero", 48000, 0)
local entry_a = resolve_one_audio_entry(outer_a)
assert(entry_a.source_in == 4000, string.format(
    "scenario A (subframe=0, file_rate=48000): expected source_in=4000 samples "
    .. "(= 2 frames * 48000/24), got %s", tostring(entry_a.source_in)))
assert(entry_a.source_out == 20000, string.format(
    "scenario A: expected source_out=20000, got %s",
    tostring(entry_a.source_out)))

-- ── Scenario B: subframe=2000 ticks, file_rate=48000 ────────────────────────
-- Subframe is at 192000 master-clock ticks per second. Per data-model.md the
-- subframe contribution in file samples is round(2000 * 48000 / 192000) = 500.
-- Expected source_in: 4000 + 500 = 4500.
local outer_b = seed_scenario("s48_2000", 48000, 2000)
local entry_b = resolve_one_audio_entry(outer_b)
local expect_b = 4000 + round_haz(2000 * 48000 / 192000)
assert(expect_b == 4500, "test design error: scenario B should expect 4500")
assert(entry_b.source_in == expect_b, string.format(
    "scenario B (subframe=2000, file_rate=48000): expected source_in=%d, got %s",
    expect_b, tostring(entry_b.source_in)))

-- ── Scenario C: subframe=2000 ticks, file_rate=44100 ────────────────────────
-- Non-divisor case. 2 frames @ 24fps @ 44100Hz = 2 * 44100 / 24 = 3675 samples
-- (exact). Subframe contribution: round(2000 * 44100 / 192000) = round(459.375) = 459.
-- Expected source_in: 3675 + 459 = 4134.
local outer_c = seed_scenario("s44_2000", 44100, 2000)
local entry_c = resolve_one_audio_entry(outer_c)
local whole_part_c   = round_haz(2 * 44100 / 24)
local subframe_part_c = round_haz(2000 * 44100 / 192000)
local expect_c = whole_part_c + subframe_part_c
assert(whole_part_c == 3675, "test design error: 2*44100/24 should be 3675")
assert(subframe_part_c == 459, "test design error: round(2000*44100/192000) should be 459")
assert(entry_c.source_in == expect_c, string.format(
    "scenario C (subframe=2000, file_rate=44100): expected source_in=%d "
    .. "(whole=%d + sub=%d), got %s",
    expect_c, whole_part_c, subframe_part_c, tostring(entry_c.source_in)))

print("✅ test_resolver_subframe.lua passed")
