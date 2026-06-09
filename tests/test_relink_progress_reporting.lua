#!/usr/bin/env luajit
--- Relink progress reporting: every media outcome must produce a progress line.
--
-- The relink dialog shows a scrolling progress log so the user can see what
-- happened to each media during a batch. Successful relinks show status lines;
-- failed and ambiguous media must ALSO produce log lines — otherwise the user
-- sees only the successes and has no visibility into why other media didn't
-- relink, which is exactly when visibility matters most.
--
-- This test is a regression guard: if progress reporting regresses to only
-- covering the happy path, users silently lose visibility into the failures
-- and ambiguities that are the whole point of showing a progress log.
require("test_env")
local test_env = require("test_env")

_G.qt_create_single_shot_timer = function() end
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

print("=== test_relink_progress_reporting.lua ===")

local media_relinker = require("core.media_relinker")

local FIXTURE_FILE = test_env.require_fixture(
    "tests/fixtures/media/anamnesis-trimmed"
    .. "/Volumes/AnamBack4 Joe/Footage/Day 12/DAY12 Sound"
    .. "/SCENE1_WT-T001.WAV")
local FIXTURE_TC = 2384442240   -- BWF time_reference in samples at 48kHz
local TC_RATE = 48000

local SEARCH_DIR = "/tmp/jve/relink_progress_test"

local function cleanup_search_dir()
    os.execute(string.format("rm -rf %q", SEARCH_DIR))
end

local function setup_with_one_copy(name)
    cleanup_search_dir()
    os.execute(string.format("mkdir -p %q", SEARCH_DIR))
    os.execute(string.format("cp %q %q", FIXTURE_FILE, SEARCH_DIR .. "/" .. name))
end

local function setup_with_two_copies(name_a, name_b)
    cleanup_search_dir()
    os.execute(string.format("mkdir -p %q", SEARCH_DIR))
    os.execute(string.format("cp %q %q", FIXTURE_FILE, SEARCH_DIR .. "/" .. name_a))
    os.execute(string.format("cp %q %q", FIXTURE_FILE, SEARCH_DIR .. "/" .. name_b))
end

--- Capturing progress callback — collects every (pct, status) tuple.
local function make_capture()
    local calls = {}
    local fn = function(pct, status)
        calls[#calls + 1] = { pct = pct, status = status }
    end
    return fn, calls
end

--- Assert that at least one captured status contains `needle`.
local function assert_status(calls, needle, scenario)
    for _, c in ipairs(calls) do
        if c.status and c.status:find(needle, 1, true) then
            return
        end
    end
    print(string.format("  FAIL: no progress status mentioned %q", needle))
    for i, c in ipairs(calls) do
        print(string.format("    [%d] status=%s pct=%s",
            i, tostring(c.status), tostring(c.pct)))
    end
    error(string.format("%s: progress status never mentioned %q", scenario, needle))
end

--------------------------------------------------------------------------------
-- Scenario 1: successful relink — baseline confirming the capture pattern
--------------------------------------------------------------------------------
print("\n--- Scenario 1: successful relink → status mentions media ---")
do
    setup_with_one_copy("SCENE1_WT-T001.WAV")
    local media_infos = {{
        media_id = "m1",
        media_path = "/offline/SCENE1_WT-T001.WAV",
        media_name = "SCENE1_WT-T001.WAV",
        media_start_tc_value = FIXTURE_TC,
        media_start_tc_rate = TC_RATE,
        width = 0, height = 0,
        source_extent_start = FIXTURE_TC + 48000,
        source_extent_end = FIXTURE_TC + 96000,
    }}
    local rules = {
        match_filename = true, match_timecode = true,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }
    local cb, calls = make_capture()
    local results = media_relinker.relink_media_batch(
        media_infos,
        { search_paths = {SEARCH_DIR}, matching_rules = rules },
        cb)
    cleanup_search_dir()

    assert(#results.relinked == 1, string.format(
        "baseline: expected 1 relinked, got %d", #results.relinked))
    assert_status(calls, "SCENE1_WT-T001.WAV", "successful relink")
    assert_status(calls, "relinked", "successful relink status")
    print("  ✓ successful relink emits status mentioning the media")
end

--------------------------------------------------------------------------------
-- Scenario 2: media-level failure → status mentions media
--
-- Stored TC = 0 but fixture TC is huge → tc_mismatch=true, no extent fits,
-- no clips to split → media ends up in failed bucket.
--------------------------------------------------------------------------------
print("\n--- Scenario 2: TC mismatch failure → status mentions media ---")
do
    setup_with_one_copy("SCENE1_WT-T001.WAV")
    local media_infos = {{
        media_id = "m2",
        media_path = "/offline/SCENE1_WT-T001.WAV",
        media_name = "SCENE1_WT-T001.WAV",
        media_start_tc_value = 0,
        media_start_tc_rate = TC_RATE,
        width = 0, height = 0,
        source_extent_start = 0,
        source_extent_end = 1,
    }}
    local rules = {
        match_filename = true, match_timecode = true,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = true, accept_filename_suffixes = false,
    }
    local cb, calls = make_capture()
    local results = media_relinker.relink_media_batch(
        media_infos,
        { search_paths = {SEARCH_DIR}, matching_rules = rules },
        cb)
    cleanup_search_dir()

    assert(#results.failed == 1, string.format(
        "baseline: expected 1 failed, got %d", #results.failed))
    assert(#results.relinked == 0,
        "baseline: must not be relinked")

    assert_status(calls, "SCENE1_WT-T001.WAV", "media failure")
    print("  ✓ failed media emits status mentioning the media")
end

--------------------------------------------------------------------------------
-- Scenario 3: ambiguous media → status mentions media
--
-- Two search-dir copies with the same TC both pass the media-level filter,
-- so the media ends up with two candidate files and goes to the ambiguous bucket.
--------------------------------------------------------------------------------
print("\n--- Scenario 3: ambiguous media → status mentions media ---")
do
    setup_with_two_copies("copy_A.WAV", "copy_B.WAV")
    local media_infos = {{
        media_id = "m3",
        media_path = "/offline/original.WAV",
        media_name = "original.WAV",
        media_start_tc_value = FIXTURE_TC,
        media_start_tc_rate = TC_RATE,
        width = 0, height = 0,
        source_extent_start = FIXTURE_TC + 48000,
        source_extent_end = FIXTURE_TC + 96000,
    }}
    -- Filename matching OFF so both copies survive the initial filter.
    local rules = {
        match_filename = false, match_timecode = true,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }
    local cb, calls = make_capture()
    local results = media_relinker.relink_media_batch(
        media_infos,
        { search_paths = {SEARCH_DIR}, matching_rules = rules },
        cb)
    cleanup_search_dir()

    -- Baseline sanity: must be ambiguous, not relinked or failed.
    assert(#results.ambiguous == 1, string.format(
        "baseline: expected 1 ambiguous, got %d", #results.ambiguous))
    assert(#results.relinked == 0,
        "baseline: ambiguous media must not be relinked")

    -- The "Done:" summary line mentions the count
    assert_status(calls, "1 ambiguous", "ambiguous media summary")
    print("  ✓ ambiguous media mentioned in summary status")
end

print("\n✅ test_relink_progress_reporting.lua passed")
