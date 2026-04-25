#!/usr/bin/env luajit

-- Test: SelectAll and SelectRectangle must exclude gap clips from selection.
-- Gap clips are derived state — selecting them for clip operations is wrong.

require('test_env')

_G.qt_create_single_shot_timer = function() end

package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}
-- Mock focus_manager so DeleteSelection reaches the timeline clip-delete path
package.loaded["ui.focus_manager"] = {
    get_focused_panel = function() return "timeline" end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
local timeline_state = require('ui.timeline.timeline_state')

print("=== SelectAll/SelectRectangle Gap Filtering Tests ===")

local db_path = "/tmp/jve/test_select_all_filters_gaps.db"
os.remove(db_path)
os.remove(db_path .. "-wal")
os.remove(db_path .. "-shm")

database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()
-- Two clips with a gap between them: clip_a [0, 100), gap [100, 200), clip_b [200, 300)
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj1', 'Test', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'nested', 30, 1, 48000, 1920, 1080,
        0, 500, 0, '[]', '[]', '[]', 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('tv1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO clips (id, project_id, clip_kind, track_id, owner_sequence_id, media_id, name,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES
        ('clip_a', 'proj1', 'timeline', 'tv1', 'seq1', NULL, 'A', 0, 100, 0, 100, 30, 1, 1, 0, %d, %d),
        ('clip_b', 'proj1', 'timeline', 'tv1', 'seq1', NULL, 'B', 200, 100, 0, 100, 30, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now))

command_manager.init('seq1', 'proj1')

-- Verify gaps were generated (gap between clip_a and clip_b)
local all_clips = timeline_state.get_clips()
local gap_count = 0
local media_count = 0
for _, c in ipairs(all_clips) do
    if c.clip_kind == "gap" then gap_count = gap_count + 1
    else media_count = media_count + 1 end
end
assert(gap_count > 0, "should have at least one gap clip")
assert(media_count == 2, "should have 2 media clips")

-- Test 1: SelectAll excludes gaps
print("Test 1: SelectAll excludes gap clips")
command_manager.execute("SelectAll", { project_id = "proj1", sequence_id = "seq1" })
local selected = timeline_state.get_selected_clips()
assert(#selected == 2,
    string.format("SelectAll should select 2 media clips, got %d", #selected))
for _, clip in ipairs(selected) do
    assert(clip.clip_kind ~= "gap",
        string.format("SelectAll must not include gap clip %s", clip.id))
end

-- Test 2: SelectRectangle excludes gaps
print("Test 2: SelectRectangle excludes gap clips")
timeline_state.set_selection({})  -- clear
command_manager.execute("SelectRectangle", {
    project_id = "proj1",
    sequence_id = "seq1",
    time_start = 0,
    time_end = 300,
    track_ids = { "tv1" },
})
selected = timeline_state.get_selected_clips()
assert(#selected == 2,
    string.format("SelectRectangle should select 2 media clips, got %d", #selected))
for _, clip in ipairs(selected) do
    assert(clip.clip_kind ~= "gap",
        string.format("SelectRectangle must not include gap clip %s", clip.id))
end

-- Test 3: DeleteSelection asserts on gap clips (defense in depth)
print("Test 3: DeleteSelection rejects gap clips")
-- Manually inject a gap clip into selection to test the assert
local gap_clip = nil
for _, c in ipairs(all_clips) do
    if c.clip_kind == "gap" then gap_clip = c; break end
end
assert(gap_clip, "need a gap clip for this test")

-- Directly set selection with gap clip (bypassing SelectAll filter)
local selection_state = require("ui.timeline.state.selection_state")
selection_state.set_selection({ gap_clip }, nil)

local result = command_manager.execute("DeleteSelection", {
    project_id = "proj1",
    sequence_id = "seq1",
})
-- The assert fires inside the executor, caught by command_manager's xpcall.
-- Result should be failure with gap-related error message.
assert(not result.success, "DeleteSelection should fail on gap clip in selection")
assert(result.error_message and result.error_message:find("gap"),
    string.format("error should mention 'gap', got: %s", tostring(result.error_message)))

print("✅ test_select_all_filters_gaps.lua passed")
