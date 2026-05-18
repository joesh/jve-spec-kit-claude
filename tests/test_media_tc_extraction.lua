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

local function expect_error(label, fn, pattern)
    local ok, err = pcall(fn)
    if not ok then
        if pattern and not tostring(err):match(pattern) then
            fail_count = fail_count + 1
            print("FAIL (wrong error): " .. label .. " got: " .. tostring(err))
        else
            pass_count = pass_count + 1
        end
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
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

print("\n--- ensure_masterclip asserts on unknown TC for media WITH video/audio ---")

-- A media record with video dims (width > 0) but no TC metadata must assert —
-- the source viewer and decoder need an authoritative TC origin.
local m_video_no_tc = Media.create({
    id = "m_video_no_tc", project_id = "proj1", name = "video_notc.mov",
    file_path = "/nonexistent/video_notc.mov",
    duration_frames = 100, fps_numerator = 25, fps_denominator = 1,
    width = 1920, height = 1080,
    -- no metadata → get_start_tc returns nil
})
m_video_no_tc:save(db)

expect_error("video media without TC → ensure_master asserts", function()
    Sequence.ensure_master("m_video_no_tc", "proj1")
end, "no video TC origin")

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
-- Half 2: Output bounds — get_audio_start_tc derivation
--------------------------------------------------------------------------------

print("\n--- Audio TC derivation bounds ---")

-- Normal derivation: video_tc=1000 @ 25fps → audio = 1000 * 48000 / 25 = 1920000
local m_derive = Media.create({
    id = "m_derive", project_id = "proj1", name = "derive.mov",
    file_path = "/nonexistent/derive.mov",
    duration_frames = 100, fps_numerator = 25, fps_denominator = 1,
    audio_channels = 1, audio_sample_rate = 48000,
    metadata = json.encode({start_tc_value = 1000, start_tc_rate = 25}),
})
m_derive:save(db)
local derived_atc, derived_sr = m_derive:get_audio_start_tc()
check("derived audio TC = 1920000", derived_atc == 1920000,
    string.format("expected 1920000, got %s", tostring(derived_atc)))
check("derived sample rate = 48000", derived_sr == 48000)

-- Invalid derivation: start_tc_rate = 0 should assert
local m_bad_rate = Media.create({
    id = "m_bad_rate", project_id = "proj1", name = "bad.mov",
    file_path = "/nonexistent/bad.mov",
    duration_frames = 100, fps_numerator = 25, fps_denominator = 1,
    audio_channels = 1, audio_sample_rate = 48000,
    metadata = json.encode({start_tc_value = 100, start_tc_rate = 0}),
})
m_bad_rate:save(db)
expect_error("audio TC derivation asserts on fps=0", function()
    m_bad_rate:get_audio_start_tc()
end, "start_tc_rate must be positive")

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------

print(string.format("\n=== Results: %d passed, %d failed ===", pass_count, fail_count))
assert(fail_count == 0,
    string.format("test_media_tc_extraction.lua: %d test(s) failed", fail_count))
print("✅ test_media_tc_extraction.lua passed")
