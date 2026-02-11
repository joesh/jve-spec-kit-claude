#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local _ = require('core.command_implementations') -- load for side effects
local Command = require('command')
local Media = require('models.media')

local TEST_DB = "/tmp/jve/test_ripple_delete_selection.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        created_at, modified_at
    )
    VALUES ('default_sequence', 'default_project', 'Sequence', 'timeline', 30, 1, 48000, 1920, 1080, 0, 240, 0, strftime('%s','now'), strftime('%s','now'));
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v2', 'default_sequence', 'Video 2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0);
]])

local function clips_snapshot()
    local clips = {}
    local stmt = db:prepare("SELECT id, track_id, timeline_start_frame, duration_frames FROM clips ORDER BY timeline_start_frame")
    assert(stmt:exec())
    while stmt:next() do
        clips[#clips + 1] = {
            id = stmt:value(0),
            track_id = stmt:value(1),
            start_value = stmt:value(2),
            duration_value = stmt:value(3)
        }
    end
    return clips
end

local function find_clip(id)
    for _, clip in ipairs(clips_snapshot()) do
        if clip.id == id then
            return clip
        end
    end
    return nil
end

local function assert_no_overlaps()
    local stmt = db:prepare("SELECT id, track_id, timeline_start_frame, duration_frames FROM clips ORDER BY track_id, timeline_start_frame")
    local prev = {}
    while stmt:next() do
        local id = stmt:value(0)
        local track = stmt:value(1)
        local start = tonumber(stmt:value(2))
        local dur = tonumber(stmt:value(3))
        if prev[track] then
            local prev_end = prev[track].start + prev[track].dur
            assert(start >= prev_end, string.format("Overlap detected on %s: %s starts at %d before previous end %d",
                track, id, start, prev_end))
        end
        prev[track] = {start = start, dur = dur}
    end
    stmt:finalize()
end

local timeline_state = {
    clips = {},
    selected_clips = {},
    selected_edges = {},
    selected_gaps = {},
    playhead_value = 0,
    playhead_position = 0,
    viewport_start_value = 0,
    viewport_duration_frames_value = 10000,
}

local function reload_state_clips()
    timeline_state.clips = clips_snapshot()
end

function timeline_state.get_selected_clips() return timeline_state.selected_clips end
function timeline_state.get_selected_edges() return timeline_state.selected_edges end
function timeline_state.clear_edge_selection() timeline_state.selected_edges = {} end
function timeline_state.clear_gap_selection() timeline_state.selected_gaps = {} end
function timeline_state.get_selected_gaps() return timeline_state.selected_gaps end
function timeline_state.set_selection(clips) timeline_state.selected_clips = clips or {} end
function timeline_state.reload_clips() reload_state_clips() end
function timeline_state.persist_state_to_db() end
function timeline_state.apply_mutations(sequence_id, mutations)
    if mutations and (mutations.updates or mutations.deletes or mutations.inserts) then
        reload_state_clips()
        return true
    end
    return false
end
function timeline_state.consume_mutation_failure() return nil end
function timeline_state.get_clips()
    reload_state_clips()
    return timeline_state.clips
end
function timeline_state.get_sequence_id() return "default_sequence" end
function timeline_state.get_sequence_frame_rate() return {fps_numerator = 30, fps_denominator = 1} end
function timeline_state.get_playhead_position() return timeline_state.playhead_position end
function timeline_state.set_playhead_position(time_ms)
    timeline_state.playhead_position = time_ms
    timeline_state.playhead_value = time_ms
end
function timeline_state.push_viewport_guard() return 1 end
function timeline_state.pop_viewport_guard() return 0 end
function timeline_state.capture_viewport()
    return {
        start_value = timeline_state.viewport_start_value,
        duration = timeline_state.viewport_duration_frames_value,
    }
end
function timeline_state.restore_viewport(snapshot)
    if not snapshot then return end
    timeline_state.viewport_start_value = snapshot.start_value or timeline_state.viewport_start_value
    timeline_state.viewport_duration_frames_value = snapshot.duration or timeline_state.viewport_duration_frames_value
end

local function reset_timeline_state()
    while command_manager.can_undo and command_manager.can_undo() do
        local last = command_manager.get_last_command and command_manager.get_last_command("default_project") or nil
        if last and last.type == "TestCreateClip" then
            break
        end

        local result = command_manager.undo()
        if not result.success then
            local msg = result.error_message or ""
            assert(not msg:match("RippleDeleteSelection"), msg)
            break
        end
    end
    db:exec("DELETE FROM clips;")
    db:exec("DELETE FROM media;")
    timeline_state.selected_clips = {}
    timeline_state.selected_edges = {}
    timeline_state.selected_gaps = {}
    timeline_state.playhead_position = 0
end

package.loaded['ui.timeline.timeline_state'] = timeline_state

-- command_impl.register_commands({}, {}, db)
command_manager.init('default_sequence', 'default_project')

local function create_clip_command(params)
    local clip_id = params.clip_id
    local clip_duration = params.duration
    local media_id = params.media_id or (clip_id .. "_media")

    local media = Media.create({
        id = media_id,
        project_id = 'default_project',
        file_path = '/tmp/jve/' .. clip_id .. '.mov',
        file_name = clip_id .. '.mov',
        duration_frames = clip_duration,
        fps_numerator = 30,
        fps_denominator = 1
    })
    assert(media, "failed to create media for clip " .. tostring(clip_id))
    assert(media:save(db), "failed to save media for clip " .. tostring(clip_id))

    local clip = require('models.clip').create("Test Clip", media_id, {
        id = params.clip_id,
        project_id = 'default_project',
        track_id = params.track_id,
        owner_sequence_id = 'default_sequence',
        timeline_start = params.start_value,
        duration = params.duration,
        source_in = 0,
        source_out = params.duration,
        fps_numerator = 30,
        fps_denominator = 1,
        enabled = true
    })
    return clip:save(db, {skip_occlusion = true})
end

-- Register schema for TestCreateClip test command
local test_create_clip_spec = {
    args = {
        project_id = { kind = "string", required = false },
        clip_id = { kind = "string", required = true },
        track_id = { kind = "string", required = true },
        start_value = { kind = "number", required = true },
        duration = { kind = "number", required = true },
        media_id = { kind = "string", required = false },
    }
}

command_manager.register_executor("TestCreateClip", function(cmd)
    return create_clip_command({
        clip_id = cmd:get_parameter("clip_id"),
        track_id = cmd:get_parameter("track_id"),
        start_value = cmd:get_parameter("start_value"),
        duration = cmd:get_parameter("duration"),
        media_id = cmd:get_parameter("media_id")
    })
end, function(cmd)
    -- Test helper command is not meant to be undone in production; tests should not push it onto undo stack.
    -- Returning false will surface an error if an undo is attempted.
    return false, "TestCreateClip is a setup-only helper and should not be undone"
end, test_create_clip_spec)

local clip_specs = {
    {id = "clip_a", start = 0, duration = 1000},
    {id = "clip_b", start = 1000, duration = 1000},
    {id = "clip_c", start = 2000, duration = 1000},
}

for _, spec in ipairs(clip_specs) do
    local cmd = Command.create("TestCreateClip", "default_project")
    cmd:set_parameter("clip_id", spec.id)
    cmd:set_parameter("track_id", "track_v1")
    cmd:set_parameter("start_value", spec.start)
    cmd:set_parameter("duration", spec.duration)
    assert(command_manager.execute(cmd).success)
end

reload_state_clips()

timeline_state.selected_clips = {
    {id = "clip_b"}
}

local function execute_ripple_delete(ids)
    local cmd = Command.create("RippleDeleteSelection", "default_project")
    cmd:set_parameter("clip_ids", ids)
    cmd:set_parameter("sequence_id", "default_sequence")
    local result = command_manager.execute(cmd)
    assert(result.success, result.error_message or "RippleDeleteSelection failed")
end

-- Test: Ripple delete removes clip and shifts downstream clips
local original_playhead = 43210
timeline_state.playhead_position = original_playhead
execute_ripple_delete({"clip_b"})

local after_delete = clips_snapshot()
assert(#after_delete == 2, "Expected 2 clips after ripple delete")

local clip_a = after_delete[1]
local clip_c = after_delete[2]

assert(clip_a.id == "clip_a", "Clip A should remain first")
assert(clip_c.id == "clip_c", "Clip C should remain after ripple")
assert(clip_c.start_value == 1000, string.format("Clip C start_value expected 1000, got %d", clip_c.start_value))

-- Undo restores original state
local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo failed for RippleDeleteSelection")
assert(timeline_state.playhead_position == original_playhead,
    string.format("Undo should restore playhead to %d, got %d", original_playhead, timeline_state.playhead_position))
assert_no_overlaps()

local after_undo = clips_snapshot()
assert(#after_undo == 3, "Expected 3 clips after undo")

local clip_b_restored = nil
for _, clip in ipairs(after_undo) do
    if clip.id == "clip_b" then
        clip_b_restored = clip
    end
end
assert(clip_b_restored, "Clip B should be restored after undo")
assert(clip_b_restored.start_value == 1000, string.format("Clip B start_value expected 1000, got %d", clip_b_restored.start_value))

-- Redo reapplies ripple delete
local redo_result = command_manager.redo()
assert(redo_result.success, redo_result.error_message or "Redo failed for RippleDeleteSelection")

local after_redo = clips_snapshot()
assert(#after_redo == 2, "Expected 2 clips after redo")
local clip_c_after_redo = after_redo[2]
assert(clip_c_after_redo.id == "clip_c", "Clip C should still be present after redo")
assert(clip_c_after_redo.start_value == 1000, string.format("Clip C start_value expected 1000 after redo, got %d", clip_c_after_redo.start_value))

-- Regression setup: reset timeline with non-adjacent selection
assert(command_manager.undo().success, "Failed to undo ripple delete before regression setup")
db:exec("DELETE FROM clips;")
db:exec("DELETE FROM media;")
timeline_state.selected_clips = {}
timeline_state.selected_edges = {}
timeline_state.selected_gaps = {}
timeline_state.playhead_position = 0

local regression_specs = {
    {id = "clip_1", start = 0, duration = 500},   -- selected
    {id = "clip_2", start = 500, duration = 2000}, -- not selected, sits between selections
    {id = "clip_3", start = 2500, duration = 1000},-- selected (non-adjacent to clip_1)
    {id = "clip_4", start = 3500, duration = 800}, -- trailing clip to verify shifts
}

for _, spec in ipairs(regression_specs) do
    local cmd = Command.create("TestCreateClip", "default_project")
    cmd:set_parameter("clip_id", spec.id)
    cmd:set_parameter("track_id", "track_v1")
    cmd:set_parameter("start_value", spec.start)
    cmd:set_parameter("duration", spec.duration)
    assert(command_manager.execute(cmd).success)
end

reload_state_clips()

timeline_state.selected_clips = {
    {id = "clip_1"},
    {id = "clip_3"},
}

execute_ripple_delete({"clip_1", "clip_3"})

local regression_after_delete = clips_snapshot()
assert(#regression_after_delete == 2, "Expected 2 clips after ripple delete of non-adjacent selection")

local first_clip = regression_after_delete[1]
local second_clip = regression_after_delete[2]

assert(first_clip.id == "clip_2", "Clip 2 should remain and shift to the start")
assert(first_clip.start_value == 0, string.format("Clip 2 expected to start at 0, got %d", first_clip.start_value))

assert(second_clip.id == "clip_4", "Clip 4 should remain after ripple delete")
local expected_second_start = first_clip.start_value + first_clip.duration_value
assert(second_clip.start_value == expected_second_start,
    string.format("Clip 4 expected to start at %d, got %d", expected_second_start, second_clip.start_value))

local gap_between = second_clip.start_value - (first_clip.start_value + first_clip.duration_value)
assert(gap_between >= 0, "Clips should not overlap after ripple delete")

-- Multi-track regression: ripple delete shifts other tracks + restores selection on undo
reset_timeline_state()

local multi_specs = {
    {id = "mt_v1_pre", track_id = "track_v1", start = 0, duration = 500},
    {id = "mt_v1_target", track_id = "track_v1", start = 500, duration = 500},
    {id = "mt_v1_post", track_id = "track_v1", start = 1500, duration = 500},
    {id = "mt_v2_pre", track_id = "track_v2", start = 0, duration = 500},
    {id = "mt_v2_post", track_id = "track_v2", start = 2000, duration = 500},
}

for _, spec in ipairs(multi_specs) do
    local cmd = Command.create("TestCreateClip", "default_project")
    cmd:set_parameter("clip_id", spec.id)
    cmd:set_parameter("track_id", spec.track_id)
    cmd:set_parameter("start_value", spec.start)
    cmd:set_parameter("duration", spec.duration)
    assert(command_manager.execute(cmd).success)
end

reload_state_clips()

local selection_before = {{id = "mt_v1_target"}}
timeline_state.selected_clips = selection_before
local selection_playhead = 24680
timeline_state.playhead_position = selection_playhead

execute_ripple_delete({"mt_v1_target"})

local shifted_v2 = find_clip("mt_v2_post")
local expected_shift = 1500  -- downstream clip should move left by target duration (500ms)
assert(shifted_v2.start_value == expected_shift,
    string.format("Multi-track ripple should shift downstream clips on other tracks. Expected %d, got %d",
        expected_shift, shifted_v2.start_value))

local undo_multi = command_manager.undo()
assert(undo_multi.success, undo_multi.error_message or "Undo failed for multi-track ripple")
assert(timeline_state.selected_clips and timeline_state.selected_clips[1]
    and timeline_state.selected_clips[1].id == "mt_v1_target",
    "Undo should restore original selection for ripple delete")
assert(timeline_state.playhead_position == selection_playhead,
    string.format("Undo should restore playhead to %d, got %d",
        selection_playhead, timeline_state.playhead_position))
assert_no_overlaps()

local restored_v2 = find_clip("mt_v2_post")
assert(restored_v2.start_value == 2000,
    string.format("Undo should restore downstream clip position on other tracks (expected 2000, got %d)",
        restored_v2.start_value))

-- ============================================================================
-- ERROR HANDLING AND EDGE CASE TESTS
-- ============================================================================

-- Test: Empty clip_ids array should fail
print("Testing empty clip_ids (expect 'No clips selected' warning)")
reset_timeline_state()
local cmd_empty = Command.create("RippleDeleteSelection", "default_project")
cmd_empty:set_parameter("clip_ids", {})
cmd_empty:set_parameter("sequence_id", "default_sequence")
local result_empty = command_manager.execute(cmd_empty)
assert(not result_empty.success, "Empty clip_ids should fail")

-- Test: All nonexistent clip_ids should fail
print("Testing nonexistent clip_ids (expect 'Clip not found' warnings)")
reset_timeline_state()
local cmd_ghost = Command.create("RippleDeleteSelection", "default_project")
cmd_ghost:set_parameter("clip_ids", {"ghost_clip_1", "ghost_clip_2"})
cmd_ghost:set_parameter("sequence_id", "default_sequence")
local result_ghost = command_manager.execute(cmd_ghost)
assert(not result_ghost.success, "All nonexistent clip_ids should fail")

-- Test: Mixed valid/invalid clip_ids - should succeed processing valid ones
print("Testing mixed valid/invalid clip_ids (expect one 'not found' warning)")
reset_timeline_state()
for _, spec in ipairs({
    {id = "mix_a", start = 0, duration = 500},
    {id = "mix_b", start = 500, duration = 500},
    {id = "mix_c", start = 1000, duration = 500},
}) do
    local cmd = Command.create("TestCreateClip", "default_project")
    cmd:set_parameter("clip_id", spec.id)
    cmd:set_parameter("track_id", "track_v1")
    cmd:set_parameter("start_value", spec.start)
    cmd:set_parameter("duration", spec.duration)
    assert(command_manager.execute(cmd).success)
end
reload_state_clips()
timeline_state.selected_clips = {{id = "mix_b"}}

local cmd_mixed = Command.create("RippleDeleteSelection", "default_project")
cmd_mixed:set_parameter("clip_ids", {"mix_b", "nonexistent_clip"})
cmd_mixed:set_parameter("sequence_id", "default_sequence")
local result_mixed = command_manager.execute(cmd_mixed)
assert(result_mixed.success, "Mixed clip_ids should succeed for valid clips: " .. tostring(result_mixed.error_message))
assert(#clips_snapshot() == 2, "Expected 2 clips after mixed delete")
assert(not find_clip("mix_b"), "mix_b should be deleted")
assert(find_clip("mix_a") and find_clip("mix_c"), "mix_a and mix_c should remain")

-- Test: Delete first clip only (no upstream clips to preserve)
reset_timeline_state()
for _, spec in ipairs({
    {id = "first_a", start = 0, duration = 500},
    {id = "first_b", start = 500, duration = 500},
    {id = "first_c", start = 1000, duration = 500},
}) do
    local cmd = Command.create("TestCreateClip", "default_project")
    cmd:set_parameter("clip_id", spec.id)
    cmd:set_parameter("track_id", "track_v1")
    cmd:set_parameter("start_value", spec.start)
    cmd:set_parameter("duration", spec.duration)
    assert(command_manager.execute(cmd).success)
end
reload_state_clips()
timeline_state.selected_clips = {{id = "first_a"}}

local cmd_first = Command.create("RippleDeleteSelection", "default_project")
cmd_first:set_parameter("clip_ids", {"first_a"})
cmd_first:set_parameter("sequence_id", "default_sequence")
local result_first = command_manager.execute(cmd_first)
assert(result_first.success, "Delete first clip should succeed: " .. tostring(result_first.error_message))

local after_first = clips_snapshot()
assert(#after_first == 2, "Expected 2 clips after deleting first")
assert(after_first[1].id == "first_b", "first_b should now be first")
assert(after_first[1].start_value == 0, "first_b should shift to position 0")
assert(after_first[2].id == "first_c", "first_c should be second")
assert(after_first[2].start_value == 500, "first_c should shift to position 500")
assert_no_overlaps()

-- Test: Delete last clip only (no downstream clips to shift)
reset_timeline_state()
for _, spec in ipairs({
    {id = "last_a", start = 0, duration = 500},
    {id = "last_b", start = 500, duration = 500},
    {id = "last_c", start = 1000, duration = 500},
}) do
    local cmd = Command.create("TestCreateClip", "default_project")
    cmd:set_parameter("clip_id", spec.id)
    cmd:set_parameter("track_id", "track_v1")
    cmd:set_parameter("start_value", spec.start)
    cmd:set_parameter("duration", spec.duration)
    assert(command_manager.execute(cmd).success)
end
reload_state_clips()
timeline_state.selected_clips = {{id = "last_c"}}

local cmd_last = Command.create("RippleDeleteSelection", "default_project")
cmd_last:set_parameter("clip_ids", {"last_c"})
cmd_last:set_parameter("sequence_id", "default_sequence")
local result_last = command_manager.execute(cmd_last)
assert(result_last.success, "Delete last clip should succeed: " .. tostring(result_last.error_message))

local after_last = clips_snapshot()
assert(#after_last == 2, "Expected 2 clips after deleting last")
assert(after_last[1].id == "last_a" and after_last[1].start_value == 0, "last_a unchanged")
assert(after_last[2].id == "last_b" and after_last[2].start_value == 500, "last_b unchanged")
assert_no_overlaps()

-- Test: Delete all clips
reset_timeline_state()
for _, spec in ipairs({
    {id = "all_a", start = 0, duration = 500},
    {id = "all_b", start = 500, duration = 500},
}) do
    local cmd = Command.create("TestCreateClip", "default_project")
    cmd:set_parameter("clip_id", spec.id)
    cmd:set_parameter("track_id", "track_v1")
    cmd:set_parameter("start_value", spec.start)
    cmd:set_parameter("duration", spec.duration)
    assert(command_manager.execute(cmd).success)
end
reload_state_clips()
timeline_state.selected_clips = {{id = "all_a"}, {id = "all_b"}}

local cmd_all = Command.create("RippleDeleteSelection", "default_project")
cmd_all:set_parameter("clip_ids", {"all_a", "all_b"})
cmd_all:set_parameter("sequence_id", "default_sequence")
local result_all = command_manager.execute(cmd_all)
assert(result_all.success, "Delete all clips should succeed: " .. tostring(result_all.error_message))
assert(#clips_snapshot() == 0, "Expected 0 clips after deleting all")

-- Undo should restore all clips
local undo_all = command_manager.undo()
assert(undo_all.success, "Undo delete all should succeed")
assert(#clips_snapshot() == 2, "Undo should restore both clips")
assert_no_overlaps()

-- Test: Multiple undo/redo cycles maintain integrity
reset_timeline_state()
for _, spec in ipairs({
    {id = "cycle_a", start = 0, duration = 500},
    {id = "cycle_b", start = 500, duration = 500},
    {id = "cycle_c", start = 1000, duration = 500},
}) do
    local cmd = Command.create("TestCreateClip", "default_project")
    cmd:set_parameter("clip_id", spec.id)
    cmd:set_parameter("track_id", "track_v1")
    cmd:set_parameter("start_value", spec.start)
    cmd:set_parameter("duration", spec.duration)
    assert(command_manager.execute(cmd).success)
end
reload_state_clips()
timeline_state.selected_clips = {{id = "cycle_b"}}

local cmd_cycle = Command.create("RippleDeleteSelection", "default_project")
cmd_cycle:set_parameter("clip_ids", {"cycle_b"})
cmd_cycle:set_parameter("sequence_id", "default_sequence")
assert(command_manager.execute(cmd_cycle).success)

-- Cycle through undo/redo multiple times
for i = 1, 3 do
    assert(command_manager.undo().success, "Undo cycle " .. i .. " failed")
    assert(#clips_snapshot() == 3, "After undo cycle " .. i .. " expected 3 clips")
    assert(find_clip("cycle_b"), "cycle_b should exist after undo cycle " .. i)
    assert_no_overlaps()

    assert(command_manager.redo().success, "Redo cycle " .. i .. " failed")
    assert(#clips_snapshot() == 2, "After redo cycle " .. i .. " expected 2 clips")
    assert(not find_clip("cycle_b"), "cycle_b should be gone after redo cycle " .. i)
    assert_no_overlaps()
end

-- Test: Clips with gaps between them
reset_timeline_state()
for _, spec in ipairs({
    {id = "gap_a", start = 0, duration = 500},
    {id = "gap_b", start = 1000, duration = 500},  -- 500 frame gap before this
    {id = "gap_c", start = 2000, duration = 500},  -- 500 frame gap before this
}) do
    local cmd = Command.create("TestCreateClip", "default_project")
    cmd:set_parameter("clip_id", spec.id)
    cmd:set_parameter("track_id", "track_v1")
    cmd:set_parameter("start_value", spec.start)
    cmd:set_parameter("duration", spec.duration)
    assert(command_manager.execute(cmd).success)
end
reload_state_clips()
timeline_state.selected_clips = {{id = "gap_b"}}

local cmd_gap = Command.create("RippleDeleteSelection", "default_project")
cmd_gap:set_parameter("clip_ids", {"gap_b"})
cmd_gap:set_parameter("sequence_id", "default_sequence")
local result_gap = command_manager.execute(cmd_gap)
assert(result_gap.success, "Delete clip with gaps should succeed: " .. tostring(result_gap.error_message))

local after_gap = clips_snapshot()
assert(#after_gap == 2, "Expected 2 clips after gap delete")
assert(after_gap[1].id == "gap_a" and after_gap[1].start_value == 0, "gap_a unchanged")
-- gap_c should shift left by gap_b's duration (500), keeping the gap before it
assert(after_gap[2].id == "gap_c", "gap_c should remain")
assert(after_gap[2].start_value == 1500, string.format("gap_c expected at 1500, got %d", after_gap[2].start_value))
assert_no_overlaps()

print("✅ test_ripple_delete_selection.lua passed")
