#!/usr/bin/env luajit
-- Regression: when the relinker found a same-basename candidate in
-- the search tree but rejected it for extent (clip needs frames the
-- file doesn't cover), the offline frame must describe the REAL
-- situation — not the misleading "File not found".
--
-- Domain behavior (not implementation):
--   Given an offline_note describing a candidate file's covered TC
--   range and a clip's source range that sticks out past the end of
--   that range, the composed offline-frame lines:
--     - Name the found candidate file
--     - State "not enough media for clip"
--     - Quantify how many frames are missing and at which boundary
--   A candidate that does cover the clip fully produces a different
--   message (relinker rejected for a non-extent reason).
package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"
require("test_env")

local ofc = require("core.media.offline_frame_cache")

print("=== offline frame: partial-coverage composition ===")

local function text_of(lines)
    local parts = {}
    for _, l in ipairs(lines) do parts[#parts + 1] = l.text end
    return table.concat(parts, "\n")
end

-- ---------------------------------------------------------------------------
-- Check 1: tail-short — file ends 3 frames before clip's source_out.
-- Message should say "short" and mention the tail.
-- ---------------------------------------------------------------------------
print("Check 1: 3-frame tail shortfall")
do
    local note = {
        kind = "partial_coverage",
        candidate_path = "/fixture/Day 12/A035_11200114_C056.mov",
        covered_start_tc = 100000,
        covered_end_tc   = 100100,  -- covers 100000..100100
        rate = 25,
    }
    local clip = { source_in = 100000, source_out = 100103 }  -- wants 3 past
    local lines = ofc._build_partial_coverage_lines(note, clip)
    assert(lines, "expected lines for partial_coverage, got nil")
    local text = text_of(lines)
    assert(text:find("A035_11200114_C056.mov", 1, true),
        "message must name the found candidate file:\n" .. text)
    assert(text:find("short", 1, true),
        "message must describe what's missing:\n" .. text)
    assert(text:find("tail", 1, true) or text:find("end", 1, true),
        "tail-short must mention tail/end:\n" .. text)
    assert(text:find("3", 1, true),
        "frame count must appear (3 missing frames):\n" .. text)
    assert(not text:find("File not found", 1, true),
        "partial coverage must NOT say 'File not found':\n" .. text)
end

-- ---------------------------------------------------------------------------
-- Check 2: head-short — clip starts before the file.
-- ---------------------------------------------------------------------------
print("Check 2: 50-frame head shortfall")
do
    local note = {
        kind = "partial_coverage",
        candidate_path = "/fixture/SFX/foo.wav",
        covered_start_tc = 100050,  -- clip wants to start 50 earlier
        covered_end_tc   = 100500,
        rate = 48000,  -- audio rate for this candidate
    }
    local clip = { source_in = 100000, source_out = 100400 }
    local lines = ofc._build_partial_coverage_lines(note, clip)
    local text = text_of(lines)
    assert(text:find("head", 1, true) or text:find("start", 1, true),
        "head-short must mention head/start:\n" .. text)
    assert(text:find("50", 1, true),
        "50-frame shortfall must appear:\n" .. text)
end

-- ---------------------------------------------------------------------------
-- Check 3: both ends short.
-- ---------------------------------------------------------------------------
print("Check 3: both-ends shortfall")
do
    local note = {
        kind = "partial_coverage",
        candidate_path = "/fixture/X.mov",
        covered_start_tc = 100050,
        covered_end_tc   = 100150,
        rate = 25,
    }
    local clip = { source_in = 100000, source_out = 100200 }
    local lines = ofc._build_partial_coverage_lines(note, clip)
    local text = text_of(lines)
    assert((text:find("head", 1, true) or text:find("start", 1, true))
        and (text:find("tail", 1, true) or text:find("end", 1, true)),
        "both-ends-short must mention both boundaries:\n" .. text)
    assert(text:find("50", 1, true),
        "both deltas (50 each side) must appear:\n" .. text)
end

-- ---------------------------------------------------------------------------
-- Check 4: candidate fully covers clip — rejected for non-extent reason.
-- ---------------------------------------------------------------------------
print("Check 4: candidate covers clip fully (non-extent rejection)")
do
    local note = {
        kind = "partial_coverage",
        candidate_path = "/fixture/Y.mov",
        covered_start_tc = 100000,
        covered_end_tc   = 100200,
        rate = 25,
    }
    local clip = { source_in = 100050, source_out = 100150 }
    local lines = ofc._build_partial_coverage_lines(note, clip)
    local text = text_of(lines)
    assert(text:find("Y.mov", 1, true),
        "candidate name must appear:\n" .. text)
    assert(not text:find("short", 1, true),
        "non-shortfall branch must not claim 'short':\n" .. text)
end

-- ---------------------------------------------------------------------------
-- Check 5: build_lines integration — full frame should suppress the
-- generic "File not found" message and render the partial-coverage
-- detail instead.
-- ---------------------------------------------------------------------------
print("Check 5: build_lines suppresses generic 'File not found'")
do
    local json = require("dkjson")
    local metadata = {
        media_path = "/Volumes/AnamBack4 Joe/Footage/Day 12/A035/A035_11200114_C056.mov",
        error_code = "FileNotFound",
        error_msg = "File not found: /Volumes/AnamBack4 Joe/...",
        offline_note = json.encode({
            kind = "partial_coverage",
            candidate_path = "/fixture/Day 12/A035/A035_11200114_C056.mov",
            covered_start_tc = 100000,
            covered_end_tc = 100100,
            rate = 25,
        }),
        clip = { source_in = 100000, source_out = 100103 },
    }
    local lines = ofc._build_lines(metadata)
    local text = text_of(lines)
    assert(text:find("A035_11200114_C056.mov", 1, true),
        "filename must still appear:\n" .. text)
    assert(text:find("short", 1, true) and text:find("3", 1, true),
        "must describe the 3-frame shortfall:\n" .. text)
    assert(not text:find("File not found: ", 1, true),
        "must NOT contain the misleading raw error_msg:\n" .. text)
end

print("✅ test_offline_frame_partial_coverage.lua passed")
