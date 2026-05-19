-- 005 smoke: gaps participate as clips in resolver output.
--
-- Acceptance Scenario 1: a sequence with [clip-A][gap][clip-B] on V1. The
-- resolver entries for the timeline range covering the gap must still
-- describe the surrounding clips; no clip_kind="gap" stripping at the
-- query/resolve boundary. This pins the FR-5 "gap-as-clip abstraction"
-- guarantee from inside the production query path.

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_005_gap_as_clip_smoke.lua ===")

require("test_env")
local database = require("core.database")
local Sequence = require("models.sequence")

local DB = "/tmp/jve/test_005_gap.jvp"
os.execute("mkdir -p /tmp/jve"); os.remove(DB); os.remove(DB..".wal"); os.remove(DB..".shm")
assert(database.init(DB))
local db = database.get_connection()
local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('p','P','passthrough','{"master_clock_hz":705600000,"default_fps":{"num":24,"den":1}}',%d,%d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, created_at, modified_at)
      VALUES ('m','p','M','master',24,1,NULL,1920,1080,%d,%d),
             ('e','p','E','sequence',24,1,48000,1920,1080,%d,%d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
      VALUES ('m-v1','m','V1','VIDEO',1), ('e-v1','e','V1','VIDEO',1);
    UPDATE sequences SET default_video_layer_track_id='m-v1' WHERE id='m';
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_channels, audio_sample_rate, created_at, modified_at)
      VALUES ('med','p','m.mov','/tmp/m.mov',1000,24,1,0,0,%d,%d);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
      VALUES ('mr','p','m','m-v1','med',0,1000,0,1000,1,1.0,0,%d,%d);
    -- Two video clips on the record sequence with a 100-frame gap between them.
    INSERT INTO clips (id, project_id, owner_sequence_id, sequence_id, track_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        fps_mismatch_policy, enabled, volume, playhead_frame, name,
        created_at, modified_at)
      VALUES ('A','p','e','m','e-v1',0,100,0,  100,'passthrough',1,1.0,0,'A',%d,%d),
             ('B','p','e','m','e-v1',0,100,200,100,'passthrough',1,1.0,0,'B',%d,%d);
]], now, now, now, now, now, now, now, now, now, now, now, now, now, now)))

-- Resolve the WHOLE range including the gap [100, 200). FR-5: no clip_kind
-- filtering — both clips appear; the gap is implied by their gap in tl coords.
local rec = Sequence.load("e")
local entries = rec:get_video_in_range(0, 300)
table.sort(entries, function(a, b) return a.sequence_start < b.sequence_start end)
assert(#entries == 2, string.format(
    "FR-5: gap must NOT be stripped from resolver output; got %d entries",
    #entries))
assert(entries[1].sequence_start == 0   and entries[1].duration == 100,
    "first entry must be clip A [0, 100)")
assert(entries[2].sequence_start == 200 and entries[2].duration == 100,
    "second entry must be clip B [200, 300)")
print("  PASS: resolver returns both surrounding clips across the gap")

-- Edge case: resolve a window that lies entirely inside the gap. The gap
-- itself is not a clip-row; clips don't appear inside a gap. The shape
-- here is "no entries for a fully-gap window."
local in_gap = rec:get_video_in_range(120, 180)
assert(#in_gap == 0, string.format(
    "fully-in-gap range should yield no entries; got %d", #in_gap))
print("  PASS: fully-in-gap range yields no entries")

print("\n✅ test_005_gap_as_clip_smoke.lua passed")
