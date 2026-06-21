-- Integration test: moving the playhead in the record viewer updates the
-- ONE shared playhead, so every view/store of the active sequence's playhead
-- agrees on the new value.
--
-- DOMAIN RULE (the bug this pins):
--   The record monitor and the timeline are two VIEWS of the same playhead —
--   the active sequence's playhead, which lives in exactly one place (the
--   sequence model). When the user scrubs the record viewer's mark bar, the
--   new position must be written to that single source of truth, and every
--   other view (the timeline) must reflect it immediately. The timeline must
--   NOT keep showing the position the playhead used to be at.
--
--   Symptom of the violation (reported 2026-06-20): move the playhead in the
--   record viewer, then press Opt+X (ClearMarks). The playhead jumps back to
--   where it was — because the timeline still cached the OLD position and a
--   later command re-asserted it. Root cause: the record viewer's scrub wrote
--   a private field instead of the model, so the timeline never heard about
--   the move and held a stale value.
--
-- This is black-box: it asserts the user-observable invariant (the playhead
-- the user set IS the playhead, everywhere), not how the monitor writes it.

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_rec_viewer_move_updates_shared_playhead.lua (integration) ===")

local test_env     = require("test_env")
local database     = require("core.database")
local Sequence     = require("models.sequence")
local command_manager = require("core.command_manager")
local timeline_state  = require("ui.timeline.timeline_state")

-- ── DB bootstrap ────────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_rec_viewer_shared_playhead.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

assert(db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('p1', 'TestProject', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
              0, 0);
]]))

local media_path = ienv.test_media_path("A005_C052_0925BL_001.mp4")
assert(db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels,
        audio_sample_rate, codec, created_at, modified_at, metadata)
    VALUES ('m1', 'p1', 'TestClip', '%s', 100, 24, 1,
            1920, 1080, 2, 48000, 'h264', 0, 0,
            '{"start_tc_value":0,"start_tc_rate":24,"start_tc_audio_samples":0,"start_tc_audio_rate":48000}')
]], media_path)))

local master_id = test_env.create_test_masterclip_sequence("p1", "TestClip", 24, 1, 100, "m1")
assert(master_id and master_id ~= "", "fixture: master_id required")

-- Active timeline sequence (kind='sequence') — what the record viewer shows.
assert(db:exec([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, created_at, modified_at)
    VALUES ('tl1', 'p1', 'MyTimeline', 'sequence', 24, 1, 48000, 1920, 1080,
            0, 2000, 0, 0, 0)
]]))
assert(db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('tv1', 'tl1', 'V1', 'VIDEO', 1, 1)
]]))
assert(db:exec(string.format([[
    INSERT INTO clips (id, project_id, owner_sequence_id, sequence_id, track_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        fps_mismatch_policy, name, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('clip1', 'p1', 'tl1', '%s', 'tv1', 0, 50, 0, 50, 'resample',
            'Clip1', 1, 1.0, 0, 0, 0)
]], master_id)))

-- ── Transport + monitor (mirrors production startup) ─────────────────────────
command_manager.init("tl1", "p1")
local transport = require("core.playback.transport")
if transport.bound_project_id() ~= "p1" then
    if transport.bound_project_id() then transport.shutdown() end
    transport.init("p1")
end
package.loaded["ui.sequence_monitor"] = nil

-- Stand up the timeline-side view of tl1 so we can read what "the timeline
-- knows". The stub is the displayed record tab for tl1; strip.tabs lets the
-- playhead_changed listener (which mirrors the model into each tab's cache)
-- find it.
local cache = test_env.install_displayed_tab_stub({
    sequence_id = "tl1",
    kind = "record",
    playhead_position = 0,
    sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 },
})
local strip = require("ui.timeline.state.strip_holder").get()
strip.tabs = { strip.get_displayed() }

local SequenceMonitor = require("ui.sequence_monitor")
local mon = SequenceMonitor.new({ view_id = "timeline_monitor" })
require("ui.panel_manager").register_sequence_monitor("timeline_monitor", mon)
mon:load_sequence("tl1")

-- Known starting state: playhead parked at frame 0 everywhere.
do
    local seq = Sequence.load("tl1")
    seq.playhead_position = 0
    seq:save()
    cache.playhead_position = 0
    assert(timeline_state.get_playhead_position() == 0,
        "fixture: timeline must start parked at frame 0")
end

-- ════════════════════════════════════════════════════════════════════════════
-- ACT: user scrubs the record viewer's mark bar to frame 120.
-- The mark bar's on_seek callback funnels straight into seek_to_frame.
-- ════════════════════════════════════════════════════════════════════════════
local MOVED = 120
mon:seek_to_frame(MOVED)

assert(mon.playhead == MOVED, string.format(
    "monitor playhead must reflect the move: expected %d, got %s",
    MOVED, tostring(mon.playhead)))

-- ── ASSERT 1: the single source of truth (the model) holds the new value ─────
local model_ph = Sequence.load("tl1").playhead_position
assert(model_ph == MOVED, string.format(
    "moving the playhead in the record viewer must write the active sequence's "
    .. "playhead to the model; expected %d, model has %s",
    MOVED, tostring(model_ph)))

-- ── ASSERT 2: the timeline knows the NEW position, not the old one ───────────
local timeline_ph = timeline_state.get_playhead_position()
assert(timeline_ph == MOVED, string.format(
    "the timeline must reflect the record viewer's playhead move; it must NOT "
    .. "still know the old position. Expected %d, timeline has %s",
    MOVED, tostring(timeline_ph)))

-- ════════════════════════════════════════════════════════════════════════════
-- End-to-end guard: clearing marks must NOT move the playhead. With the
-- timeline holding the CURRENT position (Assert 2), nothing can snap it back.
-- ════════════════════════════════════════════════════════════════════════════
do
    -- Set a mark so ClearMarks has something to clear (exercises the real path).
    local seq = Sequence.load("tl1")
    seq.mark_in = 30
    seq:save()
    require("core.signals").emit("marks_changed", "tl1")

    command_manager.execute("ClearMarks", { project_id = "p1", sequence_id = "tl1" })

    assert(mon.playhead == MOVED, string.format(
        "ClearMarks must leave the playhead where the user put it; "
        .. "expected %d, got %s (snap-back regression)",
        MOVED, tostring(mon.playhead)))
    assert(Sequence.load("tl1").playhead_position == MOVED, string.format(
        "ClearMarks must not move the model playhead; expected %d, got %s",
        MOVED, tostring(Sequence.load("tl1").playhead_position)))
end

mon:destroy()
print("\nPASS test_rec_viewer_move_updates_shared_playhead.lua (integration)")
os.exit(0)
