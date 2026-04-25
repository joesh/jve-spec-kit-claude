#!/usr/bin/env luajit
--- T010: Matching rules persistence via project settings
require("test_env")

-- No-op timer
_G.qt_create_single_shot_timer = function() end

-- Mock panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

print("=== test_matching_rules.lua ===")

local database = require("core.database")
local uuid = require("uuid")

local TEST_DB = "/tmp/jve/test_matching_rules.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
local project_id = "proj-rules"
local seq_id = uuid.generate()

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('%s', 'Rules Project', 'resample', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos,
        selected_gap_infos, current_sequence_number, created_at, modified_at)
    VALUES ('%s', '%s', 'Seq', 'nested', 25, 1, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', '[]', 0, %d, %d);
]], project_id, now, now, seq_id, project_id, now, now))

---------------------------------------------------------------------------------
-- Test 1: Default rules when key doesn't exist
---------------------------------------------------------------------------------
print("\n--- Test 1: Default rules (no key set) ---")
do
    local rules = database.get_project_setting(project_id, "relink_matching_rules")
    assert(rules == nil, "expected nil when no rules saved")
    print("  ✓ nil when no matching rules saved")
end

---------------------------------------------------------------------------------
-- Test 2: Save and load matching rules
---------------------------------------------------------------------------------
print("\n--- Test 2: Save and load matching rules ---")
do
    local rules = {
        match_filename = true,
        match_timecode = true,
        match_resolution = false,
        match_frame_rate = false,
        accept_trimmed_media = true,
        accept_filename_suffixes = false,
    }
    database.set_project_setting(project_id, "relink_matching_rules", rules)

    local loaded = database.get_project_setting(project_id, "relink_matching_rules")
    assert(loaded, "rules should be loaded")
    assert(loaded.match_filename == true, "match_filename should be true")
    assert(loaded.match_timecode == true, "match_timecode should be true")
    assert(loaded.match_resolution == false, "match_resolution should be false")
    assert(loaded.match_frame_rate == false, "match_frame_rate should be false")
    assert(loaded.accept_trimmed_media == true, "accept_trimmed_media should be true")
    assert(loaded.accept_filename_suffixes == false, "accept_filename_suffixes should be false")
    print("  ✓ matching rules round-trip through project settings")
end

---------------------------------------------------------------------------------
-- Test 3: Update existing rules
---------------------------------------------------------------------------------
print("\n--- Test 3: Update existing rules ---")
do
    local updated = {
        match_filename = true,
        match_timecode = false,
        match_resolution = true,
        match_frame_rate = true,
        accept_trimmed_media = false,
        accept_filename_suffixes = true,
    }
    database.set_project_setting(project_id, "relink_matching_rules", updated)

    local loaded = database.get_project_setting(project_id, "relink_matching_rules")
    assert(loaded.match_timecode == false, "match_timecode should be false after update")
    assert(loaded.match_resolution == true, "match_resolution should be true after update")
    assert(loaded.accept_filename_suffixes == true, "accept_filename_suffixes should be true after update")
    print("  ✓ rules updated correctly")
end

---------------------------------------------------------------------------------
-- Test 4: Rules survive alongside other project settings
---------------------------------------------------------------------------------
print("\n--- Test 4: Rules coexist with other settings ---")
do
    database.set_project_setting(project_id, "last_search_dir", "/Volumes/Media")

    -- Verify rules still intact
    local rules = database.get_project_setting(project_id, "relink_matching_rules")
    assert(rules.accept_filename_suffixes == true, "rules survived other setting write")

    -- Verify other setting also intact
    local search_dir = database.get_project_setting(project_id, "last_search_dir")
    assert(search_dir == "/Volumes/Media", "other setting intact")
    print("  ✓ rules coexist with other project settings")
end

print("\n✅ test_matching_rules.lua passed")
