#!/usr/bin/env luajit

-- TDD test: end_undo_group stamps playhead_value_post on last nested command.
-- Bug: nested commands never captured playhead_value_post, so redo_group
-- couldn't restore playhead position after redo.

require('test_env')

_G.qt_create_single_shot_timer = function() end

package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
local timeline_state = require('ui.timeline.timeline_state')
local Command = require('command')

print("=== Undo Group playhead_value_post Tests ===")

local db_path = "/tmp/jve/test_undo_group_playhead_post.db"
os.remove(db_path)
os.remove(db_path .. "-wal")
os.remove(db_path .. "-shm")

database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Disable overlap triggers
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_insert;")
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_update;")

local test_env = require('test_env')
local Project = require("models.project")
local Sequence = require("models.sequence")
local Track = require("models.track")
local Media = require("models.media")

local project = Project.create("Test Project", { fps_mismatch_policy = 'resample' })
project:save()

local seq = Sequence.create("Test Seq", project.id,
    {  fps_numerator = 30, fps_denominator = 1 }, 1920, 1080,
    { kind = "nested", audio_rate = 48000 })
seq:save()

Track.create_video("V1", seq.id, { index = 1 }):save()

-- Create media + masterclip
local media = Media.create({
    id = "media_v", project_id = project.id,
    file_path = "/tmp/jve/v.mov", name = "V",
    duration_frames = 100, fps_numerator = 30, fps_denominator = 1,
    width = 1920, height = 1080, audio_channels = 0,
})
media:save(db)
local mc_id = test_env.create_test_masterclip_sequence(
    project.id, "V Master", 30, 1, 100, "media_v")

command_manager.init(seq.id, project.id)

-- Set playhead at 500
timeline_state.set_playhead_position(500)

-- Test 1: Insert with advance_playhead in undo group captures playhead_value_post
print("Test 1: Undo group stamps playhead_value_post on last command")
local result = command_manager.execute("Insert", {
    project_id = project.id,
    sequence_id = seq.id,
    nested_sequence_id = mc_id,
    timeline_start_frame = timeline_state.get_playhead_position(),
    advance_playhead = true,
})
assert(result.success, "Insert should succeed: " .. tostring(result.error_message))

-- After insert, playhead should have advanced (500 + 100 = 600)
local post_playhead = timeline_state.get_playhead_position()
assert(post_playhead == 600,
    string.format("playhead should be 600 after insert, got %d", post_playhead))

-- Find the last command and verify playhead_value_post
local current_seq_num = command_manager.get_stack_state().current_sequence_number
local last_cmd = Command.load_at_sequence(current_seq_num, project.id)
assert(last_cmd, "should find command at cursor")
assert(last_cmd.playhead_value_post == 600,
    string.format("playhead_value_post should be 600, got %s",
        tostring(last_cmd.playhead_value_post)))

-- Test 2: Undo restores to pre-insert playhead, redo restores to post
print("Test 2: Redo restores playhead_value_post from group")
command_manager.undo()
assert(timeline_state.get_playhead_position() == 500,
    string.format("playhead should be 500 after undo, got %d",
        timeline_state.get_playhead_position()))

command_manager.redo()
assert(timeline_state.get_playhead_position() == 600,
    string.format("playhead should be 600 after redo, got %d",
        timeline_state.get_playhead_position()))

print("✅ test_undo_group_playhead_post.lua passed")
