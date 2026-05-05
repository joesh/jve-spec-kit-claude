#!/usr/bin/env luajit
-- SLOW_TEST
--
-- Combined integration test against the 43MB anamnesis DRP fixture.
-- Parses once (parse_drp_file) + converts once (to SQLite) for all assertions.
-- Covers: open timelines, mute flags, BWF audio sync.
--
-- Run with: RUN_SLOW_TESTS=1 make -j4

require("test_env")

local drp_converter = require("importers.drp_importer")
local database = require("core.database")
local Sequence = require("models.sequence")
local test_env = require("test_env")
local json = require("dkjson")

local fixture_path = test_env.require_fixture(
    "tests/fixtures/resolve/anamnesis joe edit.drp")

-- BWF stub fixture — same bwf_time_reference as the real 1.2GB stereo mix
local bwf_fixture = test_env.require_fixture(
    "tests/fixtures/resolve/bwf_stereo_mix_stub.wav")

print("\n=== test_drp_anamnesis_full.lua (SLOW) ===")

-- ═══════════════════════════════════════════════════════════════════════════
-- Phase 1: parse_drp_file (no DB) — open timelines assertions
-- ═══════════════════════════════════════════════════════════════════════════
print("\n--- Phase 1: parse_drp_file — open timelines ---")
do
    local result = drp_converter.parse_drp_file(fixture_path)
    assert(result.success, "parse_drp_file failed: " .. tostring(result.error))

    -- SequenceTabsData should yield exactly 3 tabs, not 125 from TimelineHandleVec
    local open_ids = result.project.open_timeline_ids
    assert(open_ids and #open_ids <= 10,
        string.format("Expected ≤10 open timelines (from tabs), got %d — "
            .. "likely using TimelineHandleVec instead of SequenceTabsData",
            open_ids and #open_ids or 0))
    assert(#open_ids == 3,
        string.format("Expected 3 open timelines from SequenceTabsData, got %d",
            #open_ids))
    print(string.format("  PASS: %d open timelines (not 125)", #open_ids))

    assert(result.project.active_timeline_id,
        "Expected active_timeline_id to be set")
    print(string.format("  PASS: active timeline = %s", result.project.active_timeline_id))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Phase 2: convert to SQLite (single parse + full DB write)
-- ═══════════════════════════════════════════════════════════════════════════
print("\n--- Phase 2: convert to SQLite ---")
local JVP_PATH = "/tmp/jve/test_drp_anamnesis_full.jvp"
os.remove(JVP_PATH); os.remove(JVP_PATH .. "-wal"); os.remove(JVP_PATH .. "-shm")

local ok, err = drp_converter.convert(fixture_path, JVP_PATH, nil, {audio_sample_rate = 48000})
assert(ok, "DRP convert failed: " .. tostring(err))
local db = database.get_connection()
print("  PASS: convert succeeded")

-- ═══════════════════════════════════════════════════════════════════════════
-- Phase 3: Mute flag assertions
-- ═══════════════════════════════════════════════════════════════════════════
print("\n--- Phase 3: mute flags ---")

-- 3a: Disabled clips exist
local stmt = assert(db:prepare(
    "SELECT COUNT(*) FROM clips WHERE enabled = 0 AND clip_kind = 'timeline'"))
assert(stmt:exec() and stmt:next())
local disabled_count = stmt:value(0)
stmt:finalize()
assert(disabled_count > 0, "expected disabled clips, got 0 — mute flag not imported")
print(string.format("  3a: %d disabled timeline clips", disabled_count))

-- 3b: Enabled clips also present (not ALL disabled)
local stmt2 = assert(db:prepare(
    "SELECT COUNT(*) FROM clips WHERE enabled = 1 AND clip_kind = 'timeline'"))
assert(stmt2:exec() and stmt2:next())
local enabled_count = stmt2:value(0)
stmt2:finalize()
assert(enabled_count > disabled_count,
    string.format("expected more enabled (%d) than disabled (%d)",
        enabled_count, disabled_count))
print(string.format("  3b: %d enabled, %d disabled (%.0f%%)",
    enabled_count, disabled_count,
    disabled_count * 100 / (enabled_count + disabled_count)))

-- 3c: get_audio_in_range excludes disabled clips
local seq_stmt = assert(db:prepare([[
    SELECT DISTINCT s.id, s.name
    FROM sequences s
    JOIN tracks t ON t.sequence_id = s.id
    JOIN clips c ON c.track_id = t.id
    WHERE s.kind = 'timeline' AND t.track_type = 'AUDIO'
      AND c.clip_kind = 'timeline' AND c.enabled = 0
    LIMIT 1
]]))
assert(seq_stmt:exec())
if seq_stmt:next() then
    local seq_id = seq_stmt:value(0)
    local seq_name = seq_stmt:value(1)
    seq_stmt:finalize()

    local seq = Sequence.load(seq_id)
    assert(seq, "failed to load sequence " .. seq_id)

    local dis_stmt = assert(db:prepare([[
        SELECT c.timeline_start_frame, c.timeline_start_frame + c.duration_frames as clip_end
        FROM clips c JOIN tracks t ON c.track_id = t.id
        WHERE t.sequence_id = ? AND t.track_type = 'AUDIO'
          AND c.clip_kind = 'timeline' AND c.enabled = 0
        ORDER BY c.timeline_start_frame LIMIT 1
    ]]))
    dis_stmt:bind_value(1, seq_id)
    assert(dis_stmt:exec() and dis_stmt:next())
    local disabled_start = dis_stmt:value(0)
    local disabled_end = dis_stmt:value(1)
    dis_stmt:finalize()

    local audio_entries = seq:get_audio_in_range(disabled_start, disabled_end)
    for _, entry in ipairs(audio_entries) do
        assert(entry.clip.enabled ~= 0 and entry.clip.enabled ~= false,
            string.format("get_audio_in_range returned disabled clip id=%s at tl=%d",
                entry.clip.id, entry.clip.timeline_start))
    end
    print(string.format("  3c: disabled audio clip at [%d..%d] excluded from %s",
        disabled_start, disabled_end, seq_name))
else
    seq_stmt:finalize()
    print("  3c SKIP: no sequence with disabled audio clips found")
end

-- 3d: get_video_in_range excludes disabled clips
local vseq_stmt = assert(db:prepare([[
    SELECT DISTINCT s.id, s.name
    FROM sequences s
    JOIN tracks t ON t.sequence_id = s.id
    JOIN clips c ON c.track_id = t.id
    WHERE s.kind = 'timeline' AND t.track_type = 'VIDEO'
      AND c.clip_kind = 'timeline' AND c.enabled = 0
    LIMIT 1
]]))
assert(vseq_stmt:exec())
if vseq_stmt:next() then
    local seq_id = vseq_stmt:value(0)
    local seq_name = vseq_stmt:value(1)
    vseq_stmt:finalize()

    local seq = Sequence.load(seq_id)
    assert(seq, "failed to load sequence")

    local vdis_stmt = assert(db:prepare([[
        SELECT c.timeline_start_frame, c.timeline_start_frame + c.duration_frames
        FROM clips c JOIN tracks t ON c.track_id = t.id
        WHERE t.sequence_id = ? AND t.track_type = 'VIDEO'
          AND c.clip_kind = 'timeline' AND c.enabled = 0
        ORDER BY c.timeline_start_frame LIMIT 1
    ]]))
    vdis_stmt:bind_value(1, seq_id)
    assert(vdis_stmt:exec() and vdis_stmt:next())
    local vd_start = vdis_stmt:value(0)
    local vd_end = vdis_stmt:value(1)
    vdis_stmt:finalize()

    local video_entries = seq:get_video_in_range(vd_start, vd_end)
    for _, entry in ipairs(video_entries) do
        assert(entry.clip.enabled ~= 0 and entry.clip.enabled ~= false,
            string.format("get_video_in_range returned disabled clip id=%s",
                entry.clip.id))
    end
    print(string.format("  3d: disabled video clip at [%d..%d] excluded from %s",
        vd_start, vd_end, seq_name))
else
    vseq_stmt:finalize()
    print("  3d SKIP: no sequence with disabled video clips found")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Phase 4: BWF audio sync assertions
-- ═══════════════════════════════════════════════════════════════════════════
print("\n--- Phase 4: BWF audio sync ---")

-- Probe the BWF stub fixture for metadata
assert(type(qt_constants) == "table", "qt_constants not available — run via --test")
local EMP = qt_constants.EMP
local probe = EMP.MEDIA_FILE_PROBE(bwf_fixture)
assert(probe and probe.bwf_time_reference >= 0, "BWF stub missing bwf_time_reference")
local bwf_samples = probe.bwf_time_reference
local sample_rate = probe.audio_sample_rate
print(string.format("  BWF stub: first_sample_tc=%d samples = %.4fs",
    bwf_samples, bwf_samples / sample_rate))

assert(probe.first_sample_tc == bwf_samples,
    string.format("first_sample_tc=%d should == bwf_time_reference=%d",
        probe.first_sample_tc, bwf_samples))

-- 4a: Non-BWF clip — source_in includes media_tc_origin from MediaStartTime
print("\n  4a: Non-BWF clip source_in = media_tc_origin + in_offset")

local tl_stmt = db:prepare("SELECT id FROM sequences WHERE name LIKE '%2026-03-28%' LIMIT 1")
assert(tl_stmt:exec() and tl_stmt:next())
local timeline_id = tl_stmt:value(0)
tl_stmt:finalize()

local a3_stmt = db:prepare([[
    SELECT c.source_in_frame, c.fps_numerator, m.metadata
    FROM clips c JOIN tracks t ON c.track_id=t.id JOIN media m ON c.media_id=m.id
    WHERE t.sequence_id=? AND t.name='A3' AND c.timeline_start_frame=96607
      AND m.name LIKE '%C053%' AND c.clip_kind='timeline'
]])
a3_stmt:bind_value(1, timeline_id)
assert(a3_stmt:exec() and a3_stmt:next(), "A3 clip at 96607 not found")
local a3_source_in = a3_stmt:value(0)
local a3_rate = a3_stmt:value(1)
local a3_meta = json.decode(a3_stmt:value(2)) or {}
a3_stmt:finalize()

local in_offset = math.floor(916 * (a3_rate / 25) + 0.5)
local mst = a3_meta.start_tc_value and a3_meta.start_tc_rate and a3_meta.start_tc_rate > 0
    and math.floor(a3_meta.start_tc_value / a3_meta.start_tc_rate * a3_rate + 0.5) or 0
local expected_a3 = mst + in_offset
print(string.format("    A3: source_in=%d, expected=%d (mst=%d + in_offset=%d)",
    a3_source_in, expected_a3, mst, in_offset))
assert(math.abs(a3_source_in - expected_a3) <= 1, string.format(
    "A3 source_in should be %d (mst=%d + in_offset=%d), got %d",
    expected_a3, mst, in_offset, a3_source_in))

-- 4b: Stereo Mix — source_in is absolute TC, TMB subtracts first_sample_tc
print("\n  4b: Stereo Mix absolute TC source_in")

local mix_stmt = db:prepare([[
    SELECT c.timeline_start_frame, c.source_in_frame
    FROM clips c JOIN tracks t ON c.track_id=t.id JOIN media m ON c.media_id=m.id
    WHERE t.sequence_id=? AND t.name='A1'
      AND m.name LIKE '%Stereo Mix - Online%' AND c.clip_kind='timeline'
    ORDER BY c.timeline_start_frame
]])
mix_stmt:bind_value(1, timeline_id)
assert(mix_stmt:exec())

local max_drift_frames = 2
local all_ok = true
local clip_idx = 0
while mix_stmt:next() do
    clip_idx = clip_idx + 1
    local tl_start = mix_stmt:value(0)
    local source_in = mix_stmt:value(1)

    local file_pos_samples = source_in - bwf_samples
    local file_seek_s = file_pos_samples / sample_rate
    local audio_tc_s = source_in / sample_rate
    local timeline_tc_s = tl_start / 25
    local drift_frames = math.abs((timeline_tc_s - audio_tc_s) * 25)

    local status = drift_frames <= max_drift_frames and "OK" or "FAIL"
    if status == "FAIL" then all_ok = false end
    print(string.format("    %s clip %d: tl=%d src_in=%d file_seek=%.3fs drift=%.1f frames",
        status, clip_idx, tl_start, source_in, file_seek_s, drift_frames))
end
mix_stmt:finalize()

assert(all_ok, "Stereo Mix TC sync drift exceeds tolerance")

-- ═══════════════════════════════════════════════════════════════════════════
-- Cleanup
-- ═══════════════════════════════════════════════════════════════════════════
os.remove(JVP_PATH); os.remove(JVP_PATH .. "-wal"); os.remove(JVP_PATH .. "-shm")

print("\n✅ test_drp_anamnesis_full.lua passed")
