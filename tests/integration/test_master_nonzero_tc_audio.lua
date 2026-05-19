-- Integration test: master sequence at nonzero TC plays audio in source tab.
--
-- Regression for TSO 2026-05-16: SSE STARVED chunks=0 on master playback
-- because audio media_ref's `sequence_start_frame` was stored in SAMPLES
-- while the playhead arrived in master.fps VIDEO FRAMES. The overlap
-- check (playhead >= mr.sequence_start) never succeeded for non-zero-TC
-- masters, so resolve returned no audio entries → audio pump saw "gap"
-- → silence.
--
-- Post unification: audio MR's sequence_start_frame + duration_frames are
-- in master.fps frames (uniform with video MR); source_in_frame /
-- source_out_frame stay in file-natural samples (so C++ TMB's
-- `source_in - first_sample_tc` still lands on the right file sample).
-- Sub-frame BWF precision lives on the media row.
--
-- This test:
--   1. Patches a copy of bwf_stereo_mix_stub.wav so its BWF
--      `time_reference` is a known non-zero, sub-frame-off-grid value.
--   2. Probes the patched file via EMP (real C++ probe) — verifies
--      first_sample_tc reads back as the patched value.
--   3. Constructs a master sequence whose media row carries a non-zero
--      VIDEO TC origin (start_tc_value, start_tc_audio_samples) — i.e.
--      a synthetic dual-medium master with TC=01:00:00:00 (master.fps=24).
--   4. Calls Sequence:get_audio_at and :get_audio_in_range at the
--      master's start frame — asserts that audio entries come back
--      (NOT empty), with source_in in file-natural samples matching
--      the file's first_sample_tc.
--
-- Skips gracefully when run outside --test mode.

local ienv = require("integration.integration_test_env")
local EMP = ienv.require_emp()

print("=== test_master_nonzero_tc_audio.lua ===")

local test_env = require("test_env")

-- ───────────────────────────────────────────────────────────────────
-- Step 1: patch a BWF fixture to carry a known sub-frame-off-grid TC.
-- ───────────────────────────────────────────────────────────────────
local SRC_BWF = test_env.resolve_repo_path(
    "tests/fixtures/resolve/bwf_stereo_mix_stub.wav")
local f_src = io.open(SRC_BWF, "rb")
assert(f_src, "bwf_stereo_mix_stub.wav fixture missing at " .. SRC_BWF)
local content = f_src:read("*a")
f_src:close()

-- bext data starts at file offset 0x2C (header at 0x24, +8 for ID+size).
-- time_reference (uint64 LE) lives at +338 within bext data:
--   Description(256) + Originator(32) + OriginatorReference(32)
--   + OriginationDate(10) + OriginationTime(8) = 338.
local BEXT_DATA_START = 0x2C
local TIME_REFERENCE_OFFSET = BEXT_DATA_START + 338

-- TC=01:00:00:00 at 24fps == 86400 video frames == 172800000 audio
-- samples at 48kHz. Add 13 samples to land sub-frame off-grid (the
-- canonical BWF dual-system case). Anything between 1 and 1999 works;
-- 13 is small enough to be unmistakably below a frame boundary.
local FPS_NUM, FPS_DEN = 24, 1
local SR = 48000
local VIDEO_TC_FRAMES = 86400
local AUDIO_TC_SAMPLES = VIDEO_TC_FRAMES * SR * FPS_DEN / FPS_NUM + 13
assert(AUDIO_TC_SAMPLES == 172800013, "math sanity")

-- Pack uint64 little-endian.
local function pack_u64_le(n)
    local bytes = {}
    for i = 0, 7 do
        bytes[i + 1] = string.char(math.floor(n / (256 ^ i)) % 256)
    end
    return table.concat(bytes)
end

local patched = content:sub(1, TIME_REFERENCE_OFFSET)
    .. pack_u64_le(AUDIO_TC_SAMPLES)
    .. content:sub(TIME_REFERENCE_OFFSET + 9)

local PATCHED_PATH = string.format("/tmp/jve_master_nonzero_tc_%d.wav", os.time())
local f_dst = assert(io.open(PATCHED_PATH, "wb"))
f_dst:write(patched); f_dst:close()
print(string.format("  patched fixture → %s (time_reference=%d samples)",
    PATCHED_PATH, AUDIO_TC_SAMPLES))

-- ───────────────────────────────────────────────────────────────────
-- Step 2: probe via real EMP, verify the patched TC reads back.
-- ───────────────────────────────────────────────────────────────────
local probe = EMP.MEDIA_FILE_PROBE(PATCHED_PATH)
assert(probe, "EMP.MEDIA_FILE_PROBE failed for patched fixture")
assert(probe.bwf_time_reference == AUDIO_TC_SAMPLES, string.format(
    "BWF time_reference roundtrip failed: got %d, expected %d",
    probe.bwf_time_reference, AUDIO_TC_SAMPLES))
assert(probe.first_sample_tc == AUDIO_TC_SAMPLES, string.format(
    "first_sample_tc must equal patched time_reference: got %d, expected %d",
    probe.first_sample_tc, AUDIO_TC_SAMPLES))
print(string.format("  PASS: EMP probe returned first_sample_tc=%d", probe.first_sample_tc))

-- ───────────────────────────────────────────────────────────────────
-- Step 3: build a dual-medium master sequence whose video TC is non-zero.
-- The patched WAV is audio-only, so we hand-craft a media row that
-- claims to also carry video at 24fps (width/height > 0). ensure_master
-- then exercises the audio-MR write path with both start_tc_value and
-- start_tc_audio_samples populated — the dual-medium case that broke.
-- ───────────────────────────────────────────────────────────────────
local DB_PATH = "/tmp/jve/test_master_nonzero_tc_audio.jvp"
os.execute("mkdir -p /tmp/jve")
os.remove(DB_PATH); os.remove(DB_PATH .. "-wal"); os.remove(DB_PATH .. "-shm")

local database = require("core.database")
assert(database.init(DB_PATH), "database.init failed")
local db = database.get_connection()
assert(db, "no db connection")

local project_id = "p-master-tc"
local media_id   = "m-master-tc"
local now = os.time()
assert(db:exec(string.format(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('%s', 'master-tc test', 'passthrough', %d, %d)",
    project_id, now, now)))

-- Media row: dual-medium claim (width/height nonzero) + populated TC
-- metadata + audio fields. duration_frames in video frames @ 24fps.
local _json = require("dkjson")
local meta = {
    start_tc_value         = VIDEO_TC_FRAMES,
    start_tc_rate          = FPS_NUM,
    start_tc_audio_samples = AUDIO_TC_SAMPLES,
    start_tc_audio_rate    = SR,
}
local DUR_FRAMES = 720  -- 30s @ 24fps — enough range for the resolver
assert(db:exec(string.format(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, audio_channels, audio_sample_rate, "
    .. "width, height, metadata, created_at, modified_at) "
    .. "VALUES ('%s', '%s', 'mtc.mov', '%s', %d, %d, %d, 2, %d, 1920, 1080, "
    .. "'%s', %d, %d)",
    media_id, project_id, PATCHED_PATH, DUR_FRAMES,
    FPS_NUM, FPS_DEN, SR,
    _json.encode(meta):gsub("'", "''"), now, now)))

local Sequence = require("models.sequence")
local seq_id = Sequence.ensure_master(media_id, project_id)
assert(seq_id, "ensure_master returned no id")
local seq = Sequence.load(seq_id)
assert(seq, "Sequence.load returned nil for master")
assert(seq.start_timecode_frame == VIDEO_TC_FRAMES, string.format(
    "master start_timecode_frame: got %s, expected %d",
    tostring(seq.start_timecode_frame), VIDEO_TC_FRAMES))
print(string.format("  PASS: master.start_timecode_frame=%d", seq.start_timecode_frame))

-- ───────────────────────────────────────────────────────────────────
-- Step 4: inspect the audio media_ref's column units (placement uniform
--         with video; source_in still in file-natural samples).
-- ───────────────────────────────────────────────────────────────────
local mr_stmt = assert(db:prepare(
    "SELECT mr.id, mr.sequence_start_frame, mr.duration_frames, "
    .. "mr.source_in_frame, mr.source_out_frame, t.track_type "
    .. "FROM media_refs mr JOIN tracks t ON mr.track_id = t.id "
    .. "WHERE mr.owner_sequence_id = ? AND t.track_type = 'AUDIO' "
    .. "ORDER BY t.track_index ASC LIMIT 1"))
mr_stmt:bind_value(1, seq_id)
assert(mr_stmt:exec() and mr_stmt:next(), "no audio media_ref for master")
local mr_id            = mr_stmt:value(0)
local mr_tl_start      = mr_stmt:value(1)
local mr_dur           = mr_stmt:value(2)
local mr_src_in        = mr_stmt:value(3)
local mr_src_out       = mr_stmt:value(4)
mr_stmt:finalize()

assert(mr_tl_start == VIDEO_TC_FRAMES, string.format(
    "audio MR %s sequence_start_frame should be in master.fps frames "
    .. "(= video TC origin = %d); got %d. Pre-unification this would have "
    .. "been the audio-sample anchor (%d) — that was the bug.",
    mr_id, VIDEO_TC_FRAMES, mr_tl_start, AUDIO_TC_SAMPLES))
assert(mr_dur == DUR_FRAMES, string.format(
    "audio MR duration_frames should be %d (master.fps frames, matches "
    .. "video duration), got %d", DUR_FRAMES, mr_dur))
assert(mr_src_in == AUDIO_TC_SAMPLES, string.format(
    "audio MR source_in_frame should be the file's audio TC origin in "
    .. "samples (%d); got %d. C++ TMB subtracts first_sample_tc against "
    .. "this to compute file_pos, so it MUST stay in samples.",
    AUDIO_TC_SAMPLES, mr_src_in))
local expected_src_out = AUDIO_TC_SAMPLES + math.floor(DUR_FRAMES * SR * FPS_DEN / FPS_NUM + 0.5)
assert(mr_src_out == expected_src_out, string.format(
    "audio MR source_out_frame should be source_in + audio_duration_samples "
    .. "(= %d); got %d", expected_src_out, mr_src_out))
print("  PASS: audio MR placement in master.fps frames; source range in samples")

-- ───────────────────────────────────────────────────────────────────
-- Step 5: the regression check — get_audio_at at the master's start
-- must return audio entries. Pre-fix this returned empty because the
-- audio MR's sequence_start (samples) was compared against the playhead
-- (frames) and never overlapped.
-- ───────────────────────────────────────────────────────────────────
local entries_at = seq:get_audio_at(VIDEO_TC_FRAMES)
assert(type(entries_at) == "table",
    "get_audio_at must return a table")
assert(#entries_at > 0, string.format(
    "get_audio_at(%d) returned no entries on a nonzero-TC master — "
    .. "this is the regression bug (TSO 2026-05-16)", VIDEO_TC_FRAMES))
local entry_at = entries_at[1]
assert(entry_at.source_frame == AUDIO_TC_SAMPLES, string.format(
    "audio entry source_frame at master start must equal file's first "
    .. "audio sample TC (%d samples); got %s. The resolver converts the "
    .. "master.fps frame offset (0 at start) to samples via sr/fps and "
    .. "adds it to source_in to land here.",
    AUDIO_TC_SAMPLES, tostring(entry_at.source_frame)))
local expected_us_at = math.floor(AUDIO_TC_SAMPLES * 1000000 / SR)
assert(entry_at.source_time_us == expected_us_at, string.format(
    "audio entry source_time_us at master start: got %s, expected %d",
    tostring(entry_at.source_time_us), expected_us_at))
print(string.format("  PASS: get_audio_at(%d) → entry at sample %d (%dus)",
    VIDEO_TC_FRAMES, entry_at.source_frame, entry_at.source_time_us))

-- And one frame past start — confirms offset conversion (1 master frame
-- @ 24fps = 2000 samples @ 48kHz). source_frame should land 2000 ahead.
local entries_at_p1 = seq:get_audio_at(VIDEO_TC_FRAMES + 1)
assert(#entries_at_p1 > 0, "get_audio_at(start+1) returned no entries")
local SAMPLES_PER_FRAME = SR * FPS_DEN / FPS_NUM  -- = 2000
assert(entries_at_p1[1].source_frame == AUDIO_TC_SAMPLES + SAMPLES_PER_FRAME,
    string.format(
        "one frame past start: source_frame should advance by %d samples; "
        .. "got %d (expected %d)",
        SAMPLES_PER_FRAME, entries_at_p1[1].source_frame,
        AUDIO_TC_SAMPLES + SAMPLES_PER_FRAME))
print(string.format("  PASS: get_audio_at(start+1) → +%d samples", SAMPLES_PER_FRAME))

-- ───────────────────────────────────────────────────────────────────
-- Step 6: get_audio_in_range covers the full active range and produces
-- file-relative source values converted via sr/fps in resolve_master_leaf.
-- ───────────────────────────────────────────────────────────────────
local RANGE_LO = VIDEO_TC_FRAMES
local RANGE_HI = VIDEO_TC_FRAMES + 10  -- 10 master frames
local entries_range = seq:get_audio_in_range(RANGE_LO, RANGE_HI)
assert(type(entries_range) == "table",
    "get_audio_in_range must return a table")
assert(#entries_range > 0, string.format(
    "get_audio_in_range(%d, %d) returned no entries on a nonzero-TC master "
    .. "— resolver bug", RANGE_LO, RANGE_HI))

-- master-leaf resolver returns each media_ref at FULL media extent
-- (pick_resolve_bounds widens to [0, math.huge) for masters and
-- filter_and_finalize re-overlap-filters by timeline coords). So the
-- audio entry's source_in/out span the entire file in samples.
local e_first
for _, e in ipairs(entries_range) do
    if e.media_kind == "audio" then e_first = e; break end
end
assert(e_first, "no audio entry in resolve_in_range result")
assert(e_first.source_in == AUDIO_TC_SAMPLES, string.format(
    "audio entry source_in must equal file's audio TC origin (%d "
    .. "samples); got %s. The resolver converts the master.fps frame "
    .. "offset to samples via sr/fps before adding to source_in.",
    AUDIO_TC_SAMPLES, tostring(e_first.source_in)))
local full_dur_samples = math.floor(DUR_FRAMES * SR * FPS_DEN / FPS_NUM + 0.5)
local expected_so = AUDIO_TC_SAMPLES + full_dur_samples
assert(e_first.source_out == expected_so, string.format(
    "audio entry source_out must equal source_in + full media "
    .. "duration in samples (%d + %d = %d); got %s",
    AUDIO_TC_SAMPLES, full_dur_samples, expected_so,
    tostring(e_first.source_out)))
-- And the entry's sequence_start/duration are in master.fps frames
-- (filter_and_finalize keeps those as the FULL MR extent for masters).
assert(e_first.sequence_start == VIDEO_TC_FRAMES, string.format(
    "audio entry sequence_start (master.fps frames): got %s, expected %d",
    tostring(e_first.sequence_start), VIDEO_TC_FRAMES))
assert(e_first.duration == DUR_FRAMES, string.format(
    "audio entry duration (master.fps frames): got %s, expected %d",
    tostring(e_first.duration), DUR_FRAMES))
print(string.format("  PASS: resolve_in_range entry → "
    .. "timeline=[%d, +%d) master.fps frames; source=[%d, %d) samples",
    e_first.sequence_start, e_first.duration,
    e_first.source_in, e_first.source_out))

os.remove(PATCHED_PATH)
print("✅ test_master_nonzero_tc_audio.lua passed")
