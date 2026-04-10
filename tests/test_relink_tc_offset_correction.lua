#!/usr/bin/env luajit
--- Relink TC tests: source_in/source_out are absolute TC and must never change.
-- Relink only changes which file backs a clip. The C++ decoder computes
-- file_pos = source_in - first_sample_tc at decode time.
--
-- Tests:
-- 1. Relink to file with different TC start — source_in unchanged
-- 2. Relink to file with same TC start — source_in unchanged
-- 3. Relink to trimmed file that CONTAINS the clip's TC range — accepted
-- 4. Relink to trimmed file that does NOT contain the clip's TC range — rejected
local test_env = require("test_env")

_G.qt_create_single_shot_timer = function() end
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

print("=== test_relink_tc_offset_correction.lua ===")

local media_relinker = require("core.media_relinker")

-- Real fixture file with known BWF time_reference=2384442240 at 48kHz
local FIXTURE_FILE = test_env.require_fixture(
    "tests/fixtures/media/anamnesis/2026-02-28-anamnesis joe edit-mm"
    .. "/Volumes/AnamBack4 Joe/Footage/Day 12/DAY12 Sound"
    .. "/SCENE1_WT-T001.WAV")
local FIXTURE_TC = 2384442240   -- BWF time_reference in samples at 48kHz
local TC_RATE = 48000

local SEARCH_DIR = "/tmp/jve/relink_tc_test"

local function setup_search_dir()
    os.execute(string.format("mkdir -p %q", SEARCH_DIR))
    os.execute(string.format("cp %q %q", FIXTURE_FILE, SEARCH_DIR .. "/SCENE1_WT-T001.WAV"))
end

local function cleanup_search_dir()
    os.execute(string.format("rm -rf %q", SEARCH_DIR))
end

local function make_media_info(source_in, source_out, media_tc)
    local clip_id = "test-clip-" .. tostring(math.random(99999))
    return {
        media_id = "test-media-001",
        media_path = FIXTURE_FILE,
        media_name = "SCENE1_WT-T001.WAV",
        media_start_tc_value = media_tc,
        media_start_tc_rate = TC_RATE,
        width = 0, height = 0,
        clips = {{
            clip_id = clip_id,
            source_in = source_in,
            source_out = source_out,
            fps_num = TC_RATE,
            fps_den = 1,
            clip_kind = "timeline",
            clip_name = "TC-Test",
        }},
    }
end

local function relink_one(media_info, rules_override)
    setup_search_dir()
    local rules = {
        match_filename = true,
        match_timecode = false,
        match_resolution = false,
        match_frame_rate = false,
        accept_trimmed_media = false,
        accept_filename_suffixes = false,
    }
    if rules_override then
        for k, v in pairs(rules_override) do rules[k] = v end
    end
    local results = media_relinker.relink_media_batch(
        {media_info},
        { search_paths = {SEARCH_DIR}, matching_rules = rules })
    cleanup_search_dir()
    return results
end

---------------------------------------------------------------------------------
-- Test 1: Relink to file with DIFFERENT TC start — source_in stays unchanged
---------------------------------------------------------------------------------
print("\n--- Test 1: different TC start — source_in unchanged ---")
do
    -- Clip was made from a file starting at TC 2383776000 (different from fixture's 2384442240)
    local ORIGINAL_TC = 2383776000
    local source_in = ORIGINAL_TC + 100000
    local source_out = ORIGINAL_TC + 200000

    local results = relink_one(make_media_info(source_in, source_out, ORIGINAL_TC))

    assert(#results.relinked == 1,
        string.format("expected 1 relinked, got %d", #results.relinked))

    local entry = results.relinked[1]
    assert(entry.new_source_in == source_in,
        string.format("source_in must not change: expected %d, got %d",
            source_in, entry.new_source_in))
    assert(entry.new_source_out == source_out,
        string.format("source_out must not change: expected %d, got %d",
            source_out, entry.new_source_out))

    -- Verify the decoder would compute a valid file_pos with the NEW file
    local file_pos = entry.new_source_in - FIXTURE_TC
    print(string.format("  file_pos = %d (old file TC=%d, new file TC=%d)",
        file_pos, ORIGINAL_TC, FIXTURE_TC))
    -- file_pos may be negative if the clip's content falls before the new file's start.
    -- That's a containment issue, not a relink issue. The point is source_in didn't change.
    print("  ✓ source_in/source_out unchanged despite different file TC")
end

---------------------------------------------------------------------------------
-- Test 2: Relink to file with SAME TC start — source_in stays unchanged
---------------------------------------------------------------------------------
print("\n--- Test 2: same TC start — source_in unchanged ---")
do
    local source_in = FIXTURE_TC + 100000
    local source_out = FIXTURE_TC + 200000

    local results = relink_one(make_media_info(source_in, source_out, FIXTURE_TC))

    assert(#results.relinked == 1, "expected 1 relinked")
    local entry = results.relinked[1]
    assert(entry.new_source_in == source_in,
        string.format("source_in unchanged: expected %d, got %d",
            source_in, entry.new_source_in))
    assert(entry.new_source_out == source_out,
        string.format("source_out unchanged: expected %d, got %d",
            source_out, entry.new_source_out))

    local file_pos = entry.new_source_in - FIXTURE_TC
    assert(file_pos >= 0,
        string.format("file_pos should be >= 0 when TCs match: got %d", file_pos))
    print(string.format("  file_pos = %d (valid ✓)", file_pos))
    print("  ✓ source_in/source_out unchanged, file_pos valid")
end

---------------------------------------------------------------------------------
-- Test 3: Trimmed file that CONTAINS clip's TC range — accepted
---------------------------------------------------------------------------------
print("\n--- Test 3: trimmed file containing clip range — accepted ---")
do
    -- Clip uses TC range well within the fixture file
    local source_in = FIXTURE_TC + 48000   -- 1 second into file
    local source_out = FIXTURE_TC + 96000  -- 2 seconds into file

    local results = relink_one(
        make_media_info(source_in, source_out, FIXTURE_TC),
        { match_timecode = true, accept_trimmed_media = true })

    assert(#results.relinked == 1,
        string.format("clip within file range should be accepted, got %d relinked, %d failed",
            #results.relinked, #results.failed))
    local entry = results.relinked[1]
    assert(entry.new_source_in == source_in, "source_in unchanged")
    assert(entry.new_source_out == source_out, "source_out unchanged")
    print("  ✓ trimmed file containing clip range accepted, source coords unchanged")
end

---------------------------------------------------------------------------------
-- Test 4: Trimmed file that does NOT contain clip's TC range — rejected
---------------------------------------------------------------------------------
print("\n--- Test 4: trimmed file NOT containing clip range — rejected ---")
do
    -- Clip uses TC range FAR outside the fixture file
    -- Fixture starts at FIXTURE_TC (~49:40). Put clip at TC 0 (way before file start).
    local source_in = 48000     -- 1 second absolute TC
    local source_out = 96000    -- 2 seconds absolute TC

    local results = relink_one(
        make_media_info(source_in, source_out, 0),
        { match_timecode = true, accept_trimmed_media = true })

    -- Should NOT relink — clip's TC range is outside the file
    assert(#results.relinked == 0,
        string.format("clip outside file range should be rejected, got %d relinked",
            #results.relinked))
    print("  ✓ clip outside file's TC range correctly rejected")
end

print("\n✅ test_relink_tc_offset_correction.lua passed")
