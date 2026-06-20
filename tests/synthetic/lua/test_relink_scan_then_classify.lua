#!/usr/bin/env luajit
--- Relink scan/classify split: a single filesystem scan must be reusable
--- across multiple rule sets, so the user can toggle matching rules and see
--- the result list update WITHOUT re-scanning or re-probing.
--
-- Domain behavior under test (no implementation names in assertions beyond
-- the two public entry points):
--   - scan_candidates() walks the search tree once and returns a context.
--   - classify_batch(context, rules) reports outcomes for that context.
--   - Re-running classify_batch on the SAME context with a different rule
--     set yields different outcomes — proving classification is independent
--     of the (expensive) scan.
--
-- Concrete case: a file whose embedded timecode sits AHEAD of the clip's
-- stored media origin (i.e. the file was head-trimmed). With "Accept Trimmed
-- Media" OFF the timecode rule rejects it; with the rule ON the same context
-- relinks it (the clip's source range lies within the file). The user flips
-- one checkbox; the rejected item becomes relinked.
local test_env = require("test_env")

_G.qt_create_single_shot_timer = function() end
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

print("=== test_relink_scan_then_classify.lua ===")

local media_relinker = require("core.media_relinker")

-- Real fixture WAV with known BWF time_reference at 48kHz.
local FIXTURE_FILE = test_env.require_fixture(
    "tests/fixtures/media/anamnesis-trimmed"
    .. "/Volumes/AnamBack4 Joe/Footage/Day 12/DAY12 Sound"
    .. "/SCENE1_WT-T001.WAV")
local FIXTURE_TC = 2384442240   -- file's embedded TC (samples @ 48kHz)
local TC_RATE = 48000

local SEARCH_DIR = "/tmp/jve/relink_scan_classify_test"

os.execute(string.format("rm -rf %q", SEARCH_DIR))
os.execute(string.format("mkdir -p %q", SEARCH_DIR))
os.execute(string.format("cp %q %q", FIXTURE_FILE, SEARCH_DIR .. "/SCENE1_WT-T001.WAV"))

-- Clip's stored media origin sits 1s BEFORE the file's real TC: the candidate
-- file looks head-trimmed relative to what the project remembers. The clip's
-- source range (2s..3s into the file) is comfortably inside the file.
local STORED_ORIGIN = FIXTURE_TC - TC_RATE          -- 1s earlier than file
local media_info = {
    media_id = "scan-classify-001",
    media_path = FIXTURE_FILE,
    media_name = "SCENE1_WT-T001.WAV",
    media_start_tc_value = STORED_ORIGIN,
    media_start_tc_rate = TC_RATE,
    width = 0, height = 0,
    clips = {{
        clip_id = "c1",
        source_in  = FIXTURE_TC + 2 * TC_RATE,
        source_out = FIXTURE_TC + 3 * TC_RATE,
        fps_num = TC_RATE, fps_den = 1,
        clip_kind = "sequence", clip_name = "scan-classify",
    }},
}

local function rules(trimmed)
    return {
        match_filename = true,
        match_timecode = true,
        match_resolution = false,
        match_frame_rate = false,
        accept_trimmed_media = trimmed,
        accept_filename_suffixes = false,
    }
end

-- ---- Scan ONCE ----------------------------------------------------------
local context = media_relinker.scan_candidates({media_info}, {SEARCH_DIR})
assert(type(context) == "table", "scan_candidates must return a context table")

-- ---- Classify the SAME context under two rule sets ----------------------
local off = media_relinker.classify_batch({media_info}, context, rules(false))
local on  = media_relinker.classify_batch({media_info}, context, rules(true))

-- Trimmed OFF: head-trimmed file fails the timecode rule.
assert(#off.relinked == 0, string.format(
    "trimmed OFF: expected 0 relinked, got %d", #off.relinked))
assert(#off.failed == 1 and off.failed[1].kind == "rejected", string.format(
    "trimmed OFF: expected 1 rejected, got %d failed", #off.failed))
assert(off.failed[1].relinkable_if_trimmed,
    "trimmed OFF: rejection must be flagged relinkable_if_trimmed")
print("  ✓ trimmed OFF → rejected, flagged relinkable_if_trimmed")

-- Trimmed ON: same scan context, one checkbox flipped → relinked.
assert(#on.relinked == 1, string.format(
    "trimmed ON: expected 1 relinked, got %d (failed=%d)",
    #on.relinked, #on.failed))
assert(on.relinked[1].new_path, "relinked entry must carry new_path")
print("  ✓ trimmed ON (same context) → relinked")

os.execute(string.format("rm -rf %q", SEARCH_DIR))

print("\n✅ test_relink_scan_then_classify.lua passed")
