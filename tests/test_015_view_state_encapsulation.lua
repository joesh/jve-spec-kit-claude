#!/usr/bin/env luajit

-- 015 — FR-005 view-state encapsulation regression test.
--
-- Domain rule: with the source tab displayed, view-state writes
-- (playhead, viewport, scroll, selection) belong to the SOURCE master,
-- not the active record sequence. Switching to source, scrubbing source
-- view-state, then switching back to record must leave the record
-- sequence's persisted view-state UNCHANGED — view-state is per-tab,
-- not per-edit-target.
--
-- Bug this guards: an earlier implementation conflated displayed_tab_id
-- with sequence_id (the active edit target). When the source tab was
-- open, view-state writes corrupted the active record's DB row.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local Sequence        = require("models.sequence")
local timeline_state  = require("ui.timeline.timeline_state")
local viewport_state  = require("ui.timeline.state.viewport_state")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_015_view_state_encapsulation.lua ===")

local DB = "/tmp/jve/test_015_view_state_encapsulation.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")

database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
-- Record sequence with a known persisted playhead at frame 4242.
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES
      ('rec', 'proj', 'Record', 'nested', 24, 1, 48000, 1920, 1080,
       4242, 0, 1000, %d, %d),
      ('src', 'proj', 'SourceMaster', 'master', 24, 1, NULL, 1920, 1080,
       0, 0, 1000, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES
      ('rec_v1', 'rec', 'V1', 'VIDEO', 1, 1),
      ('rec_a1', 'rec', 'A1', 'AUDIO', 1, 1),
      ('src_v1', 'src', 'V1', 'VIDEO', 1, 1);
]], now, now, now, now, now, now))

command_manager.init("rec", "proj")
timeline_state.init("rec", "proj")

-- Sanity: record's playhead loaded.
assert(timeline_state.get_playhead_position() == 4242,
    string.format("setup: expected record playhead 4242, got %s",
        tostring(timeline_state.get_playhead_position())))

-- Switch to source tab. activate_displayed flushes outgoing record view-state
-- to record's row, then loads source's view-state.
print("-- (a) switch to source, scrub source playhead --")
timeline_state.activate_displayed("src")
assert(timeline_state.get_displayed_tab_id() == "src",
    "displayed_tab_id must be 'src' after activate_displayed('src')")
assert(timeline_state.get_active_sequence_id() == "rec",
    "active_sequence_id must remain 'rec' after switching display only (FR-005)")

-- Scrub source playhead to a value that's clearly distinguishable from
-- record's 4242. Trigger a viewport change that flushes via the persist path.
viewport_state.set_viewport_start_time(99,
    require("ui.timeline.state.timeline_core_state").persist_state_to_db)

-- (b) Switch back to record. Outgoing source view-state flushes to source's
-- row. Record's row must read back the SAME playhead it had pre-source.
print("-- (b) switch back to record, verify record row unchanged --")
timeline_state.activate_displayed("rec")

local rec_after = Sequence.load("rec")
assert(rec_after, "FAIL: record sequence missing after round-trip")
assert(rec_after.playhead_position == 4242, string.format(
    "FAIL: record playhead corrupted by source-tab view-state writes — " ..
    "expected 4242, got %s. View-state encapsulation broken (FR-005).",
    tostring(rec_after.playhead_position)))
print("  record playhead unchanged at 4242 — OK")

-- (c) Source row received the source-side viewport write, not record's.
print("-- (c) verify source row received the write --")
local src_after = Sequence.load("src")
assert(src_after, "FAIL: source sequence missing after round-trip")
assert(src_after.viewport_start_time == 99, string.format(
    "FAIL: source viewport_start_time expected 99, got %s — " ..
    "source-tab writes did not land in source's DB row (FR-005).",
    tostring(src_after.viewport_start_time)))
print("  source viewport_start_time landed in source row — OK")

print("\n✅ test_015_view_state_encapsulation.lua passed")
