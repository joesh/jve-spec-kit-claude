#!/usr/bin/env luajit
-- Test: media_relink_dialog._format_results_summary partitions failed
-- entries into "partial coverage" (candidate found, insufficient
-- extent) vs "not found" (nothing with a matching basename in the
-- search tree), and renders the list of each with the relevant detail.
--
-- The dialog previously only showed counts and "no clips matched"
-- wording when relinked == 0. Users post-relink had no visibility
-- into WHICH clips remained offline or why — now they do, and the
-- distinction drives whether to look for the file (not-found) or
-- accept the clip will stay offline with a shortfall note (partial).
package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"
require("test_env")

-- Dialog module pulls in Qt bindings at require time; stub enough of
-- qt_constants for the pure summary test. We only need the formatter.
_G.qt_create_single_shot_timer = _G.qt_create_single_shot_timer or function() end

local dialog = require("ui.media_relink_dialog")

print("=== media_relink_dialog: results summary formatter ===")

-- media_info carries a source_extent (min source_in / max source_out
-- across every clip using the media). Shortfall is computed against
-- the extent, not per-clip.
local media_infos = {
    ["mp1"] = {
        name = "A001.mov", path = "/Volumes/Cam/A001.mov",
        source_extent_start = 100000, source_extent_end = 100103,
    },
    ["mp2"] = {
        name = "A002.mov", path = "/Volumes/Cam/A002.mov",
        source_extent_start = 50000, source_extent_end = 50060,
    },
    ["mn1"] = {
        name = "B001.wav", path = "/Volumes/Audio/B001.wav",
    },
    ["ok"] = { name = "C001.mov", path = "/Volumes/Cam/C001.mov" },
}

-- One clean relink, two partial-coverage relinks (new path + coverage
-- info), one true not-found failure. Partial entries now live in
-- relinked[] because the file_path update IS the user's intent; the
-- coverage info rides alongside so downstream marks short clips offline.
local results = {
    relinked = {
        { media_id = "ok",  new_path = "/fixture/C001.mov" },
        { media_id = "mp1", new_path = "/fixture/A001.mov",
          strategy = "partial_coverage",
          coverage = {
            kind = "partial_coverage",
            candidate_path = "/fixture/A001.mov",
            covered_start_tc = 100000, covered_end_tc = 100100, rate = 25,
          } },
        { media_id = "mp2", new_path = "/fixture/A002.mov",
          strategy = "partial_coverage",
          coverage = {
            kind = "partial_coverage",
            candidate_path = "/fixture/A002.mov",
            covered_start_tc = 50005, covered_end_tc = 50055, rate = 25,
          } },
    },
    failed = {
        { media_id = "mn1",
          reason = "no filename match in search directory" },
    },
    ambiguous = {},
}

local summary = dialog._format_results_summary(results, media_infos)

-- Header counts
assert(summary:find("1 relinked", 1, true),
    "summary must report relinked count: " .. summary)
assert(summary:find("2 partial", 1, true),
    "summary must report partial count: " .. summary)
assert(summary:find("1 not found", 1, true),
    "summary must report not-found count: " .. summary)

-- Partial list includes each media's name and the candidate basename
assert(summary:find("A001.mov", 1, true), "partial must name A001.mov")
assert(summary:find("A002.mov", 1, true), "partial must name A002.mov")
-- Shortfall detail: mp1 clip [100000..100103] vs cover [100000..100100] → tail=3
assert(summary:find("3f at tail", 1, true), string.format(
    "partial must quantify tail shortfall for mp1:\n%s", summary))
-- mp2 clip [50000..50060] vs cover [50005..50055] → head=5, tail=5
assert(summary:find("5f at head", 1, true) and summary:find("5f at tail", 1, true),
    string.format("both-end shortfall for mp2:\n%s", summary))

-- Not-found list names the media and includes the reason
assert(summary:find("B001.wav", 1, true), "not-found must name B001.wav")
assert(summary:find("no filename match", 1, true),
    "not-found must include the reason: " .. summary)

-- Partial list must NOT appear in the not-found section — so ensure
-- each partial media name appears BEFORE the not-found header.
local nf_header_pos = summary:find("Not found in search tree", 1, true)
local a001_pos = summary:find("A001.mov", 1, true)
local b001_pos = summary:find("B001.wav", 1, true)
assert(a001_pos < nf_header_pos,
    "partial entries appear before Not-found section header")
assert(b001_pos > nf_header_pos,
    "not-found entries appear after Not-found section header")

-- Audio-media shortfall: when the media's stored_rate is the audio
-- sample rate (DRP imports of audio-only WAVs get start_tc_rate set to
-- the file's sample rate), the shortfall numbers are in audio samples.
-- The plain "Nf" label that worked for video at 25fps becomes confusing:
-- "(short 2048004f at tail)" reads as 2 million video frames (~22 hours)
-- but actually means 2 million samples (~43 seconds at 48 kHz). The
-- summary must surface a seconds hint so the user can tell at a glance
-- the deficit isn't actually catastrophic.
do
    local audio_infos = {
        ["aud"] = {
            name = "Smash.wav", path = "/Volumes/Cam/Smash.wav",
            -- source_extent in audio samples (target = audio_sample_rate)
            source_extent_start = 0,
            source_extent_end   = 2048004,
        },
    }
    local audio_results = {
        relinked = {
            { media_id = "aud", new_path = "/local/Smash.wav",
              strategy = "partial_coverage",
              coverage = {
                kind = "partial_coverage",
                candidate_path = "/local/Smash.wav",
                covered_start_tc = 0,
                covered_end_tc   = 0,        -- candidate covers nothing
                rate = 48000,                -- AUDIO sample rate
              } },
        },
        failed = {}, ambiguous = {},
    }
    local s = dialog._format_results_summary(audio_results, audio_infos)
    -- The raw frame count is fine; what's missing is the seconds hint
    -- that disambiguates audio samples from video frames.
    assert(s:find("2048004f", 1, true), string.format(
        "audio shortfall must still expose the raw count for diagnosis: %s", s))
    assert(s:find("~42", 1, true) or s:find("~43", 1, true), string.format(
        "REGRESSION: audio shortfall (2048004 samples @ 48000 Hz ≈ 42.7s) "
        .. "must include a seconds hint so 'Nf' isn't read as N video frames. "
        .. "Without the hint, '2048004f' looks like ~22 hours instead of 43s. "
        .. "Got: %s", s))
end

-- All-good scenario: 1 relinked, 0 failed → "all relinked" prose.
do
    local all_ok = {
        relinked = { { media_id = "ok", new_path = "/a" } },
        failed = {}, ambiguous = {},
    }
    local s = dialog._format_results_summary(all_ok, media_infos)
    assert(s:find("All media relinked successfully", 1, true),
        "all-good summary announces success: " .. s)
end

print("✅ test_relink_dialog_results_summary.lua passed")
