#!/usr/bin/env luajit

-- Test MatchFrame command
-- Verifies: playhead-centric clip resolution, selection tiebreaker, master clip linking
-- Uses REAL timeline_state — no mock.
--
-- Clip layout (designed so playhead position alone selects scenarios):
--   clip_v1:        V1 [0, 200)   master_clip_a
--   clip_v2:        V2 [100, 200) master_clip_b
--   clip_no_parent: V1 [300, 400) no master
--
-- Playhead positions:
--   50  → only clip_v1 (single clip with master)
--   150 → clip_v1 + clip_v2 (multi-clip, tiebreaker tests)
--   250 → gap (no clips)
--   350 → only clip_no_parent (no master)

require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

-- Mock project_browser to capture focus_master_clip calls
local focus_calls = {}
local project_browser = {
    focus_master_clip = function(master_id, opts)
        table.insert(focus_calls, {master_id = master_id, opts = opts})
        return true
    end
}
package.loaded['ui.project_browser'] = project_browser

local database = require('core.database')
local command_manager = require('core.command_manager')
local timeline_state = require('ui.timeline.timeline_state')

local TEST_DB = "/tmp/jve/test_match_frame.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    ) VALUES (
        'default_sequence', 'default_project', 'Sequence', 'timeline',
        30, 1, 48000, 1920, 1080, 0, 500, 0,
        '[]', '[]', '[]', 0, %d, %d
    );

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v2', 'default_sequence', 'V2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
                       width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media_a', 'default_project', 'clip_a.mov', '/tmp/clip_a.mov', 500, 30, 1,
            1920, 1080, 0, 'prores', '{}', %d, %d);

    INSERT INTO clips (
        id, project_id, clip_kind, name, track_id, media_id, master_clip_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at
    ) VALUES
        ('clip_v1', 'default_project', 'timeline', 'Clip V1', 'track_v1', 'media_a', 'master_clip_a', 'default_sequence',
         0, 200, 0, 200, 30, 1, 1, 0, %d, %d),
        ('clip_v2', 'default_project', 'timeline', 'Clip V2', 'track_v2', 'media_a', 'master_clip_b', 'default_sequence',
         100, 100, 0, 100, 30, 1, 1, 0, %d, %d),
        ('clip_no_parent', 'default_project', 'timeline', 'No Parent', 'track_v1', 'media_a', NULL, 'default_sequence',
         300, 100, 0, 100, 30, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now, now, now))

command_manager.init('default_sequence', 'default_project')

-- Get real clip objects from state for selection
local clip_v1 = timeline_state.get_clip_by_id('clip_v1')
local clip_v2 = timeline_state.get_clip_by_id('clip_v2')
assert(clip_v1, "clip_v1 should be loaded from DB")
assert(clip_v2, "clip_v2 should be loaded from DB")

print("=== MatchFrame Tests ===")

-- Test 1: No clips under playhead → error
print("Test 1: No clips under playhead")
focus_calls = {}
timeline_state.set_playhead_position(250)  -- gap
timeline_state.set_selection({})
local result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(not result.success, "Should fail when no clips under playhead")
assert(result.error_message:find("No clips under playhead"), "Error: " .. tostring(result.error_message))

-- Test 2: Single clip under playhead, no master → error
print("Test 2: Clip without master clip")
focus_calls = {}
timeline_state.set_playhead_position(350)  -- only clip_no_parent
timeline_state.set_selection({})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(not result.success, "Should fail - clip_no_parent has no master")
assert(result.error_message:find("not linked"), "Error: " .. tostring(result.error_message))

-- Test 3: Single clip under playhead with master → success
print("Test 3: Single clip under playhead with master clip")
focus_calls = {}
timeline_state.set_playhead_position(50)  -- only clip_v1 (clip_v2 starts at 100)
timeline_state.set_selection({})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed: " .. tostring(result.error_message))
assert(#focus_calls == 1)
assert(focus_calls[1].master_id == 'master_clip_a', "Should focus master_clip_a")

-- Test 4: Multiple clips under playhead, no selection → topmost (highest track_index)
print("Test 4: Multiple clips, no selection, picks topmost")
focus_calls = {}
timeline_state.set_playhead_position(150)  -- clip_v1 (track_index=1) + clip_v2 (track_index=2)
timeline_state.set_selection({})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed: " .. tostring(result.error_message))
assert(#focus_calls == 1)
assert(focus_calls[1].master_id == 'master_clip_b',
    "Should pick topmost (V2, track_index=2), got " .. tostring(focus_calls[1].master_id))

-- Test 5: Multiple clips under playhead, one selected → uses selected
print("Test 5: Multiple clips, V2 selected")
focus_calls = {}
timeline_state.set_playhead_position(150)
timeline_state.set_selection({clip_v2})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed: " .. tostring(result.error_message))
assert(#focus_calls == 1)
assert(focus_calls[1].master_id == 'master_clip_b',
    "Should pick selected V2 clip, got " .. tostring(focus_calls[1].master_id))

-- Test 6: Multiple clips under playhead, both selected → topmost selected
print("Test 6: Multiple clips, both selected, picks topmost selected")
focus_calls = {}
timeline_state.set_playhead_position(150)
timeline_state.set_selection({clip_v2, clip_v1})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed: " .. tostring(result.error_message))
assert(#focus_calls == 1)
assert(focus_calls[1].master_id == 'master_clip_b',
    "Should pick topmost selected (V2, track_index=2), got " .. tostring(focus_calls[1].master_id))

-- Test 7: skip_focus option passes through
print("Test 7: skip_focus option")
focus_calls = {}
timeline_state.set_playhead_position(50)
timeline_state.set_selection({clip_v1})
result = command_manager.execute("MatchFrame", { project_id = "default_project", skip_focus = true })
assert(result.success, "Should succeed")
assert(focus_calls[1].opts.skip_focus == true, "skip_focus should pass through")

-- Test 8: skip_activate option passes through
print("Test 8: skip_activate option")
focus_calls = {}
timeline_state.set_playhead_position(50)
timeline_state.set_selection({clip_v1})
result = command_manager.execute("MatchFrame", { project_id = "default_project", skip_activate = true })
assert(result.success, "Should succeed")
assert(focus_calls[1].opts.skip_activate == true, "skip_activate should pass through")

-- Test 9: focus_master_clip throws → error surfaced (not swallowed)
print("Test 9: focus_master_clip error surfaces")
focus_calls = {}
timeline_state.set_playhead_position(50)
timeline_state.set_selection({})
local orig_focus = project_browser.focus_master_clip
project_browser.focus_master_clip = function() error("browser exploded") end
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(not result.success, "Should fail when focus_master_clip throws")
assert(result.error_message:match("browser exploded"),
    "Error message should contain original error, got: " .. tostring(result.error_message))
project_browser.focus_master_clip = orig_focus
print("  ✓ focus_master_clip error surfaced")

-- Test 10: focus_master_clip returns false → error surfaced
print("Test 10: focus_master_clip returns false")
focus_calls = {}
timeline_state.set_playhead_position(50)
timeline_state.set_selection({})
project_browser.focus_master_clip = function() return false end
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(not result.success, "Should fail when focus_master_clip returns false")
assert(result.error_message:match("Failed to focus"),
    "Error should say failed to focus, got: " .. tostring(result.error_message))
project_browser.focus_master_clip = orig_focus
print("  ✓ focus_master_clip false surfaced")

-- Cleanup
timeline_state.set_selection({})
os.remove(TEST_DB)
print("✅ test_match_frame.lua passed")
