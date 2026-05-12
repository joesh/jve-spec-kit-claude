#!/usr/bin/env luajit

-- Regression: Overwrite invoked from F10/keyboard (no marks, no explicit
-- duration_frames or timeline_start_frame) must produce a clip whose
-- duration matches the source master's native video duration in record
-- frames.
--
-- Reported by user 2026-05-12: Overwrite of a 1m56s @ 24fps masterclip
-- into a 25fps record produced a clip spanning ~14 hours of timeline.
-- This is a unit-conversion / mark-leak bug somewhere on the path.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
local test_env = require("test_env")

local database        = require("core.database")
local Sequence        = require("models.sequence")
local command_manager = require("core.command_manager")

print("=== test_overwrite_duration_no_marks.lua ===")

local DB = "/tmp/jve/test_overwrite_duration_no_marks.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'Test', 'resample', %d, %d);
]], now, now))

-- A023-like source media: 1m56s @ 24fps with TC origin like the user's file.
-- 1m56s @ 24fps = 116 * 24 = 2784 frames.
local SRC_FPS    = 24
local SRC_DUR    = 2784
local SRC_TC_ORIGIN_24 = (13*3600 + 52*60 + 29) * 24 + 7  -- 13:52:29:07 @ 24fps
local SAMPLE_RATE = 48000

test_env.create_test_media({
    id = "media_a023",
    project_id = "proj",
    file_path = "/tmp/jve/a023.mov",
    name = "A023",
    duration_frames = SRC_DUR,
    fps_numerator = SRC_FPS,
    fps_denominator = 1,
    audio_channels = 2,
    audio_sample_rate = SAMPLE_RATE,
    width = 1920,
    height = 1080,
    start_tc = SRC_TC_ORIGIN_24,
})

local src_seq_id = Sequence.ensure_master("media_a023", "proj")

-- Record sequence at 25fps, like the user's gold timeline.
local REC_FPS = 25
local REC_TC_ORIGIN_25 = (0*3600 + 59*60 + 50) * 25  -- 00:59:50:00 @ 25fps
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, start_timecode_frame, playhead_frame,
        view_start_frame, view_duration_frames, created_at, modified_at)
    VALUES ('rec', 'proj', 'Gold', 'sequence', %d, 1, %d, 1920, 1080,
            %d, 0, 0, 15000, %d, %d);
]], REC_FPS, SAMPLE_RATE, REC_TC_ORIGIN_25, now, now))

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES
      ('rv1', 'rec', 'V1', 'VIDEO', 1, 1),
      ('ra1', 'rec', 'A1', 'AUDIO', 1, 1),
      ('ra2', 'rec', 'A2', 'AUDIO', 2, 1);
]])

command_manager.init('rec', 'proj')

-- Expected: source native video duration is 2784 frames @ 24fps = 116s.
-- In record's 25fps timebase: 116 * 25 = 2900 frames (resample policy).
local EXPECTED_DUR_IN_REC = math.floor(SRC_DUR * REC_FPS / SRC_FPS + 0.5)
print(string.format("Expected duration in rec frames: %d", EXPECTED_DUR_IN_REC))

local result = command_manager.execute("Overwrite", {
    project_id            = "proj",
    sequence_id           = "rec",
    source_sequence_id    = src_seq_id,
    timeline_start_frame  = 0,
    target_video_track_id = "rv1",
})
assert(result and result.success,
    "Overwrite must succeed: " .. tostring(result and result.error_message))

-- Inspect created V1 clip
local stmt = db:prepare(
    "SELECT id, duration_frames, timeline_start_frame FROM clips "
    .. "WHERE track_id = 'rv1'")
assert(stmt and stmt:exec() and stmt:next(),
    "expected exactly one V1 clip after Overwrite")
local clip_id = stmt:value(0)
local dur     = stmt:value(1)
local start   = stmt:value(2)
stmt:finalize()

print(string.format("V1 clip: id=%s start=%d duration=%d",
    clip_id, start, dur))

-- The duration must be on the order of seconds, not hours. Reasonable
-- sanity bound: ≤ 2× expected. The reported bug produced ~1.25M frames
-- (≈ 14 h @ 25fps) for a 2900-frame source.
assert(dur > 0,
    string.format("V1 clip duration must be > 0 (got %d)", dur))
assert(dur <= EXPECTED_DUR_IN_REC * 2,
    string.format("V1 clip duration is wildly off: got %d, expected ~%d "
        .. "(>%d× expected — likely unit-conversion bug)",
        dur, EXPECTED_DUR_IN_REC, math.floor(dur / EXPECTED_DUR_IN_REC)))

-- And tighter: must equal expected exactly (resample policy on integers).
assert(dur == EXPECTED_DUR_IN_REC,
    string.format("V1 clip duration mismatch: got %d, expected %d",
        dur, EXPECTED_DUR_IN_REC))

print("✅ test_overwrite_duration_no_marks.lua passed")
