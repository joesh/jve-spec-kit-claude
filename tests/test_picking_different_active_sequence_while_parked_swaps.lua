#!/usr/bin/env luajit
-- T022 / FR-005b: active-sequence change while record-engine is parked
-- (state='stopped') is a quiet rebind: no audio touch, no error.

require("test_env")
print("=== test_picking_different_active_sequence_while_parked_swaps.lua ===")

local setup = require("helpers.test_017_setup")
local audio_log = {}
setup.install_qt_stub()
local h = setup.fresh_project_db("test_017_t022.db")
local now = os.time()
h.database.get_connection():exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, start_timecode_frame, created_at, modified_at)
        VALUES ('rec2','p','Rec2','sequence',24,1,48000,1920,1080,55,0,300,0,%d,%d);
]], now, now))

local audio_playback = require("core.media.audio_playback")
local orig_halt = audio_playback.halt_current
local orig_acq = audio_playback.acquire_for
audio_playback.halt_current = function(...) audio_log[#audio_log+1]="halt"; return orig_halt(...) end
audio_playback.acquire_for  = function(...) audio_log[#audio_log+1]="acq"; return orig_acq(...) end

local transport = require("core.playback.transport")
transport.init("p")
local rec = transport.engine_for_role("record")
rec:load("rec")
assert(rec.state == "stopped")

local timeline_state = require("ui.timeline.timeline_state")
timeline_state.switch_to_record_tab("rec2")

assert(rec.loaded_sequence_id == "rec2",
    "FR-005b: parked rebind must swap loaded_sequence_id")
assert(rec:get_position() == 55,
    "rec2's saved playhead 55 must be applied")
assert(#audio_log == 0, string.format(
    "FR-005b: parked rebind must NOT touch audio device; saw %d calls: %s",
    #audio_log, table.concat(audio_log, ",")))

print("✅ test_picking_different_active_sequence_while_parked_swaps.lua passed")
