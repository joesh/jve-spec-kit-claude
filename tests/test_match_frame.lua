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

-- Stub sequence monitor: records load_sequence calls so tests can verify
-- which master clip was loaded without needing Qt widgets.
local load_calls = {}
local stub_source_monitor = {
    sequence_id = nil,
    load_sequence = function(self, sequence_id)
        self.sequence_id = sequence_id
        table.insert(load_calls, sequence_id)
    end,
}

package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
    get_sequence_monitor = function(view_id)
        assert(view_id == "source_monitor",
            "unexpected view_id: " .. tostring(view_id))
        return stub_source_monitor
    end,
}

package.loaded["ui.focus_manager"] = {
    focus_panel = function() end,
    get_focused_panel = function() return "timeline" end,
    set_focused_panel = function() end,
}

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
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('default_project', 'Default Project', 'resample', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    ) VALUES (
        'default_sequence', 'default_project', 'Sequence', 'nested',
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

    -- V13 master sequence + track + media_ref for media_a
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
VALUES ('master_media_a', 'default_project', 'media_a_master', 'master', 30, 1, 48000, 1920, 1080, strftime('%s','now'), strftime('%s','now'));
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('master_v_media_a', 'master_media_a', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = 'master_v_media_a' WHERE id = 'master_media_a';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mr_media_a', 'default_project', 'master_media_a', 'master_v_media_a', 'media_a', 0, 500, 0, 500, 1, 1.0, 0, strftime('%s','now'), strftime('%s','now'));

INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
VALUES
    
    ('master_clip_a', 'default_project', 'Master A', NULL, 'master_media_a', 'master_clip_a', 0, 500, 0, 500, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('master_clip_b', 'default_project', 'Master B', NULL, 'master_media_a', 'master_clip_b', 0, 500, 0, 500, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('master_clip_audio_a1', 'default_project', 'Master Audio A1', NULL, 'master_media_a', 'master_clip_audio_a1', 0, 500, 0, 500, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('clip_v1', 'default_project', 'Clip V1', 'track_v1', 'master_media_a', 'default_sequence', 0, 200, 10, 210, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('clip_v2', 'default_project', 'Clip V2', 'track_v2', 'master_media_a', 'default_sequence', 100, 100, 0, 100, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('clip_no_parent', 'default_project', 'No Parent', 'track_v1', 'master_media_a', 'default_sequence', 300, 100, 0, 100, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('clip_a1', 'default_project', 'Audio A1', 'track_a1', 'master_media_a', 'default_sequence', 0, 200, 0, 200, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('clip_a2', 'default_project', 'Audio A2', 'track_a2', 'master_media_a', 'default_sequence', 0, 200, 0, 200, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('clip_a3', 'default_project', 'Audio A3', 'track_a3', 'master_media_a', 'default_sequence', 0, 200, 0, 200, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
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
load_calls = {}
timeline_state.set_playhead_position(250)  -- gap
timeline_state.set_selection({})
local result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(not result.success, "Should fail when no clips under playhead")
assert(result.error_message:find("No clips under playhead"), "Error: " .. tostring(result.error_message))

-- Test 2: Single clip under playhead, no master → error
print("Test 2: Clip without master clip")
load_calls = {}
timeline_state.set_playhead_position(350)  -- only clip_no_parent
timeline_state.set_selection({})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(not result.success, "Should fail - clip_no_parent has no master")
assert(result.error_message:find("not linked"), "Error: " .. tostring(result.error_message))

-- Test 3: Single clip under playhead with master → success
print("Test 3: Single clip under playhead with master clip")
load_calls = {}
timeline_state.set_playhead_position(50)  -- only clip_v1 (clip_v2 starts at 100)
timeline_state.set_selection({})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed: " .. tostring(result.error_message))
assert(#load_calls == 1)
assert(load_calls[1] == 'master_clip_a', "Should load master_clip_a")

-- Test 4: Multiple clips under playhead, no selection → topmost (highest track_index)
print("Test 4: Multiple clips, no selection, picks topmost")
load_calls = {}
timeline_state.set_playhead_position(150)  -- clip_v1 (track_index=1) + clip_v2 (track_index=2)
timeline_state.set_selection({})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed: " .. tostring(result.error_message))
assert(#load_calls == 1)
assert(load_calls[1] == 'master_clip_b',
    "Should pick topmost (V2, track_index=2), got " .. tostring(load_calls[1]))

-- Test 5: Multiple clips under playhead, one selected → uses selected
print("Test 5: Multiple clips, V2 selected")
load_calls = {}
timeline_state.set_playhead_position(150)
timeline_state.set_selection({clip_v2})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed: " .. tostring(result.error_message))
assert(#load_calls == 1)
assert(load_calls[1] == 'master_clip_b',
    "Should pick selected V2 clip, got " .. tostring(load_calls[1]))

-- Test 6: Multiple clips under playhead, both selected → topmost selected
print("Test 6: Multiple clips, both selected, picks topmost selected")
load_calls = {}
timeline_state.set_playhead_position(150)
timeline_state.set_selection({clip_v2, clip_v1})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed: " .. tostring(result.error_message))
assert(#load_calls == 1)
assert(load_calls[1] == 'master_clip_b',
    "Should pick topmost selected (V2, track_index=2), got " .. tostring(load_calls[1]))

-- Test 7: MatchFrame does NOT touch browser selection (only loads source viewer)
print("Test 7: MatchFrame does not touch browser")
load_calls = {}
timeline_state.set_playhead_position(50)
timeline_state.set_selection({clip_v1})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed")
assert(#load_calls == 1, "Should call source_viewer.load_master_clip exactly once")
-- source_viewer.load_master_clip is the only external call — no browser interaction

-- Test 8: source_viewer.load_master_clip error surfaces (not swallowed)
print("Test 8: source_viewer error surfaces")
load_calls = {}
timeline_state.set_playhead_position(50)
timeline_state.set_selection({})
local source_viewer = require("ui.source_viewer")
local orig_load = source_viewer.load_master_clip
source_viewer.load_master_clip = function() error("source viewer exploded") end
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(not result.success, "Should fail when source_viewer throws")
assert(result.error_message:match("source viewer exploded"),
    "Error message should contain original error, got: " .. tostring(result.error_message))
source_viewer.load_master_clip = orig_load
print("  ✓ source_viewer error surfaced")

-- Test 9: Video clips trump audio clips when nothing selected
-- Bug regression: audio clip on A3 (track_index=3) was picked over video on V1 (track_index=1)
-- because pick_topmost only compared track_index without considering track_type.
print("Test 9: Video clips trump audio clips when nothing selected")
load_calls = {}
timeline_state.set_playhead_position(50)  -- clip_v1 (V1) + clip_a1 (A1) + clip_a2 (A2) + clip_a3 (A3)
timeline_state.set_selection({})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed: " .. tostring(result.error_message))
assert(#load_calls == 1)
assert(load_calls[1] == 'master_clip_a',
    "Should pick video clip (V1) over audio clips (A1-A3), got " .. tostring(load_calls[1]))

-- Test 10: Multiple video+audio, no selection → topmost VIDEO wins
print("Test 10: Multiple video+audio clips, no selection, topmost video wins")
load_calls = {}
timeline_state.set_playhead_position(150)  -- clip_v1 (V1) + clip_v2 (V2) + clip_a1-a3 (A1-A3)
timeline_state.set_selection({})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed: " .. tostring(result.error_message))
assert(#load_calls == 1)
assert(load_calls[1] == 'master_clip_b',
    "Should pick topmost VIDEO (V2/master_clip_b), got " .. tostring(load_calls[1]))

-- Test 11: Selected audio clip under playhead still wins (selection overrides type preference)
print("Test 11: Selected audio clip overrides video preference")
load_calls = {}
local clip_a1 = timeline_state.get_clip_by_id('clip_a1')
assert(clip_a1, "clip_a1 should be loaded from DB")
timeline_state.set_playhead_position(50)
timeline_state.set_selection({clip_a1})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed: " .. tostring(result.error_message))
assert(#load_calls == 1)
assert(load_calls[1] == 'master_clip_audio_a1',
    "Selected audio clip should win, got " .. tostring(load_calls[1]))

-- Test 12: MatchFrame sets master clip marks to clip's source_in/source_out
-- clip_v1: timeline_start=0, source_in=10, source_out=210, playhead at 50
-- Expected: master mark_in=10, mark_out=210, playhead_frame=10+(50-0)=60
print("Test 12: MatchFrame sets marks and playhead on master clip")
load_calls = {}
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

-- Test 13: MatchFrame with playhead deeper into clip
-- clip_v2: timeline_start=100, source_in=0, source_out=100, playhead at 150
-- Expected: master mark_in=0, mark_out=100, playhead_frame=0+(150-100)=50
print("Test 13: MatchFrame playhead mapping with offset clip")
load_calls = {}
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

-- Test 14: Out-of-range source position → set_playhead asserts → error surfaced
-- Simulates DRP import bug where media.duration is timeline edit duration (short)
-- but timeline clip's source range references deeper into the real file.
-- The assert in Sequence:set_playhead catches this at the write boundary.
print("Test 14: Out-of-range playhead asserts via set_playhead")
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
load_calls = {}
timeline_state.set_playhead_position(550)  -- inside clip_overrange [500, 600)
timeline_state.set_selection({})
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
-- playhead = 800 + (550 - 500) = 850, but master_clip_a has 500 frames → assert fires
assert(not result.success, "Should fail: source position 850 exceeds master clip's 500 frames")
assert(result.error_message:find("set_playhead") or result.error_message:find("set_in") or result.error_message:find("set_out"),
    "Error should mention bounds validation, got: " .. tostring(result.error_message))

-- Cleanup
timeline_state.set_selection({})
os.remove(TEST_DB)
print("✅ test_match_frame.lua passed")
