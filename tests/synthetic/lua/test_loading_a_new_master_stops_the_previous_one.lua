#!/usr/bin/env luajit
-- T017 / FR-004: source-engine:load(masterB) while masterA is parked
-- (a) writes A's playhead to its DB row;
-- (b) releases audio device;
-- (c) binds to B at B's saved playhead;
-- (d) loaded_sequence_id reflects B.

require("test_env")
print("=== test_loading_a_new_master_stops_the_previous_one.lua ===")

local setup = require("synthetic.helpers.test_017_setup")
setup.install_qt_stub()
local h = setup.fresh_project_db("test_017_t017.db")
local db = h.database.get_connection()
local now = os.time()
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, start_timecode_frame, created_at, modified_at)
        VALUES ('mB','p','MasterB','master',24,1,NULL,1920,1080,75,0,300,0,%d,%d);
]], now, now))

local transport = require("core.playback.transport")
local audio_playback = require("core.media.audio_playback")
transport.init("p")

local src = transport.engine_for_role("source")
src:load("src")
src:seek(100)
-- Simulate src owning audio.
audio_playback.acquire_for(src)
assert(audio_playback.is_owner(src))

-- Load masterB. Engine is parked (state=='stopped'), so this is allowed.
src:load("mB")

-- (a) A's playhead persisted
local Sequence = require("models.sequence")
local seqA = Sequence.load("src")
assert(seqA.playhead_position == 100, string.format(
    "FR-007: previous sequence's playhead must be persisted; expected 100, got %s",
    tostring(seqA.playhead_position)))

-- (b) audio released between rebind
assert(audio_playback.current_owner() == nil, string.format(
    "audio must be released across rebind; current_owner=%s",
    tostring(audio_playback.current_owner())))

-- (c) parked at B's saved playhead 75
assert(src:get_position() == 75, string.format(
    "engine must park at B's saved playhead 75, got %s", tostring(src:get_position())))

-- (d) loaded_sequence_id reflects B
assert(src.loaded_sequence_id == "mB",
    "loaded_sequence_id must be 'mB' after rebinding")

print("✅ test_loading_a_new_master_stops_the_previous_one.lua passed")
