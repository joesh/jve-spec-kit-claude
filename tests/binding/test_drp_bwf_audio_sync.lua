#!/usr/bin/env luajit

-- Test: DRP audio import produces correct file-relative source_in.
-- Verifies that <In> values are correctly converted to samples and that
-- the TMB's BWF adjustment (at playback time) would produce correct TC sync
-- for BWF WAV files where MediaStartTime differs from BWF time_reference.

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
local bwf_us = math.floor(bwf_samples * 1000000 / sample_rate)
print(string.format("BWF: %d samples = %.4fs", bwf_samples, bwf_samples / sample_rate))

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

-- Test 1: DRP <In> is file-relative — source_in = In * samples_per_frame
print("\n--- Test 1: Audio source_in matches DRP <In> (file-relative) ---")

-- A3 clip from A037_11210019_C053.mov at Start=96607, DRP <In>=916
local stmt = db:prepare([[
    SELECT c.source_in_frame, c.fps_numerator
    FROM clips c JOIN tracks t ON c.track_id=t.id JOIN media m ON c.media_id=m.id
    WHERE t.sequence_id=? AND t.name='A3' AND c.timeline_start_frame=96607
      AND m.name LIKE '%C053%' AND c.clip_kind='timeline'
]])
stmt:bind_value(1, timeline_id)
assert(stmt:exec() and stmt:next(), "A3 clip at 96607 not found")
local a3_source_in = stmt:value(0)
local a3_rate = stmt:value(1)
stmt:finalize()

local expected_a3 = 916 * (a3_rate / 25)  -- In=916 at 25fps → samples at clip rate
assert(a3_source_in == expected_a3, string.format(
    "A3 source_in should be %d (In=916 * %d/25), got %d",
    expected_a3, a3_rate, a3_source_in))
print(string.format("  ✓ A3 source_in=%d (916 frames file-relative)", a3_source_in))

-- Test 2: Stereo Mix — import produces In-based source_in, TMB BWF adjusts at playback
print("\n--- Test 2: Stereo Mix BWF playback adjustment ---")

local stmt2 = db:prepare([[
    SELECT c.timeline_start_frame, c.source_in_frame, c.fps_numerator, m.metadata
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
    local rate = stmt2:value(2)
    local meta = json.decode(stmt2:value(3)) or {}

    local mst_us = (meta.start_tc_value and meta.start_tc_rate and meta.start_tc_rate > 0)
        and math.floor(meta.start_tc_value * 1000000 / meta.start_tc_rate) or 0

    -- Simulate TMB BWF adjustment: file_seek = source_in_us - (bwf_us - mst_us)
    local source_in_us = math.floor(source_in * 1000000 / rate)
    local bwf_offset_us = bwf_us - mst_us
    local file_seek_us = source_in_us - bwf_offset_us
    local file_seek_s = file_seek_us / 1000000

    local audio_tc_s = (bwf_samples / sample_rate) + file_seek_s
    local timeline_tc_s = tl_start / 25
    local drift_frames = math.abs((timeline_tc_s - audio_tc_s) * 25)

    local status = drift_frames <= max_drift_frames and "OK" or "FAIL"
    if status == "FAIL" then all_ok = false end
    print(string.format("  %s clip %d: tl=%d src_in=%d bwf_seek=%.3fs drift=%.1f frames",
        status, clip_idx, tl_start, source_in, file_seek_s, drift_frames))
end
stmt2:finalize()

assert(all_ok, "Stereo Mix TC sync drift exceeds tolerance after BWF adjustment")

print("\n✅ test_drp_bwf_audio_sync.lua passed")
