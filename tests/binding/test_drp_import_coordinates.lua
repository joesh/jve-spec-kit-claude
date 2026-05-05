#!/usr/bin/env luajit

-- Black-box test: DRP import produces correct clip coordinates in the DB.
-- Uses sample_project.drp which has non-trivial source_in values, V/A pairs,
-- non-unity speed clips, and media with non-zero MediaStartTime.
--
-- Known-answer values derived from Resolve's DRP XML (verified by inspection).

require("test_env")

local drp_converter = require("importers.drp_importer")
local database = require("core.database")
local test_env = require("test_env")
local json = require("dkjson")

local fixture = test_env.require_fixture("tests/fixtures/resolve/sample_project.drp")
local JVP = "/tmp/jve/test_drp_coordinates.jvp"
os.remove(JVP); os.remove(JVP .. "-wal"); os.remove(JVP .. "-shm")

print("\n=== DRP Import Coordinate Accuracy (sample_project.drp) ===")

local ok, err = drp_converter.convert(fixture, JVP, nil, {audio_sample_rate = 48000})
assert(ok, "convert failed: " .. tostring(err))

local db = database.get_connection()

local function query_one(sql, ...)
    local params = {...}
    local stmt = assert(db:prepare(sql), "prepare failed: " .. sql)
    for i, v in ipairs(params) do stmt:bind_value(i, v) end
    assert(stmt:exec())
    if not stmt:next() then stmt:finalize(); return nil end
    local vals = {}
    for i = 0, 9 do
        local v = stmt:value(i)
        if v == nil then break end
        vals[i + 1] = v
    end
    stmt:finalize()
    return vals
end

local function query_all(sql, ...)
    local params = {...}
    local stmt = assert(db:prepare(sql), "prepare failed: " .. sql)
    for i, v in ipairs(params) do stmt:bind_value(i, v) end
    assert(stmt:exec())
    local rows = {}
    while stmt:next() do
        local row = {}
        for i = 0, 9 do
            local v = stmt:value(i)
            if v == nil then break end
            row[i + 1] = v
        end
        rows[#rows + 1] = row
    end
    stmt:finalize()
    return rows
end

-- ═══════════════════════════════════════════════════════════════
-- 1. Video clips with non-zero source_in
-- ═══════════════════════════════════════════════════════════════
print("\n--- 1: Video clips with non-zero source_in ---")

-- "resolve audio tracks tutorial" — 6 trimmed clips from same media
-- Known: DRP <In>=2189 at 24fps sequence rate, media is 59.94fps (≈60/1).
-- Source coords are at native media rate: 2189 * 60/24 = 5473 (rounded).
-- clip rate = native media rate = 60/1 (not sequence rate).
-- V13: clips no longer carry fps_*; rate comes from the nested master
-- sequence (kind='master') the clip references via nested_sequence_id.
local video_clips = query_all([[
    SELECT c.timeline_start_frame, c.source_in_frame, c.duration_frames,
           ns.fps_numerator, ns.fps_denominator
    FROM clips c
    JOIN tracks t ON c.track_id = t.id
    JOIN sequences s ON t.sequence_id = s.id
    JOIN sequences ns ON c.nested_sequence_id = ns.id
    WHERE s.name = 'resolve audio tracks tutorial'
      AND t.track_type = 'VIDEO' AND t.name = 'V1'
    ORDER BY c.timeline_start_frame
]])

assert(#video_clips == 6, string.format("expected 6 V1 clips, got %d", #video_clips))

-- Known-answer: (timeline_start, source_in, duration, fps_num, fps_den)
-- source_in is at native media rate (60fps), timeline_start/duration at sequence rate (24fps).
local expected_video = {
    {86400, 5473, 362, 60, 1},
    {86762, 6475, 49, 60, 1},
    {86811, 6623, 45, 60, 1},
    {86856, 6878, 527, 60, 1},
    {87383, 8253, 2698, 60, 1},
    {90084, 14998, 8, 60, 1},
}

for i, exp in ipairs(expected_video) do
    local got = video_clips[i]
    for j = 1, 5 do
        assert(got[j] == exp[j], string.format(
            "V1 clip %d field %d: expected %d, got %s",
            i, j, exp[j], tostring(got[j])))
    end
end
print("  PASS: 6 video clips — all source_in values match DRP <In>")

-- ═══════════════════════════════════════════════════════════════
-- 2. Audio source_in = video source_in * samples_per_frame
-- ═══════════════════════════════════════════════════════════════
print("\n--- 2: V/A source_in correspondence ---")

-- V13: audio clips and video clips for the same media share one master
-- sequence; that master's fps_* reflects the media's VIDEO fps.
-- The audio sample rate lives on the media row (and nested seq's
-- audio_sample_rate). Verify both — they should match.
local audio_clips = query_all([[
    SELECT c.timeline_start_frame, c.source_in_frame, c.duration_frames,
           ns.audio_sample_rate, m.audio_sample_rate
    FROM clips c
    JOIN tracks t ON c.track_id = t.id
    JOIN sequences s ON t.sequence_id = s.id
    JOIN sequences ns ON c.nested_sequence_id = ns.id
    JOIN media_refs mr ON mr.owner_sequence_id = ns.id
    JOIN media m ON mr.media_id = m.id
    WHERE s.name = 'resolve audio tracks tutorial'
      AND t.track_type = 'AUDIO' AND t.name = 'A1'
    GROUP BY c.id
    ORDER BY c.timeline_start_frame
]])

assert(#audio_clips == 6, string.format("expected 6 A1 clips, got %d", #audio_clips))

-- First 5 clips are paired V/A from same media at ~60fps video / 48kHz audio.
-- Both source_in values are at their native rates, computed independently
-- from the same DRP <In> field. Due to independent rounding, the exact ratio
-- audio/video ≈ 48000/60 = 800 but may differ by a few samples.
-- Known-answer audio values (from probe):
local expected_audio = {
    {86400, 4378000},    -- V/A pair 1
    {86762, 5180000},    -- V/A pair 2
    {86811, 5298000},    -- V/A pair 3
    {86856, 5502000},    -- V/A pair 4
    {87383, 6602000},    -- V/A pair 5
}

for i = 1, 5 do
    local v = video_clips[i]
    local a = audio_clips[i]
    -- Same timeline position
    assert(v[1] == a[1], string.format(
        "clip %d: V tl_start=%d != A tl_start=%d", i, v[1], a[1]))
    -- Audio source_in matches known value
    assert(a[2] == expected_audio[i][2], string.format(
        "clip %d: expected audio src_in=%d, got %d",
        i, expected_audio[i][2], a[2]))
    -- V13: audio sample rate lives on media + master seq, both should be 48000.
    assert(a[4] == 48000, string.format(
        "clip %d: master seq audio_sample_rate should be 48000, got %s",
        i, tostring(a[4])))
    assert(a[5] == 48000, string.format(
        "clip %d: media audio_sample_rate should be 48000, got %s",
        i, tostring(a[5])))
end
print("  PASS: 5 V/A pairs — audio source_in at 48kHz native rate")

-- ═══════════════════════════════════════════════════════════════
-- 3. Clip 6 is a different DRP clip (speed=0.38, different coordinates)
-- ═══════════════════════════════════════════════════════════════
print("\n--- 3: Non-unity speed audio clip ---")

local a6 = audio_clips[6]
-- Known-answer (derived from DRP XML, not code tracing):
-- <In>=6000|00e0401cd451d83f → 6000 whole frames + sub-frame hex that
-- decodes as LE IEEE-754 double to 0.37999…
-- Per commit 9b5d306f, importer snaps both video AND audio to whole
-- source frames (Resolve Media-Manage cuts on whole-frame boundaries
-- for both): in_frame = ceil(6000.38 - 1e-6) = 6001.
-- At 48 kHz audio native rate via 24fps timeline:
--   src_in = 6001 × 48000 / 24 = 12,002,000 samples.
-- tl=90082, src_in=12002000, dur=6, audio_sample_rate=48000.
assert(a6[1] == 90082, "clip 6 tl_start: " .. tostring(a6[1]))
assert(a6[2] == 12002000, "clip 6 src_in: " .. tostring(a6[2]))
assert(a6[4] == 48000, "clip 6 master seq audio_sample_rate: " .. tostring(a6[4]))
-- This clip's source_in does NOT follow the V/A * 800 rule because it's
-- a different clip with speed=0.38 (the DRP speed affects source mapping)
-- V1 clip 6: tl=90084, src_in=14998 — different timeline_start too
assert(a6[1] ~= video_clips[6][1], "clip 6 should have different tl_start than V1 clip 6")
print("  PASS: audio clip 6 has independent coordinates (speed=0.38)")

-- ═══════════════════════════════════════════════════════════════
-- 4. Multi-track non-zero source_in (FogTL on V1 and V2)
-- ═══════════════════════════════════════════════════════════════
print("\n--- 4: Multi-track source_in (Timeline 1 — FogTL) ---")

-- V13: clip → nested master sequence → media_refs → media. The "media" of
-- a clip is the media_ref(s) sitting on its master sequence.
-- V13 master sequences hold V+A media_refs from one media; JOIN multiplies.
-- EXISTS keeps one row per clip.
local fog_v1 = query_all([[
    SELECT c.timeline_start_frame, c.source_in_frame
    FROM clips c
    JOIN tracks t ON c.track_id = t.id
    JOIN sequences s ON t.sequence_id = s.id
    WHERE s.name = 'Timeline 1' AND t.name = 'V1'
      AND c.source_in_frame != 0
      AND EXISTS (
        SELECT 1 FROM media_refs mr JOIN media m ON mr.media_id = m.id
        WHERE mr.owner_sequence_id = c.nested_sequence_id
          AND m.name = 'FogTL.mp4'
      )
    ORDER BY c.timeline_start_frame
]])
assert(#fog_v1 == 2, "expected 2 trimmed FogTL on V1, got " .. #fog_v1)
assert(fog_v1[1][2] == 57, "FogTL V1 clip1 src_in: " .. tostring(fog_v1[1][2]))
assert(fog_v1[2][2] == 57, "FogTL V1 clip2 src_in: " .. tostring(fog_v1[2][2]))

-- V2: one FogTL at src_in=156 (different trim point!)
local fog_v2 = query_all([[
    SELECT c.timeline_start_frame, c.source_in_frame
    FROM clips c
    JOIN tracks t ON c.track_id = t.id
    JOIN sequences s ON t.sequence_id = s.id
    WHERE s.name = 'Timeline 1' AND t.name = 'V2'
      AND EXISTS (
        SELECT 1 FROM media_refs mr JOIN media m ON mr.media_id = m.id
        WHERE mr.owner_sequence_id = c.nested_sequence_id
          AND m.name = 'FogTL.mp4'
      )
]])
assert(#fog_v2 == 1, "expected 1 FogTL on V2")
assert(fog_v2[1][2] == 156, "FogTL V2 src_in: " .. tostring(fog_v2[1][2]))

print("  PASS: FogTL V1 src_in=57, V2 src_in=156 (different trim points)")

-- ═══════════════════════════════════════════════════════════════
-- 5. MediaStartTime stored correctly on media with real TC
-- ═══════════════════════════════════════════════════════════════
print("\n--- 5: MediaStartTime in media metadata ---")

-- "sound tracks test" clips have non-zero MST (real TC from production cameras)
-- A001_05191411_C020.mov: mst=51099.76s → start_tc_value=1277494 at rate=25
local r = query_one([[
    SELECT metadata FROM media WHERE name = 'A001_05191411_C020.mov'
]])
assert(r, "media A001_05191411_C020.mov not found")
local meta = json.decode(r[1])
assert(meta.start_tc_value == 1277494, "start_tc_value: " .. tostring(meta.start_tc_value))
assert(meta.start_tc_rate == 25, "start_tc_rate: " .. tostring(meta.start_tc_rate))
-- Verify: 1277494/25 = 51099.76s = 14h 11m 39.76s ≈ DRP mst=51099.76 ✓
local tc_seconds = meta.start_tc_value / meta.start_tc_rate
assert(math.abs(tc_seconds - 51099.76) < 0.1, string.format(
    "TC should be ~51099.76s, got %.2f", tc_seconds))
print(string.format("  PASS: A001_05191411_C020.mov TC = %.2fs (14:11:39)", tc_seconds))

-- APM_Adobe_Going Home_v3.wav: mst=3603.6s → start_tc_value=172972800 at rate=48000
local r2 = query_one([[
    SELECT metadata FROM media WHERE name = 'APM_Adobe_Going Home_v3.wav'
]])
assert(r2, "WAV media not found")
local meta2 = json.decode(r2[1])
assert(meta2.start_tc_value == 172972800, "WAV start_tc_value: " .. tostring(meta2.start_tc_value))
assert(meta2.start_tc_rate == 48000, "WAV start_tc_rate: " .. tostring(meta2.start_tc_rate))
-- 172972800/48000 = 3603.6s = 01:00:03.6 ✓
local wav_tc = meta2.start_tc_value / meta2.start_tc_rate
assert(math.abs(wav_tc - 3603.6) < 0.01, string.format("WAV TC: %.2f", wav_tc))
print(string.format("  PASS: WAV TC = %.1fs (01:00:03.6)", wav_tc))

-- ═══════════════════════════════════════════════════════════════
-- 6. Total clip count (sanity)
-- ═══════════════════════════════════════════════════════════════
print("\n--- 6: Total counts ---")
-- V13: every row in clips is a "timeline" row (INV-2 enforces nested-only).
local r3 = query_one("SELECT COUNT(*) FROM clips")
assert(r3[1] == 126, "expected 126 timeline clips, got " .. tostring(r3[1]))
local r4 = query_one("SELECT COUNT(*) FROM media")
assert(r4[1] == 37, "expected 37 media, got " .. tostring(r4[1]))
print(string.format("  PASS: %d clips, %d media", r3[1], r4[1]))

-- ═══════════════════════════════════════════════════════════════
-- 7. UUID dedup — no duplicate file_uuid values
-- ═══════════════════════════════════════════════════════════════
print("\n--- 7: UUID dedup ---")
local r5 = query_one([[
    SELECT COUNT(*) FROM (
        SELECT file_uuid, COUNT(*) as cnt FROM media
        WHERE file_uuid IS NOT NULL
        GROUP BY file_uuid HAVING cnt > 1
    )
]])
assert(r5[1] == 0, r5[1] .. " duplicate UUIDs")
-- All media should have a UUID
local r6 = query_one("SELECT COUNT(*) FROM media WHERE file_uuid IS NULL OR file_uuid = ''")
assert(r6[1] == 0, r6[1] .. " media without UUID")
print("  PASS: 0 duplicate UUIDs, all media have UUID")

-- Cleanup
os.remove(JVP); os.remove(JVP .. "-wal"); os.remove(JVP .. "-shm")
print("\n✅ test_drp_import_coordinates.lua passed")
