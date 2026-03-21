#!/usr/bin/env luajit

-- Test: DRP audio import stores absolute TC source_in.
-- Verifies that source_in = media_tc_origin + in_offset (absolute TC in samples),
-- and that TMB's internal first_sample_tc subtraction would produce correct
-- file-relative decode positions for BWF WAV files.

require("test_env")

local drp_converter = require("importers.drp_importer")
local database = require("core.database")
local test_env = require("test_env")

local fixture_path = test_env.resolve_repo_path(
    "tests/fixtures/resolve/2026-03-20-anamnesis joe edit.drp")
local wav_path = "/Users/joe/Local/Anamnesis/2026-02-28-mm/anamnesis joe edit/"
    .. "Volumes/AnamBack4 Joe/OUTPUT/From Sound Post/Ross Wilkes-Houghton Sound Mix/"
    .. "Anemnesis Stereo Mix - Online 23012026_01.wav"

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

if not file_exists(fixture_path) or not file_exists(wav_path) then
    print("SKIP: fixture or WAV not found")
    print("✅ test_drp_bwf_audio_sync.lua skipped")
    os.exit(0)
end

print("\n=== DRP BWF Audio Sync Test ===")

-- Probe BWF
assert(type(qt_constants) == "table", "qt_constants not available — run via --test")
local EMP = qt_constants.EMP
local probe = EMP.MEDIA_FILE_PROBE(wav_path)
assert(probe and probe.bwf_time_reference >= 0, "WAV missing BWF time_reference")
local bwf_samples = probe.bwf_time_reference
local sample_rate = probe.audio_sample_rate
print(string.format("BWF: first_sample_tc=%d samples = %.4fs",
    bwf_samples, bwf_samples / sample_rate))

-- Verify probe returns correct TC origin fields
assert(probe.first_sample_tc == bwf_samples,
    string.format("first_sample_tc=%d should == bwf_time_reference=%d",
        probe.first_sample_tc, bwf_samples))
print(string.format("  first_sample_tc=%d (matches BWF)", probe.first_sample_tc))

-- Import DRP
local JVP_PATH = "/tmp/jve/test_drp_bwf_sync.jvp"
os.remove(JVP_PATH); os.remove(JVP_PATH .. "-wal"); os.remove(JVP_PATH .. "-shm")
local ok, err = drp_converter.convert(fixture_path, JVP_PATH)
assert(ok, "DRP convert failed: " .. tostring(err))

-- Query clips + media metadata
local db = database.get_connection()
local seq_stmt = db:prepare("SELECT id FROM sequences WHERE name LIKE '%2026-02-28%' LIMIT 1")
assert(seq_stmt:exec() and seq_stmt:next())
local timeline_id = seq_stmt:value(0)
seq_stmt:finalize()

local json = require("dkjson")

-- Test 1: Non-BWF clip — source_in includes media_tc_origin from MediaStartTime
print("\n--- Test 1: Non-BWF clip source_in = media_tc_origin + in_offset ---")

-- A3 clip from A037_11210019_C053.mov at Start=96607, DRP <In>=916
-- MediaStartTime for this clip = its TC origin (will be 0 if no MST)
local stmt = db:prepare([[
    SELECT c.source_in_frame, c.fps_numerator, m.metadata
    FROM clips c JOIN tracks t ON c.track_id=t.id JOIN media m ON c.media_id=m.id
    WHERE t.sequence_id=? AND t.name='A3' AND c.timeline_start_frame=96607
      AND m.name LIKE '%C053%' AND c.clip_kind='timeline'
]])
stmt:bind_value(1, timeline_id)
assert(stmt:exec() and stmt:next(), "A3 clip at 96607 not found")
local a3_source_in = stmt:value(0)
local a3_rate = stmt:value(1)
local a3_meta = json.decode(stmt:value(2)) or {}
stmt:finalize()

-- source_in should be media_tc_origin + in_offset
-- in_offset = 916 * (a3_rate / 25) samples
local in_offset = math.floor(916 * (a3_rate / 25) + 0.5)
local mst = a3_meta.start_tc_value and a3_meta.start_tc_rate and a3_meta.start_tc_rate > 0
    and math.floor(a3_meta.start_tc_value / a3_meta.start_tc_rate * a3_rate + 0.5) or 0
local expected_a3 = mst + in_offset
print(string.format("  A3: source_in=%d, expected=%d (mst=%d + in_offset=%d)",
    a3_source_in, expected_a3, mst, in_offset))
assert(math.abs(a3_source_in - expected_a3) <= 1, string.format(
    "A3 source_in should be %d (mst=%d + in_offset=%d), got %d",
    expected_a3, mst, in_offset, a3_source_in))

-- Test 2: Stereo Mix — source_in is absolute TC, TMB subtracts first_sample_tc
print("\n--- Test 2: Stereo Mix absolute TC source_in ---")

local stmt2 = db:prepare([[
    SELECT c.timeline_start_frame, c.source_in_frame
    FROM clips c JOIN tracks t ON c.track_id=t.id JOIN media m ON c.media_id=m.id
    WHERE t.sequence_id=? AND t.name='A1'
      AND m.name LIKE '%Stereo Mix - Online%' AND c.clip_kind='timeline'
    ORDER BY c.timeline_start_frame
]])
stmt2:bind_value(1, timeline_id)
assert(stmt2:exec())

local max_drift_frames = 2
local all_ok = true
local clip_idx = 0
while stmt2:next() do
    clip_idx = clip_idx + 1
    local tl_start = stmt2:value(0)
    local source_in = stmt2:value(1)

    -- source_in is now absolute TC in samples.
    -- TMB subtracts first_sample_tc (= bwf_time_reference for BWF files).
    -- file_pos = source_in - first_sample_tc (in samples)
    -- file_seek_s = file_pos / sample_rate
    local file_pos_samples = source_in - bwf_samples
    local file_seek_s = file_pos_samples / sample_rate

    -- The absolute TC of the audio at this file position should match the timeline TC
    -- source_in / sample_rate = absolute TC seconds
    local audio_tc_s = source_in / sample_rate
    local timeline_tc_s = tl_start / 25
    local drift_frames = math.abs((timeline_tc_s - audio_tc_s) * 25)

    local status = drift_frames <= max_drift_frames and "OK" or "FAIL"
    if status == "FAIL" then all_ok = false end
    print(string.format("  %s clip %d: tl=%d src_in=%d file_seek=%.3fs drift=%.1f frames",
        status, clip_idx, tl_start, source_in, file_seek_s, drift_frames))
end
stmt2:finalize()

assert(all_ok, "Stereo Mix TC sync drift exceeds tolerance")

print("\n✅ test_drp_bwf_audio_sync.lua passed")
