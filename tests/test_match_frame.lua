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
local Sequence = require('models.sequence')

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
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_a1', 'default_sequence', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_a2', 'default_sequence', 'A2', 'AUDIO', 2, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_a3', 'default_sequence', 'A3', 'AUDIO', 3, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
                       width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media_a', 'default_project', 'clip_a.mov', '/tmp/clip_a.mov', 500, 30, 1,
            1920, 1080, 0, 'prores', '{}', %d, %d);

    -- Master clips (masterclip IS-a sequence, stored as clip_kind='master')
    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    ) VALUES
        ('master_clip_a', 'default_project', 'Master A', 'masterclip',
         30, 1, 48000, 1920, 1080, 0, 500, 0,
         '[]', '[]', '[]', 0, %d, %d),
        ('master_clip_b', 'default_project', 'Master B', 'masterclip',
         30, 1, 48000, 1920, 1080, 0, 500, 0,
         '[]', '[]', '[]', 0, %d, %d),
        ('master_clip_audio_a1', 'default_project', 'Master Audio A1', 'masterclip',
         30, 1, 48000, 1920, 1080, 0, 500, 0,
         '[]', '[]', '[]', 0, %d, %d);

    INSERT INTO clips (
        id, project_id, clip_kind, name, track_id, media_id, master_clip_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at
    ) VALUES
        -- Master clip entries (clip_kind='master', owner_sequence_id = self)
        ('master_clip_a', 'default_project', 'master', 'Master A', NULL, 'media_a', NULL, 'master_clip_a',
         0, 500, 0, 500, 30, 1, 1, 0, %d, %d),
        ('master_clip_b', 'default_project', 'master', 'Master B', NULL, 'media_a', NULL, 'master_clip_b',
         0, 500, 0, 500, 30, 1, 1, 0, %d, %d),
        ('master_clip_audio_a1', 'default_project', 'master', 'Master Audio A1', NULL, 'media_a', NULL, 'master_clip_audio_a1',
         0, 500, 0, 500, 30, 1, 1, 0, %d, %d),
        -- Timeline clips
        ('clip_v1', 'default_project', 'timeline', 'Clip V1', 'track_v1', 'media_a', 'master_clip_a', 'default_sequence',
         0, 200, 10, 210, 30, 1, 1, 0, %d, %d),
        ('clip_v2', 'default_project', 'timeline', 'Clip V2', 'track_v2', 'media_a', 'master_clip_b', 'default_sequence',
         100, 100, 0, 100, 30, 1, 1, 0, %d, %d),
        ('clip_no_parent', 'default_project', 'timeline', 'No Parent', 'track_v1', 'media_a', NULL, 'default_sequence',
         300, 100, 0, 100, 30, 1, 1, 0, %d, %d),
        ('clip_a1', 'default_project', 'timeline', 'Audio A1', 'track_a1', 'media_a', 'master_clip_audio_a1', 'default_sequence',
         0, 200, 0, 200, 30, 1, 1, 0, %d, %d),
        ('clip_a2', 'default_project', 'timeline', 'Audio A2', 'track_a2', 'media_a', 'master_clip_audio_a1', 'default_sequence',
         0, 200, 0, 200, 30, 1, 1, 0, %d, %d),
        ('clip_a3', 'default_project', 'timeline', 'Audio A3', 'track_a3', 'media_a', 'master_clip_audio_a1', 'default_sequence',
         0, 200, 0, 200, 30, 1, 1, 0, %d, %d);
]], now, now,           -- projects
    now, now,               -- sequences (default_sequence)
    now, now,               -- media
    now, now, now, now, now, now,  -- sequences (3 masters × 2)
    now, now, now, now, now, now,  -- clips (3 masters × 2)
    now, now, now, now, now, now,  -- clips (3 timeline: v1, v2, no_parent × 2)
    now, now, now, now, now, now)) -- clips (3 audio: a1, a2, a3 × 2)

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

-- Test 7: skip_focus always true (browser panel should never steal focus)
print("Test 7: skip_focus always true")
focus_calls = {}
timeline_state.set_playhead_position(50)
timeline_state.set_selection({clip_v1})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed")
assert(focus_calls[1].opts.skip_focus == true, "skip_focus should always be true")

-- Test 8: focus_master_clip throws → error surfaced (not swallowed)
print("Test 8: focus_master_clip error surfaces")
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

-- Test 9: focus_master_clip returns false → error surfaced
print("Test 9: focus_master_clip returns false")
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

-- Test 10: Video clips trump audio clips when nothing selected
-- Bug regression: audio clip on A3 (track_index=3) was picked over video on V1 (track_index=1)
-- because pick_topmost only compared track_index without considering track_type.
print("Test 10: Video clips trump audio clips when nothing selected")
focus_calls = {}
timeline_state.set_playhead_position(50)  -- clip_v1 (V1) + clip_a1 (A1) + clip_a2 (A2) + clip_a3 (A3)
timeline_state.set_selection({})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed: " .. tostring(result.error_message))
assert(#focus_calls == 1)
assert(focus_calls[1].master_id == 'master_clip_a',
    "Should pick video clip (V1) over audio clips (A1-A3), got " .. tostring(focus_calls[1].master_id))

-- Test 11: Multiple video+audio, no selection → topmost VIDEO wins
print("Test 11: Multiple video+audio clips, no selection, topmost video wins")
focus_calls = {}
timeline_state.set_playhead_position(150)  -- clip_v1 (V1) + clip_v2 (V2) + clip_a1-a3 (A1-A3)
timeline_state.set_selection({})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed: " .. tostring(result.error_message))
assert(#focus_calls == 1)
assert(focus_calls[1].master_id == 'master_clip_b',
    "Should pick topmost VIDEO (V2/master_clip_b), got " .. tostring(focus_calls[1].master_id))

-- Test 12: Selected audio clip under playhead still wins (selection overrides type preference)
print("Test 12: Selected audio clip overrides video preference")
focus_calls = {}
local clip_a1 = timeline_state.get_clip_by_id('clip_a1')
assert(clip_a1, "clip_a1 should be loaded from DB")
timeline_state.set_playhead_position(50)
timeline_state.set_selection({clip_a1})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed: " .. tostring(result.error_message))
assert(#focus_calls == 1)
assert(focus_calls[1].master_id == 'master_clip_audio_a1',
    "Selected audio clip should win, got " .. tostring(focus_calls[1].master_id))

-- Test 13: MatchFrame sets master clip marks to clip's source_in/source_out
-- clip_v1: timeline_start=0, source_in=10, source_out=210, playhead at 50
-- Expected: master mark_in=10, mark_out=210, playhead_frame=10+(50-0)=60
print("Test 13: MatchFrame sets marks and playhead on master clip")
focus_calls = {}
timeline_state.set_playhead_position(50)
timeline_state.set_selection({})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed: " .. tostring(result.error_message))
local master_a = Sequence.load('master_clip_a')
assert(master_a, "master_clip_a should be loadable as sequence")
assert(master_a.mark_in == 10,
    string.format("mark_in should be 10 (source_in), got %s", tostring(master_a.mark_in)))
assert(master_a.mark_out == 210,
    string.format("mark_out should be 210 (source_out), got %s", tostring(master_a.mark_out)))
assert(master_a.playhead_position == 60,
    string.format("playhead_position should be 60 (source_in + playhead - timeline_start), got %s",
        tostring(master_a.playhead_position)))

-- Test 14: MatchFrame with playhead deeper into clip
-- clip_v2: timeline_start=100, source_in=0, source_out=100, playhead at 150
-- Expected: master mark_in=0, mark_out=100, playhead_frame=0+(150-100)=50
print("Test 14: MatchFrame playhead mapping with offset clip")
focus_calls = {}
timeline_state.set_playhead_position(150)
timeline_state.set_selection({clip_v2})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed: " .. tostring(result.error_message))
local master_b = Sequence.load('master_clip_b')
assert(master_b, "master_clip_b should be loadable as sequence")
assert(master_b.mark_in == 0,
    string.format("mark_in should be 0, got %s", tostring(master_b.mark_in)))
assert(master_b.mark_out == 100,
    string.format("mark_out should be 100, got %s", tostring(master_b.mark_out)))
assert(master_b.playhead_position == 50,
    string.format("playhead_position should be 50, got %s", tostring(master_b.playhead_position)))

-- Test 15: Out-of-range source position → set_playhead asserts → error surfaced
-- Simulates DRP import bug where media.duration is timeline edit duration (short)
-- but timeline clip's source range references deeper into the real file.
-- The assert in Sequence:set_playhead catches this at the write boundary.
print("Test 15: Out-of-range playhead asserts via set_playhead")
db:exec(string.format([[
    INSERT INTO clips (
        id, project_id, clip_kind, name, track_id, media_id, master_clip_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at
    ) VALUES (
        'clip_overrange', 'default_project', 'timeline', 'Over Range', 'track_v1', 'media_a',
        'master_clip_a', 'default_sequence',
        500, 100, 800, 900, 30, 1, 1, 0, %d, %d
    )
]], now, now))
-- Reload timeline state to pick up the new clip
timeline_state.init('default_sequence', 'default_project')
focus_calls = {}
timeline_state.set_playhead_position(550)  -- inside clip_overrange [500, 600)
timeline_state.set_selection({})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
-- playhead = 800 + (550 - 500) = 850, but master_clip_a has 500 frames → assert fires
assert(not result.success, "Should fail: source position 850 exceeds master clip's 500 frames")
assert(result.error_message:find("set_playhead") or result.error_message:find("content duration"),
    "Error should mention set_playhead bounds, got: " .. tostring(result.error_message))

-- Cleanup
timeline_state.set_selection({})
os.remove(TEST_DB)
print("✅ test_match_frame.lua passed")
