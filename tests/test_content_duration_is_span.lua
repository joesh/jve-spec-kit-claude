#!/usr/bin/env luajit
--- Sequence:content_duration() must return a SPAN, not an absolute end.
---
--- Symmetric to test_master_content_end_absolute_tc.lua: that test pins
--- `compute_content_end` as an ABSOLUTE end frame in TC space (for
--- playback bounds). This test pins `content_duration` as the
--- complementary SPAN (length) used by mark/playhead bounds checks and
--- by Overwrite resample math (place_shared.compute_owner_duration).
---
--- The two APIs serve different consumers:
---   compute_content_end → max(start+dur)   — absolute, in sequence
---                                            timeline-frame space.
---   content_duration    → max(end) - start — span, unit-of-length.
---
--- Before this regression test, the non-master branch of content_duration
--- delegated to compute_content_end() — accidentally correct only when
--- start_timecode_frame == 0. A record sequence imported at 01:00:00:00
--- (start_tc=90000 @ 25fps) with one clip at timeline_start=90000 dur=25
--- would report content_duration=90025 (it's the absolute end frame),
--- making set_in/set_out/set_playhead bounds far too permissive.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local Sequence = require("models.sequence")
local uuid     = require("uuid")

print("=== test_content_duration_is_span.lua ===")

local DB = "/tmp/jve/test_content_duration_is_span.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', %d, %d);
]], now, now))

-- Non-master sequence starting at 01:00:00:00 @ 25 fps.
local FPS_NUM   = 25
local START_TC  = 3600 * FPS_NUM  -- 90000 frames
local CLIP_DUR  = 25
local CLIP_START = START_TC       -- placed at sequence head

local seq_id = "seq1"
local seq_create = Sequence.create("Seq", "proj",
    { fps_numerator = FPS_NUM, fps_denominator = 1 },
    1920, 1080,
    { kind = "sequence", id = seq_id, audio_sample_rate = 48000,
      start_timecode_frame = START_TC })
assert(seq_create:save(), "save sequence")

local track_id = "v1"
db:exec(string.format([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('%s', '%s', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], track_id, seq_id))

-- Placeholder master so the clip's sequence_id FK resolves; we don't
-- exercise nested-sequence resolution here.
local placeholder_master = Sequence.create("PH", "proj",
    { fps_numerator = FPS_NUM, fps_denominator = 1 },
    1920, 1080,
    { kind = "master", id = "_v13_placeholder_master" })
assert(placeholder_master:save(), "save placeholder master")

-- Clip references a placeholder master sequence (we're only testing the
-- owner non-master's content_duration; nested-sequence resolution is not
-- exercised).
local clip_id = uuid.generate()
db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, sequence_id,
        owner_sequence_id, timeline_start_frame, duration_frames,
        source_in_frame, source_out_frame, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        volume, playhead_frame)
    VALUES ('%s', 'proj', 'Clip', '%s', '_v13_placeholder_master', '%s',
        %d, %d, 0, %d, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], clip_id, track_id, seq_id,
    CLIP_START, CLIP_DUR, CLIP_DUR, now, now))

local seq = Sequence.load(seq_id)
assert(seq, "loaded non-master seq is nil")
assert(not seq:is_master(), "expected non-master")

local end_frame = seq:compute_content_end()
assert(end_frame == CLIP_START + CLIP_DUR, string.format(
    "compute_content_end: got %d, expected %d (absolute end)",
    end_frame, CLIP_START + CLIP_DUR))

local span = seq:content_duration()
print(string.format("content_duration: got %d, expected %d (clip dur)",
    span, CLIP_DUR))
assert(span == CLIP_DUR, string.format(
    "content_duration must be a SPAN (length): got %d, expected %d. "
    .. "Reading absolute end (%d) as a duration makes set_in/set_out/"
    .. "set_playhead bounds end_frame = start + (start + span), which "
    .. "is too permissive by `start` frames for any non-master sequence "
    .. "with start_timecode_frame > 0.",
    span, CLIP_DUR, CLIP_START + CLIP_DUR))

print("✅ test_content_duration_is_span.lua passed")
