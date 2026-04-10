#!/usr/bin/env luajit
--- Relink progress reporting: every clip outcome must produce a progress line.
--
-- The relink dialog shows a scrolling progress log so the user can see what
-- happened to each clip during a batch. Successful relinks show "[OK] ..."
-- lines; failed and ambiguous clips must ALSO produce log lines — otherwise
-- the user sees only the successes and has no visibility into why other
-- clips didn't relink, which is exactly when visibility matters most.
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
    "tests/fixtures/media/anamnesis/2026-02-28-anamnesis joe edit-mm"
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

--- Capturing progress callback — collects every (pct, status, log_line) tuple.
local function make_capture()
    local calls = {}
    local fn = function(pct, status, log_line)
        calls[#calls + 1] = { pct = pct, status = status, log_line = log_line }
    end
    return fn, calls
end

--- Assert that at least one captured log_line contains `needle`.
-- On failure, dumps every captured call so the gap is visible.
local function assert_logged(calls, needle, scenario)
    for _, c in ipairs(calls) do
        if c.log_line and c.log_line:find(needle, 1, true) then
            return
        end
    end
    print(string.format("  FAIL: no progress log_line mentioned %q", needle))
    for i, c in ipairs(calls) do
        print(string.format("    [%d] log=%s status=%s pct=%s",
            i, tostring(c.log_line), tostring(c.status), tostring(c.pct)))
    end
    error(string.format("%s: progress log never mentioned %q", scenario, needle))
end

--------------------------------------------------------------------------------
-- Scenario 1: successful relink — baseline confirming the capture pattern
--------------------------------------------------------------------------------
print("\n--- Scenario 1: successful relink → log line mentions clip ---")
do
    setup_with_one_copy("SCENE1_WT-T001.WAV")
    local media_infos = {{
        media_id = "m1",
        media_path = "/offline/SCENE1_WT-T001.WAV",
        media_name = "SCENE1_WT-T001.WAV",
        media_start_tc_value = FIXTURE_TC,
        media_start_tc_rate = TC_RATE,
        width = 0, height = 0,
        clips = {{
            clip_id = "clip-OK",
            clip_name = "ClipNameAlphaOK",
            source_in = FIXTURE_TC + 48000,
            source_out = FIXTURE_TC + 96000,
            fps_num = TC_RATE, fps_den = 1,
            clip_kind = "timeline",
        }},
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
    assert_logged(calls, "ClipNameAlphaOK", "successful relink")
    print("  ✓ successful relink emits log line mentioning the clip")
end

--------------------------------------------------------------------------------
-- Scenario 2: per-clip containment failure → log line mentions the clip
--
-- Media has ONE candidate (so "no candidates" media-level line does NOT
-- fire), but the clip's source range falls outside the candidate's TC
-- window, so the clip ends up in the `failed` bucket.
--
-- Without per-outcome progress reporting, the user sees a media with a
-- valid candidate and has no idea why the clip wasn't relinked.
--------------------------------------------------------------------------------
print("\n--- Scenario 2: per-clip containment failure → log line mentions clip ---")
do
    setup_with_one_copy("SCENE1_WT-T001.WAV")
    -- Stored TC = 0 but fixture TC is huge → tc_mismatch=true. Clip range
    -- [0, 1] falls far below the fixture's TC window → containment fails.
    local media_infos = {{
        media_id = "m2",
        media_path = "/offline/SCENE1_WT-T001.WAV",
        media_name = "SCENE1_WT-T001.WAV",
        media_start_tc_value = 0,
        media_start_tc_rate = TC_RATE,
        width = 0, height = 0,
        clips = {{
            clip_id = "clip-FAIL",
            clip_name = "ClipNameBravoFail",
            source_in = 0,
            source_out = 1,
            fps_num = TC_RATE, fps_den = 1,
            clip_kind = "timeline",
        }},
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

    -- Baseline sanity: the clip MUST actually end up in the failed bucket —
    -- otherwise this test isn't exercising the gap.
    assert(#results.failed == 1, string.format(
        "baseline: expected 1 failed, got %d", #results.failed))
    assert(#results.relinked == 0,
        "baseline: ClipNameBravoFail must not be relinked")

    assert_logged(calls, "ClipNameBravoFail", "per-clip containment failure")
    print("  ✓ failed clip emits log line mentioning the clip")
end

--------------------------------------------------------------------------------
-- Scenario 3: ambiguous clip → log line mentions the clip
--
-- Two search-dir copies with the same TC both pass the media-level filter,
-- so a single clip ends up with two candidate files and goes to the
-- `ambiguous` bucket. The user must see which clip needs their attention.
--------------------------------------------------------------------------------
print("\n--- Scenario 3: ambiguous clip → log line mentions clip ---")
do
    setup_with_two_copies("copy_A.WAV", "copy_B.WAV")
    local media_infos = {{
        media_id = "m3",
        media_path = "/offline/original.WAV",
        media_name = "original.WAV",
        media_start_tc_value = FIXTURE_TC,
        media_start_tc_rate = TC_RATE,
        width = 0, height = 0,
        clips = {{
            clip_id = "clip-AMBIG",
            clip_name = "ClipNameCharlieAmbig",
            source_in = FIXTURE_TC + 48000,
            source_out = FIXTURE_TC + 96000,
            fps_num = TC_RATE, fps_den = 1,
            clip_kind = "timeline",
        }},
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
        "baseline: ambiguous clip must not be relinked")

    assert_logged(calls, "ClipNameCharlieAmbig", "ambiguous clip")
    print("  ✓ ambiguous clip emits log line mentioning the clip")
end

print("\n✅ test_relink_progress_reporting.lua passed")
