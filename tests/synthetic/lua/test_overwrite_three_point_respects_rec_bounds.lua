#!/usr/bin/env luajit
--- Three-point Overwrite (rec_in + rec_out + src_in) MUST cover exactly
--- [rec_in, rec_out) on the timeline — not run past rec_out.
---
--- Domain (matches every NLE since the early-90s Avid model):
---   given any 3 of (src_in, src_out, rec_in, rec_out), the 4th is
---   computed. When the user marked the record window and only an
---   IN on the source, the system computes src_out from rec duration
---   and the source-out implicitly is src_in + (rec_out - rec_in) at
---   the appropriate timebase. The placed clip's record-side span is
---   the marked record window, no more.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
local test_env = require("test_env")
local database = require("core.database")
local Sequence = require("models.sequence")
local command_manager = require("core.command_manager")

print("=== test_overwrite_three_point_respects_rec_bounds.lua ===")

local DB = "/tmp/jve/test_overwrite_three_point_respects_rec_bounds.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'Test', 'resample',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
            %d, %d);
]], now, now))

-- Source media: 24fps, plenty long. TC origin nonzero to keep source_in
-- math nontrivial (no zero-origin masquerading).
local SRC_FPS = 24
local SRC_DUR = 5000     -- ~3m28s @ 24fps; bigger than any rec window we mark
local SRC_TC_ORIGIN = 24 * 60 * 10   -- 10 min @ 24fps = 14400

test_env.create_test_media({
    id = "media_src", project_id = "proj",
    file_path = "/tmp/jve/src.mov", name = "SRC",
    duration_frames = SRC_DUR,
    fps_numerator = SRC_FPS, fps_denominator = 1,
    audio_channels = 2, audio_sample_rate = 48000,
    width = 1920, height = 1080,
    start_tc = SRC_TC_ORIGIN,
})
local src_seq_id = Sequence.ensure_master("media_src", "proj")

-- Same-fps record sequence — keep rate-conversion out of the assertion.
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, start_timecode_frame, playhead_frame,
        view_start_frame, view_duration_frames,
        mark_in_frame, mark_out_frame,
        created_at, modified_at)
    VALUES ('rec', 'proj', 'Rec', 'sequence', %d, 1, 48000,
            1920, 1080, 0, 0, 0, 1000,
            500, 700,
            %d, %d);
]], SRC_FPS, now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES
      ('rv1', 'rec', 'V1', 'VIDEO', 1, 1),
      ('ra1', 'rec', 'A1', 'AUDIO', 1, 1),
      ('ra2', 'rec', 'A2', 'AUDIO', 2, 1);
]])

-- Set a src IN on the master. mark_in/out live on sequences row in TC
-- space. Source mark-in is SRC_TC_ORIGIN + 50 (50 frames into the file).
local SRC_MARK_IN = SRC_TC_ORIGIN + 50
db:exec(string.format(
    "UPDATE sequences SET mark_in_frame = %d WHERE id = '%s'",
    SRC_MARK_IN, src_seq_id))

command_manager.init("rec", "proj")

-- Three-point edit: rec_in=500, rec_out=700 (rec duration = 200 frames);
-- src_in=50 file-relative. Expected placed-clip span: [500, 700).
local REC_IN, REC_OUT = 500, 700
local EXPECTED_DURATION = REC_OUT - REC_IN

local result = command_manager.execute("Overwrite", {
    project_id            = "proj",
    sequence_id           = "rec",
    source_sequence_id    = src_seq_id,
    target_video_track_id = "rv1",
    -- Intentionally omit sequence_start_frame so the command resolves
    -- the start from rec_in (not playhead) per three-point semantics.
})
assert(result and result.success, "Overwrite must succeed: "
    .. tostring(result and result.error_message))

-- Inspect the V1 clip.
local stmt = db:prepare(
    "SELECT id, sequence_start_frame, duration_frames FROM clips "
    .. "WHERE track_id = 'rv1'")
assert(stmt and stmt:exec() and stmt:next(),
    "expected exactly one V1 clip after Overwrite")
local clip_id = stmt:value(0)
local start   = stmt:value(1)
local dur     = stmt:value(2)
stmt:finalize()

print(string.format("V1 clip: id=%s start=%d duration=%d (expected start=%d duration=%d)",
    clip_id, start, dur, REC_IN, EXPECTED_DURATION))

assert(start == REC_IN, string.format(
    "Overwrite start_frame must equal rec_in (%d), not playhead/0; got %d. "
    .. "Three-point edit places the clip at the record mark-in.",
    REC_IN, start))
assert(dur == EXPECTED_DURATION, string.format(
    "Overwrite duration must equal rec_out - rec_in (%d), not the source's "
    .. "full duration; got %d. Three-point edit caps the placed span at "
    .. "the marked record window.",
    EXPECTED_DURATION, dur))

print("✅ test_overwrite_three_point_respects_rec_bounds.lua passed")
