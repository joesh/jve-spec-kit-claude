-- Reversed video clips must resolve to a playable entry, not black.
--
-- Domain requirement: when a clip plays source material backward
-- (source_in > source_out after DRP import swap), the resolver must:
--   1. Return an entry for the clip (no entry → black frame in monitor)
--   2. Carry source_in > source_out in the entry so the playback engine
--      computes a negative speed_ratio (backward decode order)
--   3. Place the entry at the correct outer timeline position
--
-- Regression for the resolver treating a backward [source_in, source_out)
-- interval as an empty interval, finding no overlapping media_refs.

require("test_env")

local database   = require("core.database")
local Sequence   = require("models.sequence")
local tmb_clip_builder = require("core.playback.tmb_clip_builder")

print("=== test_resolver_reversed_clip.lua ===")

local DB = "/tmp/jve/test_resolver_reversed_clip.db"
os.remove(DB)
assert(database.init(DB))
local db = database.get_connection()

-- Project at 25fps (matches the gold timeline)
assert(db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'Rev', 'passthrough',
            '{"master_clock_hz":192000,"default_fps":{"num":25,"den":1}}',
            0, 0);
]]))

-- Outer edit sequence (25fps)
assert(db:exec([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
                          audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('edit', 'p', 'Edit', 'sequence', 25, 1, 48000, 1920, 1080, 0, 0);
]]))
assert(db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
    VALUES ('edit-v1', 'edit', 'V1', 'VIDEO', 1);
]]))

-- Master sequence (25fps) — simulates a camera-original mediaseq
-- Media file contains frames 100..299 (file_in=100, file_out=300; 200 frames total)
assert(db:exec([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
                          audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('master', 'p', 'A001_C001.mov', 'master', 25, 1, NULL, 1920, 1080, 0, 0);
]]))
assert(db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
    VALUES ('master-v1', 'master', 'V1', 'VIDEO', 1);
]]))
assert(db:exec([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
                      fps_numerator, fps_denominator, created_at, modified_at)
    VALUES ('med', 'p', 'A001_C001.mov', '/tmp/jve/A001_C001.mov', 200, 25, 1, 0, 0);
]]))
-- media_ref covers frames [100, 300) in the master's absolute TC space
assert(db:exec([[
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
                           source_in_frame, source_out_frame,
                           sequence_start_frame, duration_frames,
                           enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr', 'p', 'master', 'master-v1', 'med',
            100, 300,
            100, 200,
            1, 1.0, 100, 0, 0);
]]))

-- ─── Reversed outer clip ───────────────────────────────────────────────────
-- The clip occupies outer frames [50, 140) — 90 frames.
-- It is REVERSED: source_in=190 (first frame to display) > source_out=100 (exclusive lower bound).
-- This simulates what the DRP importer writes after swapping source_in/source_out
-- when clip_speed < 0.
-- The frames to display: 190, 189, ..., 101 (90 frames), all within the
-- media_ref's [100, 300) range.
local OUTER_START  = 50
local OUTER_DUR    = 90
local SOURCE_IN    = 190   -- first frame to decode (reversed entry point)
local SOURCE_OUT   = 100   -- exclusive lower bound (SOURCE_OUT+1 = 101 = last frame)
assert(db:exec(string.format([[
    INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id,
                      name, sequence_start_frame, duration_frames,
                      source_in_frame, source_out_frame,
                      fps_mismatch_policy, enabled, volume,
                      playhead_frame, created_at, modified_at)
    VALUES ('c', 'p', 'edit', 'edit-v1', 'master',
            'rev', %d, %d,
            %d, %d,
            'passthrough', 1, 1.0, %d, 0, 0);
]], OUTER_START, OUTER_DUR, SOURCE_IN, SOURCE_OUT, OUTER_START)))

require("test_env").touch_media_fixtures()

-- ─── Test 1: resolver must return an entry (not empty) ────────────────────
local seq = Sequence.load("edit", "p")
assert(seq, "failed to load edit sequence")

local entries = seq:get_video_in_range(OUTER_START, OUTER_START + OUTER_DUR)
assert(#entries == 1, string.format(
    "reversed clip: expected 1 entry from resolver, got %d "
    .. "(black frame = 0 entries; resolver saw empty interval [%d,%d))",
    #entries, SOURCE_IN, SOURCE_OUT))
print("  ✓ resolver returns 1 entry for reversed clip (not black)")

-- ─── Test 2: entry carries reversed source convention ─────────────────────
local e = entries[1]
assert(e.source_in > e.source_out, string.format(
    "reversed clip entry must have source_in > source_out "
    .. "(got source_in=%s, source_out=%s)",
    tostring(e.source_in), tostring(e.source_out)))
print("  ✓ entry.source_in > entry.source_out (reversed convention preserved)")

-- ─── Test 3: compute_video_speed_ratio yields -1.0 ────────────────────────
local speed = tmb_clip_builder.compute_video_speed_ratio(e)
assert(math.abs(speed + 1.0) < 0.001, string.format(
    "reversed clip: speed_ratio must be -1.0, got %.4f", speed))
print("  ✓ compute_video_speed_ratio = -1.0 (backward decode)")

-- ─── Test 4: entry placed at the correct outer timeline position ───────────
assert(e.sequence_start == OUTER_START, string.format(
    "reversed clip entry must start at outer frame %d, got %d",
    OUTER_START, e.sequence_start))
assert(e.duration == OUTER_DUR, string.format(
    "reversed clip entry must have duration %d, got %d",
    OUTER_DUR, e.duration))
print(string.format("  ✓ entry placed at outer [%d, %d) correctly",
    e.sequence_start, e.sequence_start + e.duration))

-- ─── Test 5: source_in matches clip's source_in (first frame to decode) ──
assert(e.source_in == SOURCE_IN, string.format(
    "entry.source_in must equal clip's SOURCE_IN (%d), got %d",
    SOURCE_IN, e.source_in))
assert(e.source_out == SOURCE_OUT, string.format(
    "entry.source_out must equal clip's SOURCE_OUT (%d), got %d",
    SOURCE_OUT, e.source_out))
print(string.format("  ✓ source range preserved: source_in=%d, source_out=%d",
    e.source_in, e.source_out))

-- ─── Test 6: the clip plays exactly the right source frames, backward ─────
-- Domain (not the decode formula): a reversed clip shows the same frames a
-- forward clip of this span would, last-first. The highest played frame is the
-- entry (source_in = 190); the lowest is the frame just above the exclusive
-- lower bound (source_out + 1 = 101). For a 1× reverse the number of distinct
-- played frames equals the timeline duration. These endpoints are what the
-- viewer sees first and last — derived from the span, never by re-applying
-- source_in + offset × speed (that would just verify the formula with itself).
local highest_played = e.source_in        -- first frame shown (clip entry)
local lowest_played  = e.source_out + 1   -- last frame shown (exclusive bound + 1)
assert(highest_played == 190, string.format(
    "highest played source frame must be 190 (clip entry), got %d", highest_played))
assert(lowest_played == 101, string.format(
    "lowest played source frame must be 101 (source_out+1), got %d", lowest_played))
assert(highest_played - lowest_played + 1 == OUTER_DUR, string.format(
    "number of played frames must equal duration %d, got %d",
    OUTER_DUR, highest_played - lowest_played + 1))
print(string.format("  ✓ plays source [%d..%d] backward (%d frames = duration)",
    lowest_played, highest_played, OUTER_DUR))

print("✅ test_resolver_reversed_clip.lua passed")
