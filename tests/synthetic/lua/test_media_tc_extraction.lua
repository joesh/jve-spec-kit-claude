--- Test Media TC extraction — NSF regression test for the source_in=0 crash.
--
-- Bug: double-clicking a masterclip in the project browser crashed because
-- source_in=0 was passed to GetVideoFrame for media with first_frame_tc=1148001.
-- Root cause: import_media never extracted TC from the file; ensure_masterclip
-- silently defaulted to TC=0.
--
-- This test verifies:
-- 1. Media.create without TC metadata → get_start_tc() returns nil (not fabricated 0)
-- 2. Media with explicit TC=0 → get_start_tc() returns 0 (not nil)
-- 3. Media with explicit TC=N → get_start_tc() returns N
-- 4. ensure_masterclip asserts when TC is unknown
-- 5. ensure_masterclip uses real TC for source_in (not 0)
-- 6. get_audio_start_tc derivation output bounds check

require("test_env")

local database = require("core.database")
local Sequence = require("models.sequence")
local Media = require("models.media")
local json = require("dkjson")

local pass_count = 0
local fail_count = 0

local function check(label, condition, detail)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label .. (detail and (" — " .. detail) or ""))
    end
end


print("\n=== Media TC Extraction — NSF Regression Tests ===")

local db_path = "/tmp/jve/test_media_tc_extraction.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

local now = os.time()
db:exec(string.format(
    "INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at) VALUES ('proj1', 'Test', 'resample', '{\"master_clock_hz\":192000,\"default_fps\":{\"num\":24,\"den\":1}}', %d, %d)",
    now, now))

--------------------------------------------------------------------------------
-- Half 1: Input validation — get_start_tc never fabricates data
--------------------------------------------------------------------------------

print("\n--- No fabricated TC ---")

-- Media with no metadata → TC is unknown
local m_no_tc = Media.create({
    id = "m_no_tc", project_id = "proj1", name = "no_tc.mov",
    file_path = "/nonexistent/no_tc.mov",
    duration_frames = 100, fps_numerator = 25, fps_denominator = 1,
})
m_no_tc:save(db)
local tc, rate = m_no_tc:get_start_tc()
check("no metadata → get_start_tc returns nil", tc == nil,
    "got: " .. tostring(tc))
check("no metadata → rate is nil", rate == nil)

-- Media with empty metadata → TC is still unknown
local m_empty = Media.create({
    id = "m_empty", project_id = "proj1", name = "empty.mov",
    file_path = "/nonexistent/empty.mov",
    duration_frames = 100, fps_numerator = 24, fps_denominator = 1,
    metadata = "{}",
})
m_empty:save(db)
local tc2 = m_empty:get_start_tc()
check("empty metadata → get_start_tc returns nil", tc2 == nil,
    "got: " .. tostring(tc2))

--------------------------------------------------------------------------------
-- Half 1: Input validation — explicit TC values preserved
--------------------------------------------------------------------------------

print("\n--- Explicit TC preserved ---")

-- TC=0 is valid (file starts at 00:00:00:00)
local m_tc0 = Media.create({
    id = "m_tc0", project_id = "proj1", name = "tc0.mov",
    file_path = "/nonexistent/tc0.mov",
    duration_frames = 100, fps_numerator = 25, fps_denominator = 1,
    width = 1920, height = 1080,
    metadata = json.encode({start_tc_value = 0, start_tc_rate = 25}),
})
m_tc0:save(db)
local tc3, rate3 = m_tc0:get_start_tc()
check("TC=0 → returns 0 (not nil)", tc3 == 0, "got: " .. tostring(tc3))
check("TC=0 → rate preserved", rate3 == 25)

-- TC=1148001 (the value from the crash — 01:16:33:06 @ 25fps)
local m_tc_high = Media.create({
    id = "m_tc_high", project_id = "proj1", name = "high_tc.mov",
    file_path = "/nonexistent/high_tc.mov",
    duration_frames = 250, fps_numerator = 25, fps_denominator = 1,
    width = 1920, height = 1080,
    audio_channels = 2, audio_sample_rate = 48000,
    metadata = json.encode({
        start_tc_value = 1148001, start_tc_rate = 25,
        start_tc_audio_samples = 2204162, start_tc_audio_rate = 48000,
    }),
})
m_tc_high:save(db)
local tc4, rate4 = m_tc_high:get_start_tc()
check("TC=1148001 → returns 1148001", tc4 == 1148001, "got: " .. tostring(tc4))
check("TC=1148001 → rate=25", rate4 == 25)

local atc4, arate4 = m_tc_high:get_audio_start_tc()
check("audio TC=2204162 (explicit)", atc4 == 2204162, "got: " .. tostring(atc4))
check("audio rate=48000", arate4 == 48000)

--------------------------------------------------------------------------------
-- Half 2: Output invariants
--------------------------------------------------------------------------------

print("\n--- media with no video or audio dims: ensure_master succeeds, no media_refs ---")

-- Media whose project file carried no dims (placeholder ref, failed blob
-- decode) still gets a master row — dims will be filled in when the file
-- is probed. ensure_master logs a warning and continues.
local mc_nodims_ok, mc_nodims_id = pcall(Sequence.ensure_master, "m_no_tc", "proj1")
check("no-dims media → ensure_master succeeds", mc_nodims_ok,
    "error: " .. tostring(mc_nodims_id))

local mc_empty_ok, mc_empty_id = pcall(Sequence.ensure_master, "m_empty", "proj1")
check("empty metadata → ensure_master succeeds", mc_empty_ok,
    "error: " .. tostring(mc_empty_id))

-- The master exists but has no media_refs yet.
if mc_nodims_ok then
    local stmt2 = assert(db:prepare("SELECT COUNT(*) FROM media_refs WHERE owner_sequence_id = ?"))
    stmt2:bind_value(1, mc_nodims_id)
    stmt2:exec(); stmt2:next()
    check("no-dims master has 0 media_refs", stmt2:value(0) == 0,
        "got: " .. tostring(stmt2:value(0)))
    stmt2:finalize()
end

print("\n--- ensure_masterclip defaults TC origin to 00:00:00:00 for media WITH video/audio but no TC ---")

-- A media record with video dims (width > 0) but no TC metadata anchors at
-- 00:00:00:00 (frame 0). No-TC media is common (offline/relinked clips, files
-- whose container carries no start timecode); the master must still build so
-- the clip places, with the file's first frame as origin. (Joe-approved
-- 2026-06-14 no-TC origin-0 fix; this replaced the earlier hard assert.)
local m_video_no_tc = Media.create({
    id = "m_video_no_tc", project_id = "proj1", name = "video_notc.mov",
    file_path = "/nonexistent/video_notc.mov",
    duration_frames = 100, fps_numerator = 25, fps_denominator = 1,
    width = 1920, height = 1080,
    -- no metadata → get_start_tc returns nil → origin defaults to frame 0
})
m_video_no_tc:save(db)

local mc_no_tc = Sequence.ensure_master("m_video_no_tc", "proj1")
check("no-TC video media → master created", mc_no_tc ~= nil)

local notc_stmt = assert(db:prepare([[
    SELECT c.source_in_frame, c.sequence_start_frame
    FROM media_refs c
    JOIN tracks t ON c.track_id = t.id
    WHERE c.owner_sequence_id = ? AND t.track_type = 'VIDEO'
    LIMIT 1
]]))
notc_stmt:bind_value(1, mc_no_tc)
assert(notc_stmt:exec() and notc_stmt:next())
local notc_source_in = notc_stmt:value(0)
local notc_sequence_start = notc_stmt:value(1)
notc_stmt:finalize()

check("no-TC video source_in = frame 0 (00:00:00:00)", notc_source_in == 0,
    string.format("expected 0, got %s", tostring(notc_source_in)))
check("no-TC video sequence_start = frame 0", notc_sequence_start == 0,
    string.format("expected 0, got %s", tostring(notc_sequence_start)))

--------------------------------------------------------------------------------
-- Half 2: Output invariants — masterclip source_in uses real TC
--------------------------------------------------------------------------------

print("\n--- masterclip source_in = TC origin (the actual crash fix) ---")

local mc_id = Sequence.ensure_master("m_tc_high", "proj1")
check("masterclip created", mc_id ~= nil)

-- Query the video stream clip's source_in
local stmt = assert(db:prepare([[
    SELECT c.source_in_frame, c.source_out_frame, c.sequence_start_frame
    FROM media_refs c
    JOIN tracks t ON c.track_id = t.id
    WHERE c.owner_sequence_id = ? AND t.track_type = 'VIDEO' AND 1=1
]]))
stmt:bind_value(1, mc_id)
assert(stmt:exec() and stmt:next())
local source_in = stmt:value(0)
local source_out = stmt:value(1)
local sequence_start = stmt:value(2)
stmt:finalize()

check("video source_in = TC origin (1148001)", source_in == 1148001,
    string.format("expected 1148001, got %s", tostring(source_in)))
check("video source_out = TC + duration", source_out == 1148001 + 250,
    string.format("expected %d, got %s", 1148001 + 250, tostring(source_out)))
check("video sequence_start = TC origin", sequence_start == 1148001,
    string.format("expected 1148001, got %s", tostring(sequence_start)))

-- Query audio stream clip's source_in
local astmt = assert(db:prepare([[
    SELECT c.source_in_frame, c.source_out_frame
    FROM media_refs c
    JOIN tracks t ON c.track_id = t.id
    WHERE c.owner_sequence_id = ? AND t.track_type = 'AUDIO' AND 1=1
    LIMIT 1
]]))
astmt:bind_value(1, mc_id)
assert(astmt:exec() and astmt:next())
local audio_source_in = astmt:value(0)
local audio_source_out = astmt:value(1)
astmt:finalize()

check("audio source_in = audio TC origin (2204162)", audio_source_in == 2204162,
    string.format("expected 2204162, got %s", tostring(audio_source_in)))

-- Audio duration: 250 frames @ 25fps = 10s → 10s × 48000Hz = 480000 samples
local expected_audio_out = 2204162 + 480000
check("audio source_out = audio_tc + duration_samples", audio_source_out == expected_audio_out,
    string.format("expected %d, got %s", expected_audio_out, tostring(audio_source_out)))

--------------------------------------------------------------------------------
-- Half 2: Output invariants — TC=0 masterclip (file at 00:00:00:00)
--------------------------------------------------------------------------------

print("\n--- TC=0 masterclip works correctly ---")

local mc_id_0 = Sequence.ensure_master("m_tc0", "proj1")
check("TC=0 masterclip created", mc_id_0 ~= nil)

local stmt0 = assert(db:prepare([[
    SELECT c.source_in_frame, c.sequence_start_frame
    FROM media_refs c
    JOIN tracks t ON c.track_id = t.id
    WHERE c.owner_sequence_id = ? AND t.track_type = 'VIDEO' AND 1=1
]]))
stmt0:bind_value(1, mc_id_0)
assert(stmt0:exec() and stmt0:next())
local si0 = stmt0:value(0)
local ts0 = stmt0:value(1)
stmt0:finalize()

check("TC=0 video source_in = 0", si0 == 0, "got: " .. tostring(si0))
check("TC=0 video sequence_start = 0", ts0 == 0, "got: " .. tostring(ts0))

--------------------------------------------------------------------------------
-- Half 2: get_audio_start_tc reads start_tc_audio_samples directly
--------------------------------------------------------------------------------
-- Post-normalization (2026-05-16) get_audio_start_tc no longer derives from
-- start_tc_value * sr / fps. That derive path bridged the dual-unit overload
-- (audio TC stored under start_tc_value with rate==sr for audio-only files),
-- which caused 4-second-late playback when metadata drifted from the file's
-- BWF TC. Audio TC now lives exclusively in start_tc_audio_samples; missing
-- → returns nil, callers fail via their own has_audio gates.

print("\n--- get_audio_start_tc reads start_tc_audio_samples directly ---")

-- Direct read: metadata carries explicit audio samples; no derivation.
local m_direct = Media.create({
    id = "m_direct", project_id = "proj1", name = "direct.mov",
    file_path = "/nonexistent/direct.mov",
    duration_frames = 100, fps_numerator = 25, fps_denominator = 1,
    audio_channels = 1, audio_sample_rate = 48000,
    metadata = json.encode({
        start_tc_value = 1000, start_tc_rate = 25,
        start_tc_audio_samples = 1920000, start_tc_audio_rate = 48000,
    }),
})
m_direct:save(db)
local direct_atc, direct_sr = m_direct:get_audio_start_tc()
check("direct audio TC = 1920000", direct_atc == 1920000,
    string.format("expected 1920000, got %s", tostring(direct_atc)))
check("direct sample rate = 48000", direct_sr == 48000)

-- V-only metadata (no start_tc_audio_samples): get_audio_start_tc returns nil
-- rather than deriving. Callers must gate on has_audio.
local m_v_only = Media.create({
    id = "m_v_only", project_id = "proj1", name = "vonly.mov",
    file_path = "/nonexistent/vonly.mov",
    duration_frames = 100, fps_numerator = 25, fps_denominator = 1,
    audio_channels = 0,
    metadata = json.encode({start_tc_value = 1000, start_tc_rate = 25}),
})
m_v_only:save(db)
local v_only_atc, v_only_sr = m_v_only:get_audio_start_tc()
check("V-only file: audio TC = nil (no derive from V)", v_only_atc == nil,
    string.format("expected nil, got %s", tostring(v_only_atc)))
check("V-only file: sample rate = nil", v_only_sr == nil)

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------

print(string.format("\n=== Results: %d passed, %d failed ===", pass_count, fail_count))
assert(fail_count == 0,
    string.format("test_media_tc_extraction.lua: %d test(s) failed", fail_count))
print("✅ test_media_tc_extraction.lua passed")
