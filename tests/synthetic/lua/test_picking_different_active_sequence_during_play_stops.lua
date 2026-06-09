#!/usr/bin/env luajit
-- T021 / FR-005a: changing active_sequence_id during record-engine play
-- stops the engine, persists playhead, then rebinds to the new sequence.

require("test_env")
print("=== test_picking_different_active_sequence_during_play_stops.lua ===")

local setup = require("synthetic.helpers.test_017_setup")
setup.install_qt_stub()
local h = setup.fresh_project_db("test_017_t021.db")
local now = os.time()
h.database.get_connection():exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, start_timecode_frame, created_at, modified_at)
        VALUES ('rec2','p','Rec2','sequence',24,1,48000,1920,1080,33,0,300,0,%d,%d);
]], now, now))

local transport = require("core.playback.transport")
transport.init("p")
local rec = transport.engine_for_role("record")
rec:load("rec")
rec:seek(80)
rec.state = "playing"  -- simulate playing

-- Active sequence changes — record engine must stop, persist, rebind.
local timeline_state = require("ui.timeline.timeline_state")
assert(type(timeline_state.set_active_sequence_id) == "function"
    or type(timeline_state.switch_to_record_tab) == "function",
    "timeline_state must expose a way to change active_sequence_id")

-- Drive via switch_to_record_tab — production path for active seq change.
timeline_state.switch_to_record_tab("rec2")

assert(rec.state == "stopped", string.format(
    "FR-005a: record-engine must stop on active-sequence change during play; state=%s",
    tostring(rec.state)))

local Sequence = require("models.sequence")
assert(Sequence.load("rec").playhead_position == 80, string.format(
    "active-seq-change during play must persist outgoing seq's playhead; got %s",
    tostring(Sequence.load("rec").playhead_position)))
assert(rec.loaded_sequence_id == "rec2",
    "record-engine must be rebound to the new active sequence")
assert(rec:get_position() == 33, string.format(
    "record-engine must park at rec2's saved playhead 33; got %s",
    tostring(rec:get_position())))

print("✅ test_picking_different_active_sequence_during_play_stops.lua passed")
