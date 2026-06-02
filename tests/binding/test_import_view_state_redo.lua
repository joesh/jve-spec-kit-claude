#!/usr/bin/env luajit

-- Test that FCP7 import preserves view state across undo/redo.
-- Simulates: import → user zooms+moves playhead → undo → redo → DB and
-- timeline_state both reflect the restored viewport.

require('test_env')
local ui = require('integration.ui_test_env')

print("=== test_import_view_state_redo ===")

local DB = "/tmp/jve/test_import_view_state_redo.jvp"
local _, info = ui.launch({
    db_path      = DB,
    project_name = "Default Project",
})

local database        = require('core.database')
local command_manager = require('core.command_manager')
local timeline_state  = require('ui.timeline.timeline_state')
local Sequence        = require('models.sequence')
local Command         = require('command')

-- Inline FCP7 XML with two clips so the imported timeline has known
-- duration and viewport-fit semantics.
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
            <width>1920</width><height>1080</height>
            <rate><timebase>24</timebase><ntsc>FALSE</ntsc></rate>
          </samplecharacteristics>
        </format>
        <track>
          <clipitem id="clip1"><name>Clip 1</name>
            <start>0</start><end>60</end><in>0</in><out>60</out>
            <file id="file1"><name>test_media.mov</name><duration>200</duration>
              <rate><timebase>24</timebase><ntsc>FALSE</ntsc></rate>
              <pathurl>file:///tmp/test_media.mov</pathurl>
              <media><video><samplecharacteristics>
                <width>1920</width><height>1080</height>
              </samplecharacteristics></video></media>
            </file>
          </clipitem>
          <clipitem id="clip2"><name>Clip 2</name>
            <start>60</start><end>120</end><in>0</in><out>60</out>
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

local import_cmd = Command.create("ImportFCP7XML", info.project.id)
import_cmd:set_parameter("project_id", info.project.id)
import_cmd:set_parameter("xml_contents", xml_content)
import_cmd:set_parameter("xml_path", "/tmp/test_view_state.xml")

local result = command_manager.execute(import_cmd)
assert(result.success, "Import should succeed: " .. tostring(result.error_message))

local db = database.get_connection()
local imported_seq_id = nil
local seq_query = db:prepare("SELECT id FROM sequences WHERE name = 'View State Test'")
if seq_query and seq_query:exec() and seq_query:next() then
    imported_seq_id = seq_query:value(0)
end
if seq_query then seq_query:finalize() end
assert(imported_seq_id, "Imported sequence should exist")

timeline_state.init(imported_seq_id, info.project.id)

assert(timeline_state.get_viewport_duration() == 132,
    "Initial viewport should be zoom-to-fit (132 frames)")

print("Step 2: User modifies view state via timeline_state")
timeline_state.set_playhead_position(35)
timeline_state.set_viewport_duration(40)
timeline_state.set_viewport_start_time(20)
timeline_state.persist_state_to_db(true)

local seq_before_undo = Sequence.load(imported_seq_id)
assert(seq_before_undo.viewport_start_time == 20,
    string.format("Before undo, DB viewport_start should be 20, got %d",
        seq_before_undo.viewport_start_time))
assert(seq_before_undo.playhead_position == 35,
    string.format("Before undo, DB playhead should be 35, got %d",
        seq_before_undo.playhead_position))

print("Step 3: Undo import")
local undo_result = command_manager.undo()
assert(undo_result.success, "Undo should succeed: " .. tostring(undo_result.error_message))
assert(Sequence.load(imported_seq_id) == nil, "Sequence should be deleted after undo")

print("Step 4: Redo import")
local redo_result = command_manager.redo()
assert(redo_result.success, "Redo should succeed: " .. tostring(redo_result.error_message))

local seq_after_redo = Sequence.load(imported_seq_id)
assert(seq_after_redo.viewport_start_time == 20,
    string.format("DB viewport_start should be 20 after redo, got %d",
        seq_after_redo.viewport_start_time))
assert(seq_after_redo.viewport_duration == 40,
    string.format("DB viewport_duration should be 40 after redo, got %d",
        seq_after_redo.viewport_duration))
assert(seq_after_redo.playhead_position == 35,
    string.format("DB playhead should be 35 after redo, got %d",
        seq_after_redo.playhead_position))

print("Step 5: Persist via timeline_state — must not stomp restored values")
timeline_state.persist_state_to_db(true)
local seq_after_persist = Sequence.load(imported_seq_id)
assert(seq_after_persist.viewport_start_time == 20,
    string.format("viewport_start should still be 20 after persist, got %d",
        seq_after_persist.viewport_start_time))
assert(seq_after_persist.viewport_duration == 40,
    string.format("viewport_duration should still be 40 after persist, got %d",
        seq_after_persist.viewport_duration))
assert(seq_after_persist.playhead_position == 35,
    string.format("playhead should still be 35 after persist, got %d",
        seq_after_persist.playhead_position))

print("Step 6: timeline_state cache reflects restored values")
assert(timeline_state.get_viewport_start_time() == 20,
    string.format("timeline_state viewport_start should be 20, got %d",
        timeline_state.get_viewport_start_time()))
assert(timeline_state.get_viewport_duration() == 40,
    string.format("timeline_state viewport_duration should be 40, got %d",
        timeline_state.get_viewport_duration()))
assert(timeline_state.get_playhead_position() == 35,
    string.format("timeline_state playhead should be 35, got %d",
        timeline_state.get_playhead_position()))

command_manager.end_command_event()
print("✅ Import view state preserved across undo/redo")
