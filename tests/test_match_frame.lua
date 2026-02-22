#!/usr/bin/env luajit

-- Test MatchFrame command
-- Verifies: playhead-centric clip resolution, selection tiebreaker, master clip linking

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')

local TEST_DB = "/tmp/jve/test_match_frame.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

db:exec([[
    INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, width, height)
    VALUES ('default_sequence', 'default_project', 'Sequence', 30, 1, 1920, 1080);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v2', 'default_sequence', 'V2', 'VIDEO', 2, 1);
]])

db:exec([[
    INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, created_at, modified_at)
    VALUES ('media_a', 'default_project', 'clip_a.mov', '/tmp/clip_a.mov', 100, 30.0, 0, 0);

    INSERT INTO clips (id, track_id, media_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled, master_clip_id)
    VALUES ('clip_v1', 'track_v1', 'media_a', 0, 100, 0, 100, 30, 1, 1, 'master_clip_a');
    INSERT INTO clips (id, track_id, media_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled, master_clip_id)
    VALUES ('clip_v2', 'track_v2', 'media_a', 0, 100, 0, 100, 30, 1, 1, 'master_clip_b');
    INSERT INTO clips (id, track_id, media_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled)
    VALUES ('clip_no_parent', 'track_v1', 'media_a', 200, 100, 0, 100, 30, 1, 1);
]])

-- Track focus_master_clip calls for verification
local focus_calls = {}

-- Mock project_browser
local project_browser = {
    focus_master_clip = function(master_id, opts)
        table.insert(focus_calls, {master_id = master_id, opts = opts})
        return true
    end
}
package.loaded['ui.project_browser'] = project_browser

-- Clips in UI state (track_id present for track resolution)
local clip_v1 = {id = 'clip_v1', track_id = 'track_v1', master_clip_id = 'master_clip_a', timeline_start = 0, duration = 100}
local clip_v2 = {id = 'clip_v2', track_id = 'track_v2', master_clip_id = 'master_clip_b', timeline_start = 0, duration = 100}
local clip_no_parent = {id = 'clip_no_parent', track_id = 'track_v1', timeline_start = 200, duration = 100}

-- Mock timeline_state
local timeline_state = {
    playhead_position = 50,
    clips = {clip_v1, clip_v2, clip_no_parent},
    selected_clips = {},
    tracks = {
        {id = 'track_v1', track_type = 'VIDEO', track_index = 1},
        {id = 'track_v2', track_type = 'VIDEO', track_index = 2},
    },
}

function timeline_state.get_selected_clips() return timeline_state.selected_clips end
function timeline_state.get_selected_edges() return {} end
function timeline_state.set_selection(_) end
function timeline_state.reload_clips() end
function timeline_state.get_playhead_position() return timeline_state.playhead_position end
function timeline_state.set_playhead_position(pos) timeline_state.playhead_position = pos end
function timeline_state.get_clips() return timeline_state.clips end
function timeline_state.get_clips_at_time(time_value)
    local matches = {}
    for _, clip in ipairs(timeline_state.clips) do
        local clip_end = clip.timeline_start + clip.duration
        if time_value >= clip.timeline_start and time_value < clip_end then
            table.insert(matches, clip)
        end
    end
    return matches
end
function timeline_state.get_track_by_id(track_id)
    for _, track in ipairs(timeline_state.tracks) do
        if track.id == track_id then return track end
    end
    return nil
end
function timeline_state.get_sequence_frame_rate() return {fps_numerator = 30, fps_denominator = 1} end
function timeline_state.capture_viewport() return {start_value = 0, duration_value = 500} end
function timeline_state.restore_viewport(_) end
function timeline_state.push_viewport_guard() return 1 end
function timeline_state.pop_viewport_guard() return 0 end

package.loaded['ui.timeline.timeline_state'] = timeline_state

command_manager.init('default_sequence', 'default_project')

print("=== MatchFrame Tests ===")

-- Test 1: No clips under playhead → error
print("Test 1: No clips under playhead")
focus_calls = {}
timeline_state.playhead_position = 150  -- gap between clips
timeline_state.selected_clips = {}
local result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(not result.success, "Should fail when no clips under playhead")
assert(result.error_message:find("No clips under playhead"), "Error: " .. tostring(result.error_message))

-- Test 2: Single clip under playhead, no selection → uses it
print("Test 2: Single clip under playhead, no selection")
focus_calls = {}
timeline_state.playhead_position = 250  -- only clip_no_parent here, but it has no master
timeline_state.selected_clips = {}
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(not result.success, "Should fail - clip_no_parent has no master")
assert(result.error_message:find("not linked"), "Error: " .. tostring(result.error_message))

-- Test 3: Single clip under playhead with parent → success
print("Test 3: Clip under playhead with master clip")
focus_calls = {}
-- Put playhead at 50, only clip_v1 (track_v1) and clip_v2 (track_v2) overlap
-- Remove clip_v2 temporarily to test single-clip case
local saved_clips = timeline_state.clips
timeline_state.clips = {clip_v1, clip_no_parent}
timeline_state.playhead_position = 50
timeline_state.selected_clips = {}
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed: " .. tostring(result.error_message))
assert(#focus_calls == 1)
assert(focus_calls[1].master_id == 'master_clip_a', "Should focus master_clip_a")
timeline_state.clips = saved_clips

-- Test 4: Multiple clips under playhead, no selection → topmost (highest track_index)
print("Test 4: Multiple clips, no selection, picks topmost")
focus_calls = {}
timeline_state.playhead_position = 50  -- clip_v1 (track_index=1) and clip_v2 (track_index=2)
timeline_state.selected_clips = {}
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed: " .. tostring(result.error_message))
assert(#focus_calls == 1)
assert(focus_calls[1].master_id == 'master_clip_b',
    "Should pick topmost (V2, track_index=2), got " .. tostring(focus_calls[1].master_id))

-- Test 5: Multiple clips under playhead, lower one selected → uses selected
print("Test 5: Multiple clips, lower one selected")
focus_calls = {}
timeline_state.playhead_position = 50
timeline_state.selected_clips = {clip_v2}  -- select clip on V2 (track_index=2)
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed: " .. tostring(result.error_message))
assert(#focus_calls == 1)
assert(focus_calls[1].master_id == 'master_clip_b',
    "Should pick selected V2 clip, got " .. tostring(focus_calls[1].master_id))

-- Test 6: Multiple clips under playhead, both selected → topmost selected
print("Test 6: Multiple clips, both selected, picks topmost selected")
focus_calls = {}
timeline_state.playhead_position = 50
timeline_state.selected_clips = {clip_v2, clip_v1}  -- both selected, v2 listed first
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "Should succeed: " .. tostring(result.error_message))
assert(#focus_calls == 1)
assert(focus_calls[1].master_id == 'master_clip_b',
    "Should pick topmost selected (V2, track_index=2), got " .. tostring(focus_calls[1].master_id))

-- Test 7: skip_focus option passes through
print("Test 7: skip_focus option")
focus_calls = {}
timeline_state.playhead_position = 50
timeline_state.selected_clips = {clip_v1}
result = command_manager.execute("MatchFrame", { project_id = "default_project", skip_focus = true })
assert(result.success, "Should succeed")
assert(focus_calls[1].opts.skip_focus == true, "skip_focus should pass through")

-- Test 8: skip_activate option passes through
print("Test 8: skip_activate option")
focus_calls = {}
timeline_state.playhead_position = 50
timeline_state.selected_clips = {clip_v1}
result = command_manager.execute("MatchFrame", { project_id = "default_project", skip_activate = true })
assert(result.success, "Should succeed")
assert(focus_calls[1].opts.skip_activate == true, "skip_activate should pass through")

print("✅ test_match_frame.lua passed")
