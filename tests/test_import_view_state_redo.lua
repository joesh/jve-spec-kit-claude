#!/usr/bin/env luajit

-- Test that FCP7 import preserves view state across undo/redo
-- This test simulates the real app flow including timeline_state

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local timeline_state = require('ui.timeline.timeline_state')
local Sequence = require('models.sequence')
local Rational = require('core.rational')
local Command = require('command')

local TEST_DB = "/tmp/jve/test_import_view_state_redo.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))
db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
                           view_start_frame, view_duration_frames, playhead_frame, created_at, modified_at)
    VALUES ('placeholder_seq', 'default_project', 'Placeholder', 'timeline', 24, 1, 48000, 1920, 1080,
            0, 240, 0, strftime('%s','now'), strftime('%s','now'));

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'placeholder_seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

command_manager.init('placeholder_seq', 'default_project')

-- Simple FCP7 XML with clips
local xml_content = [[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE xmeml>
<xmeml version="4">
  <sequence id="seq-view-test">
    <name>View State Test</name>
    <duration>120</duration>
    <rate><timebase>24</timebase><ntsc>FALSE</ntsc></rate>
    <timecode>
      <rate><timebase>24</timebase><ntsc>FALSE</ntsc></rate>
      <string>00:00:00:00</string>
      <frame>0</frame>
      <displayformat>NDF</displayformat>
    </timecode>
    <media>
      <video>
        <format>
          <samplecharacteristics>
            <width>1920</width>
            <height>1080</height>
            <rate><timebase>24</timebase><ntsc>FALSE</ntsc></rate>
          </samplecharacteristics>
        </format>
        <track>
          <clipitem id="clip1">
            <name>Clip 1</name>
            <start>0</start>
            <end>60</end>
            <in>0</in>
            <out>60</out>
            <file id="file1">
              <name>test_media.mov</name>
              <duration>200</duration>
              <rate><timebase>24</timebase><ntsc>FALSE</ntsc></rate>
              <pathurl>file:///tmp/test_media.mov</pathurl>
            </file>
          </clipitem>
          <clipitem id="clip2">
            <name>Clip 2</name>
            <start>60</start>
            <end>120</end>
            <in>0</in>
            <out>60</out>
            <file id="file1"/>
          </clipitem>
        </track>
      </video>
    </media>
  </sequence>
</xmeml>
]]

print("Step 1: Import FCP7 XML")
command_manager.begin_command_event("script")

local import_cmd = Command.create("ImportFCP7XML", "default_project")
import_cmd:set_parameter("project_id", "default_project")
import_cmd:set_parameter("xml_contents", xml_content)
import_cmd:set_parameter("xml_path", "/tmp/test_view_state.xml")

local result = command_manager.execute(import_cmd)
assert(result.success, "Import should succeed: " .. tostring(result.error_message))

-- Find the imported sequence
local imported_seq_id = nil
local seq_query = db:prepare("SELECT id FROM sequences WHERE name = 'View State Test'")
if seq_query and seq_query:exec() and seq_query:next() then
    imported_seq_id = seq_query:value(0)
end
if seq_query then seq_query:finalize() end
assert(imported_seq_id, "Imported sequence should exist")

-- Switch timeline_state to view the imported sequence (like user opening it)
timeline_state.init(imported_seq_id, 'default_project')

-- Check initial zoom-to-fit viewport via timeline_state (as the app sees it)
local vp_start = timeline_state.get_viewport_start_time()
local vp_dur = timeline_state.get_viewport_duration()
local playhead = timeline_state.get_playhead_position()

print(string.format("  After import (timeline_state): viewport_start=%d, viewport_duration=%d, playhead=%d",
    vp_start.frames, vp_dur.frames, playhead.frames))

assert(vp_dur.frames == 132,
    "Initial viewport should be zoom-to-fit (132 frames)")

print("Step 2: User modifies view state via timeline_state")
-- Simulate user zooming in and moving playhead via timeline_state (like real UI)
-- Note: set_viewport_duration centers around playhead, so set playhead first
timeline_state.set_playhead_position(Rational.new(35, 24, 1))
-- Now set viewport - duration first (which will center around playhead 35)
timeline_state.set_viewport_duration(Rational.new(40, 24, 1))
-- Then adjust start to our desired position
timeline_state.set_viewport_start_time(Rational.new(20, 24, 1))
timeline_state.persist_state_to_db(true)  -- Force immediate persist

vp_start = timeline_state.get_viewport_start_time()
vp_dur = timeline_state.get_viewport_duration()
playhead = timeline_state.get_playhead_position()
print(string.format("  Modified (timeline_state): viewport_start=%d, viewport_duration=%d, playhead=%d",
    vp_start.frames, vp_dur.frames, playhead.frames))

-- Verify the database has correct values before undo
local seq_before_undo = Sequence.load(imported_seq_id)
print(string.format("  Before undo (database): viewport_start=%d, viewport_duration=%d, playhead=%d",
    seq_before_undo.viewport_start_time.frames,
    seq_before_undo.viewport_duration.frames,
    seq_before_undo.playhead_position.frames))

assert(seq_before_undo.viewport_start_time.frames == 20,
    string.format("Before undo, DB viewport_start should be 20, got %d", seq_before_undo.viewport_start_time.frames))
assert(seq_before_undo.playhead_position.frames == 35,
    string.format("Before undo, DB playhead should be 35, got %d", seq_before_undo.playhead_position.frames))

print("Step 3: Undo import")
local undo_result = command_manager.undo()
assert(undo_result.success, "Undo should succeed: " .. tostring(undo_result.error_message))

-- Verify sequence is deleted
local seq_after_undo = Sequence.load(imported_seq_id)
assert(seq_after_undo == nil, "Sequence should be deleted after undo")
print("  Sequence deleted")

print("Step 4: Redo import")
local redo_result = command_manager.redo()
assert(redo_result.success, "Redo should succeed: " .. tostring(redo_result.error_message))

-- After redo, the executor calls timeline_state.init() to reload view state
-- Verify timeline_state now has the correct restored values
vp_start = timeline_state.get_viewport_start_time()
vp_dur = timeline_state.get_viewport_duration()
playhead = timeline_state.get_playhead_position()
print(string.format("  After redo (timeline_state): viewport_start=%d, viewport_duration=%d, playhead=%d",
    vp_start.frames, vp_dur.frames, playhead.frames))
-- In the real app, the user is already "viewing" this sequence, so the UI
-- doesn't know it needs to re-init. timeline_state still has stale cached values.

-- Check that database has the correct restored values BEFORE any persist
local seq_after_redo = Sequence.load(imported_seq_id)
print(string.format("  After redo (database): viewport_start=%d, viewport_duration=%d, playhead=%d",
    seq_after_redo.viewport_start_time.frames,
    seq_after_redo.viewport_duration.frames,
    seq_after_redo.playhead_position.frames))

assert(seq_after_redo.viewport_start_time.frames == 20,
    string.format("DB viewport_start should be 20 after redo, got %d", seq_after_redo.viewport_start_time.frames))
assert(seq_after_redo.viewport_duration.frames == 40,
    string.format("DB viewport_duration should be 40 after redo, got %d", seq_after_redo.viewport_duration.frames))
assert(seq_after_redo.playhead_position.frames == 35,
    string.format("DB playhead should be 35 after redo, got %d", seq_after_redo.playhead_position.frames))

print("Step 5: Simulate user action that triggers persist (without re-init)")
-- User clicks somewhere, which triggers timeline_state.persist_state_to_db()
-- timeline_state still has stale cached values from before undo!
timeline_state.persist_state_to_db(true)

-- Check that database STILL has correct values (stale cache shouldn't overwrite)
local seq_after_persist = Sequence.load(imported_seq_id)
print(string.format("  After persist (database): viewport_start=%d, viewport_duration=%d, playhead=%d",
    seq_after_persist.viewport_start_time.frames,
    seq_after_persist.viewport_duration.frames,
    seq_after_persist.playhead_position.frames))

assert(seq_after_persist.viewport_start_time.frames == 20,
    string.format("viewport_start should still be 20 after persist, got %d", seq_after_persist.viewport_start_time.frames))
assert(seq_after_persist.viewport_duration.frames == 40,
    string.format("viewport_duration should still be 40 after persist, got %d", seq_after_persist.viewport_duration.frames))
assert(seq_after_persist.playhead_position.frames == 35,
    string.format("playhead should still be 35 after persist, got %d", seq_after_persist.playhead_position.frames))

print("Step 6: Check what UI would display (timeline_state cached values)")
-- The user sees what timeline_state has in memory, not database values.
-- After redo, timeline_state should have the correct restored values.
vp_start = timeline_state.get_viewport_start_time()
vp_dur = timeline_state.get_viewport_duration()
playhead = timeline_state.get_playhead_position()
print(string.format("  timeline_state shows: viewport_start=%d, viewport_duration=%d, playhead=%d",
    vp_start.frames, vp_dur.frames, playhead.frames))

-- These MUST match the restored values, not stale cached values from before undo
assert(vp_start.frames == 20,
    string.format("timeline_state viewport_start should be 20, got %d (user sees wrong zoom!)", vp_start.frames))
assert(vp_dur.frames == 40,
    string.format("timeline_state viewport_duration should be 40, got %d (user sees wrong zoom!)", vp_dur.frames))
assert(playhead.frames == 35,
    string.format("timeline_state playhead should be 35, got %d", playhead.frames))

command_manager.end_command_event()
os.remove(TEST_DB)
print("✅ Import view state preserved across undo/redo")
