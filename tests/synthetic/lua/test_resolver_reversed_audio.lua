-- Reversed AUDIO clips must resolve to a playable entry, sample-accurate.
--
-- Today the resolver gates reverse handling on track_type=="VIDEO": a reversed
-- AUDIO clip (source_in_frame > source_out_frame) falls to the forward branch,
-- which hands pick_seq_range lo > hi → empty interval → NO entry → SILENCE.
-- This is the bug under test.
--
-- Domain reference (no code tracing): the forward case is pinned by
-- test_resolver_subframe.lua scenario A — an AUDIO clip over master frames
-- [2, 10) against a 48000Hz mref (source_in=0 file samples) at 24fps resolves
-- to file samples [4000, 20000): source_in=4000 (first played), source_out=20000
-- (one past the last played). A REVERSE clip covering that exact same region,
-- played last-sample-first, must therefore emit:
--   source_in  = highest played sample (inclusive) = 20000 - 1 = 19999
--   source_out = exclusive lower bound             =  4000 - 1 =  3999
-- and source_in > source_out so the playback engine derives a negative
-- conform ratio (backward decode). The played width equals the forward width.
--
-- The clip is stored in the reverse convention the DRP importer writes:
--   forward file-sample span [4000, 20000); reverse stores
--   source_in_native  = 19999 (= highest played sample, inclusive)
--   source_out_native =  3999 (= lowest played sample - 1, exclusive)
-- which compute_audio_clip_source converts to (master frame, subframe ticks):
--   19999 file samples @48k → ticks 79996 → frame 9, sub 7996
--    3999 file samples @48k → ticks 15996 → frame 1, sub 7996
-- (master_clock_hz=192000, tpf=8000, ticks_per_sample=4).

require("test_env")
local database = require("core.database")
local Sequence = require("models.sequence")

print("=== test_resolver_reversed_audio.lua ===")

local DB = "/tmp/jve/test_resolver_reversed_audio.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()

local SETTINGS = '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}'

assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'RevAudio', 'passthrough', '%s', 0, 0);
]], SETTINGS)))

-- Master (audio source) + outer edit sequence, both 24fps.
assert(db:exec([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('master', 'p', 'a.wav', 'master', 24, 1, NULL, 1920, 1080, 0, 0),
           ('edit',   'p', 'Edit',  'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
]]))
assert(db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
    VALUES ('master-a1', 'master', 'A1', 'AUDIO', 1),
           ('edit-a1',   'edit',   'A1', 'AUDIO', 1);
]]))
assert(db:exec([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_sample_rate, audio_channels,
        created_at, modified_at)
    VALUES ('med', 'p', 'a', '/tmp/jve/a.wav', 240, 24, 1, 48000, 1, 0, 0);
]]))
-- AUDIO mref: source_in=0 file samples, master frames [0, 240).
assert(db:exec([[
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr', 'p', 'master', 'master-a1', 'med', 0, 240, 0, 240,
            48000, 1, 1.0, 0, 0, 0);
]]))

-- Reversed AUDIO clip on the edit sequence, occupying outer frames [50, 58).
-- Stored in reverse convention (source_in_frame > source_out_frame) with the
-- sub-frame residuals the importer produces for file samples 19999 / 3999.
local OUTER_START = 50
local OUTER_DUR   = 8
assert(db:exec(string.format([[
    INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, name,
        sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, source_in_subframe, source_out_subframe,
        fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('c', 'p', 'edit', 'edit-a1', 'master', 'rev',
            %d, %d, 9, 1, 7996, 7996,
            'passthrough', 1, 1.0, 0, 0, 0);
]], OUTER_START, OUTER_DUR)))

require("test_env").touch_media_fixtures()

-- ── Resolve the outer range covering the clip ────────────────────────────
local entries = Sequence:pick_in_range("edit", OUTER_START, OUTER_START + OUTER_DUR, {
    recursing_into = {}, depth = 0, export_mode = false,
    project_fps_mismatch_policy = "passthrough",
})
local audio = {}
for _, e in ipairs(entries) do
    if e.media_kind == "audio" then audio[#audio + 1] = e end
end

-- ── Test 1: not silent ───────────────────────────────────────────────────
assert(#audio == 1, string.format(
    "reversed audio clip: expected 1 audio entry, got %d "
    .. "(0 = silence: resolver saw an empty reversed interval)", #audio))
local e = audio[1]
print(string.format("  entry: source_in=%s source_out=%s seq_start=%s dur=%s",
    tostring(e.source_in), tostring(e.source_out),
    tostring(e.sequence_start), tostring(e.duration)))

-- ── Test 2: reverse signal preserved (samples) ───────────────────────────
assert(e.source_in > e.source_out, string.format(
    "reversed audio entry must have source_in > source_out (samples) so the "
    .. "playback engine derives a negative conform ratio; got %s / %s",
    tostring(e.source_in), tostring(e.source_out)))

-- ── Test 3: sample-accurate boundaries (domain-derived) ──────────────────
assert(e.source_in == 19999, string.format(
    "highest played sample must be 19999 (= forward 20000 - 1); got %s",
    tostring(e.source_in)))
assert(e.source_out == 3999, string.format(
    "exclusive lower bound must be 3999 (= forward 4000 - 1); got %s",
    tostring(e.source_out)))

-- ── Test 4: outer placement ──────────────────────────────────────────────
assert(e.sequence_start == OUTER_START, string.format(
    "entry must start at outer frame %d, got %s", OUTER_START, tostring(e.sequence_start)))
assert(e.duration == OUTER_DUR, string.format(
    "entry duration must be %d, got %s", OUTER_DUR, tostring(e.duration)))

print("  ✓ reversed audio resolves to a sample-accurate backward entry")
print("✅ test_resolver_reversed_audio.lua passed")
