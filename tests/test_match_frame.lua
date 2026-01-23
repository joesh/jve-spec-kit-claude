#!/usr/bin/env luajit

-- Test MatchFrame command
-- Verifies: selection requirement, master clip linking, project browser focus

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local Rational = require('core.rational')

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
]])

db:exec([[
    INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, created_at, modified_at)
    VALUES ('media_a', 'default_project', 'clip_a.mov', '/tmp/clip_a.mov', 100, 30.0, 0, 0);

    INSERT INTO clips (id, track_id, media_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled, parent_clip_id)
    VALUES ('clip_a', 'track_v1', 'media_a', 0, 100, 0, 100, 30, 1, 1, 'master_clip_a');
    INSERT INTO clips (id, track_id, media_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled)
    VALUES ('clip_no_parent', 'track_v1', 'media_a', 100, 100, 0, 100, 30, 1, 1);
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

-- Mock timeline_state
local timeline_state = {
    playhead_position = Rational.new(50, 30, 1),
    clips = {
        {id = 'clip_a', parent_clip_id = 'master_clip_a', timeline_start = Rational.new(0, 30, 1), duration = Rational.new(100, 30, 1)},
        {id = 'clip_no_parent', timeline_start = Rational.new(100, 30, 1), duration = Rational.new(100, 30, 1)},
    },
    selected_clips = {},
}

function timeline_state.get_selected_clips() return timeline_state.selected_clips end
function timeline_state.get_selected_edges() return {} end
function timeline_state.set_selection(_) end
function timeline_state.reload_clips() end
function timeline_state.get_playhead_position() return timeline_state.playhead_position end
function timeline_state.set_playhead_position(pos) timeline_state.playhead_position = pos end
function timeline_state.get_clips() return timeline_state.clips end
function timeline_state.get_sequence_frame_rate() return {fps_numerator = 30, fps_denominator = 1} end
function timeline_state.capture_viewport() return {start_value = 0, duration_value = 500} end
function timeline_state.restore_viewport(_) end
function timeline_state.push_viewport_guard() return 1 end
function timeline_state.pop_viewport_guard() return 0 end

package.loaded['ui.timeline.timeline_state'] = timeline_state

command_manager.init('default_sequence', 'default_project')

print("=== MatchFrame Tests ===")

-- Test 1: MatchFrame with no selection fails
print("Test 1: MatchFrame requires selection")
focus_calls = {}
timeline_state.selected_clips = {}
local result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(not result.success, "MatchFrame should fail with no selection")
assert(result.error_message:find("No clips selected"), "Error should mention no selection")
assert(#focus_calls == 0, "focus_master_clip should not be called")

-- Test 2: MatchFrame with clip that has parent_clip_id
print("Test 2: MatchFrame with linked clip")
focus_calls = {}
timeline_state.selected_clips = {timeline_state.clips[1]}  -- clip_a with parent_clip_id
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "MatchFrame should succeed with linked clip: " .. tostring(result.error_message))
assert(#focus_calls == 1, "focus_master_clip should be called once")
assert(focus_calls[1].master_id == 'master_clip_a',
    string.format("Should focus master_clip_a, got %s", tostring(focus_calls[1].master_id)))

-- Test 3: MatchFrame with clip that has no parent_clip_id fails
print("Test 3: MatchFrame with unlinked clip")
focus_calls = {}
timeline_state.selected_clips = {timeline_state.clips[2]}  -- clip_no_parent
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(not result.success, "MatchFrame should fail with unlinked clip")
assert(result.error_message:find("not linked"), "Error should mention not linked to master")
assert(#focus_calls == 0, "focus_master_clip should not be called")

-- Test 4: MatchFrame with multiple clips uses first linked one
print("Test 4: MatchFrame with multiple clips")
focus_calls = {}
-- Put unlinked first, then linked
timeline_state.selected_clips = {timeline_state.clips[2], timeline_state.clips[1]}
result = command_manager.execute("MatchFrame", { project_id = "default_project" })
assert(result.success, "MatchFrame should succeed finding linked clip in selection")
assert(#focus_calls == 1, "focus_master_clip should be called once")
assert(focus_calls[1].master_id == 'master_clip_a', "Should find and focus master_clip_a")

-- Test 5: MatchFrame passes skip_focus option
print("Test 5: MatchFrame skip_focus option")
focus_calls = {}
timeline_state.selected_clips = {timeline_state.clips[1]}
result = command_manager.execute("MatchFrame", { project_id = "default_project", skip_focus = true })
assert(result.success, "MatchFrame should succeed")
assert(focus_calls[1].opts.skip_focus == true, "skip_focus should be passed through")

-- Test 6: MatchFrame passes skip_activate option
print("Test 6: MatchFrame skip_activate option")
focus_calls = {}
timeline_state.selected_clips = {timeline_state.clips[1]}
result = command_manager.execute("MatchFrame", { project_id = "default_project", skip_activate = true })
assert(result.success, "MatchFrame should succeed")
assert(focus_calls[1].opts.skip_activate == true, "skip_activate should be passed through")

print("✅ MatchFrame tests passed")
