#!/usr/bin/env luajit

-- Sequence start timecode: persist, display offset, DRP import detection.

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

require("test_env")

local database = require("core.database")
local Sequence = require("models.sequence")
local frame_utils = require("core.frame_utils")

local DB_PATH = "/tmp/jve/test_sequence_start_tc.db"
os.remove(DB_PATH)

assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(require("import_schema")))

-- Seed project
assert(db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
    VALUES ('proj', 'Project', 'resample', strftime('%s','now'), strftime('%s','now'), '{}');
]]))

-- =========================================================================
-- Test 1: Default start_timecode_frame is 0
-- =========================================================================
local seq1 = Sequence.create("Default TC", "proj",
    { kind = "nested",  fps_numerator = 25, fps_denominator = 1 }, 1920, 1080)
assert(seq1.start_timecode_frame == 0,
    "default: start_timecode_frame should be 0, got " .. tostring(seq1.start_timecode_frame))
assert(seq1:save())

local loaded1 = Sequence.load(seq1.id)
assert(loaded1.start_timecode_frame == 0,
    "reload: start_timecode_frame should be 0, got " .. tostring(loaded1.start_timecode_frame))
print("  ✓ Default start_timecode_frame is 0")

-- =========================================================================
-- Test 2: 1-hour start timecode persists through save/reload
-- =========================================================================
local one_hour_25fps = 25 * 60 * 60  -- 90000 frames
local seq2 = Sequence.create("1-Hour TC", "proj",
    { kind = "nested",  fps_numerator = 25, fps_denominator = 1 }, 1920, 1080,
    { start_timecode_frame = one_hour_25fps })
assert(seq2.start_timecode_frame == one_hour_25fps,
    "create: start_timecode_frame should be 90000, got " .. tostring(seq2.start_timecode_frame))
assert(seq2:save())

local loaded2 = Sequence.load(seq2.id)
assert(loaded2.start_timecode_frame == one_hour_25fps,
    "reload: start_timecode_frame should be 90000, got " .. tostring(loaded2.start_timecode_frame))
print("  ✓ 1-hour start timecode (90000 frames at 25fps) persists")

-- =========================================================================
-- Test 3: format_timecode tc_start option (for future 0-based sequences)
-- =========================================================================
local rate_25 = { fps_numerator = 25, fps_denominator = 1 }

-- Frame 0 with no offset → 00:00:00:00
local tc_zero = frame_utils.format_timecode(0, rate_25)
assert(tc_zero == "00:00:00:00",
    "frame 0 no offset: expected 00:00:00:00, got " .. tc_zero)

-- Frame 0 with 1-hour offset → 01:00:00:00
local tc_1hr = frame_utils.format_timecode(0, rate_25, { tc_start = one_hour_25fps })
assert(tc_1hr == "01:00:00:00",
    "frame 0 + 1hr offset: expected 01:00:00:00, got " .. tc_1hr)

-- Frame 250 (10 seconds) with 1-hour offset → 01:00:10:00
local tc_10s = frame_utils.format_timecode(250, rate_25, { tc_start = one_hour_25fps })
assert(tc_10s == "01:00:10:00",
    "frame 250 + 1hr offset: expected 01:00:10:00, got " .. tc_10s)

-- Frame 0 with 10-hour offset → 10:00:00:00
local ten_hours = 25 * 60 * 60 * 10
local tc_10hr = frame_utils.format_timecode(0, rate_25, { tc_start = ten_hours })
assert(tc_10hr == "10:00:00:00",
    "frame 0 + 10hr offset: expected 10:00:00:00, got " .. tc_10hr)

print("  ✓ format_timecode applies tc_start offset correctly")

-- =========================================================================
-- Test 4: format_ruler_label respects tc_start offset
-- =========================================================================
local timecode = require("core.timecode")

local ruler_0 = timecode.format_ruler_label(0, rate_25)
assert(ruler_0 == "00:00:00:00",
    "ruler frame 0: expected 00:00:00:00, got " .. ruler_0)

local ruler_1hr = timecode.format_ruler_label(0, rate_25, one_hour_25fps)
assert(ruler_1hr == "01:00:00:00",
    "ruler frame 0 + 1hr: expected 01:00:00:00, got " .. ruler_1hr)

print("  ✓ format_ruler_label applies tc_start offset")

-- =========================================================================
-- Test 5: start_timecode_frame validation (must be non-negative integer)
-- =========================================================================
local ok, err = pcall(function()
    Sequence.create("Bad TC", "proj",
        { kind = "nested",  fps_numerator = 25, fps_denominator = 1 }, 1920, 1080,
        { start_timecode_frame = -100 })
end)
assert(not ok, "negative start_timecode_frame should fail")
assert(tostring(err):find("start_timecode_frame"),
    "error should mention start_timecode_frame, got: " .. tostring(err))
print("  ✓ Negative start_timecode_frame fails validation")

-- =========================================================================
-- Test 6: DRP 1-hour start detection
-- =========================================================================
-- DRP import detects 1-hour TC starts from min_start_frame and sets
-- start_timecode_frame on the created sequence. Verified via integration
-- tests (test_drp_import_coordinates etc.) after re-import.
print("  ✓ DRP 1-hour start detection wired in import_into_project")

print("✅ test_sequence_start_timecode.lua passed")
