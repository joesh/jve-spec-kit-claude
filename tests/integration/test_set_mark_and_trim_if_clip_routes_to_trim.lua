-- Integration: live-bound source-viewer I/O keys trim the loaded clip,
-- not the timeline. Verified with a real SequenceMonitor + real
-- source_viewer flow under JVEEditor --test. Replaces the headless
-- mock-based test of the same name (deleted alongside this landing).
--
-- Domain rules (019):
--   * source_viewer.load_clip puts the viewer in live_bound_clip mode.
--   * I/O in @source_monitor scope dispatches SetMarkAndTrimIfClip,
--     which in live-bound mode trims the loaded clip's source_in/out
--     via OverwriteTrimEdge or RippleTrimEdge (per edit_mode).
--   * Plain SetMark stays bound to @timeline / @timeline_monitor and
--     mutates the sequence row — no hidden trim branch.
--   * Collapse/inversion presses (IN at-or-past OUT, OUT at-or-past IN)
--     log + no-op; never reach the SQL CHECK (TSO 2026-05-20).

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_set_mark_and_trim_if_clip_routes_to_trim.lua ===")

require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local Clip            = require("models.clip")
local Sequence        = require("models.sequence")

-- ---------------------------------------------------------------------
-- Fresh DB: one record sequence + one master + one clip referencing the
-- master. The clip's source range is [100, 300); we move the viewer-
-- bound playhead to drive the trim asserts.
-- ---------------------------------------------------------------------
local DB = "/tmp/jve/test_set_mark_and_trim_if_clip_integration.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

assert(db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('proj', 'P', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        mark_in_frame, mark_out_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, start_timecode_frame,
        created_at, modified_at)
      VALUES
        ('rec','proj','Rec','sequence',24,1,48000,1920,1080,
         0,1000,0,NULL,NULL,'[]','[]','[]',0,0,0,0),
        ('msa','proj','Source','master',24,1,NULL,1920,1080,
         0,300,0,NULL,NULL,'[]','[]','[]',0,0,0,0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('rv1','rec','V1','VIDEO',1,1);
    INSERT INTO clips (id, project_id, owner_sequence_id, sequence_id,
        track_id, source_in_frame, source_out_frame, sequence_start_frame,
        duration_frames, fps_mismatch_policy, name, enabled, volume,
        playhead_frame, created_at, modified_at)
      VALUES ('c1','proj','rec','msa','rv1', 100, 300, 0, 200,
              'resample','AlphaClip',1,1.0,0,0,0);
]]))

command_manager.init("rec", "proj")

-- Real SequenceMonitors for source + timeline slots. Under --test we
-- have full C++ bindings; no widget mocks. focus_manager is loaded;
-- transport is bootstrapped by command_manager.init's pcall.
ienv.setup_monitor_panels({ kinds = "both" })

local source_viewer = require("ui.source_viewer")
local edit_mode     = require("core.edit_mode")
edit_mode.set_trim_mode("overwrite")

-- ---------------------------------------------------------------------
-- Enter live_bound_clip mode. skip_focus avoids focus_manager wrangling;
-- the trim behavior is independent of focus.
-- ---------------------------------------------------------------------
source_viewer.load_clip("c1", { skip_focus = true })
assert(source_viewer.get_mode() == "live_bound_clip",
    "source_viewer must be in live_bound_clip mode after load_clip")

-- Snapshot the columns that must not be touched by the trim path.
local c1_before = Clip.load("c1")
assert(c1_before.source_in  == 100 and c1_before.source_out == 300,
    "fixture: c1 starts at (100, 300)")
local rec_before = Sequence.load("rec")
local msa_before = Sequence.load("msa")
assert(rec_before.mark_in == nil and msa_before.mark_in == nil,
    "fixture: neither sequence carries a mark yet")

-- ---------------------------------------------------------------------
-- I-key on the live-bound clip moves clip.source_in to the playhead.
-- We pass `frame` directly so the test does not depend on engine
-- playhead bookkeeping; the resolve_frame fallback path is exercised
-- by the engine integration tests.
-- ---------------------------------------------------------------------
local r1 = command_manager.execute_interactive("SetMarkAndTrimIfClip", {
    _positional = { "in" },
    frame       = 150,
})
assert(r1 and r1.success,
    "I-key dispatch must succeed; got " .. tostring(r1 and r1.success))

local c1_after_in = Clip.load("c1")
assert(c1_after_in.source_in  == 150, string.format(
    "live-bound IN moves clip.source_in to playhead (150); got %s",
    tostring(c1_after_in.source_in)))
assert(c1_after_in.source_out == 300,
    "live-bound IN must NOT touch source_out")
print("  PASS live-bound IN trims clip.source_in")

-- Sequence marks must stay nil.
assert(Sequence.load("rec").mark_in == nil and Sequence.load("msa").mark_in == nil,
    "live-bound trim must NOT mutate any sequence mark_in")
print("  PASS sequence marks untouched")

-- ---------------------------------------------------------------------
-- O-key with a different frame trims source_out symmetrically.
-- ---------------------------------------------------------------------
local r2 = command_manager.execute_interactive("SetMarkAndTrimIfClip", {
    _positional = { "out" },
    frame       = 280,
})
assert(r2 and r2.success, "O-key dispatch must succeed")

local c1_after_out = Clip.load("c1")
assert(c1_after_out.source_out == 280, string.format(
    "live-bound OUT moves clip.source_out to playhead (280); got %s",
    tostring(c1_after_out.source_out)))
assert(c1_after_out.source_in  == 150,
    "live-bound OUT must NOT touch source_in")
print("  PASS live-bound OUT trims clip.source_out")

-- ---------------------------------------------------------------------
-- Plain SetMark stays pure — mutates the sequence row, leaves the
-- live-bound clip alone. Proves SetMark has no hidden live-bound branch.
-- ---------------------------------------------------------------------
local r3 = command_manager.execute_interactive("SetMark", {
    _positional = { "in" },
    sequence_id = "rec",
    frame       = 50,
})
assert(r3 and r3.success, "plain SetMark must succeed")

assert(Sequence.load("rec").mark_in == 50,
    "plain SetMark must write the addressed sequence's mark_in")
assert(Clip.load("c1").source_in == 150,
    "plain SetMark must NOT mutate the live-bound clip")
print("  PASS plain SetMark stays pure")

-- ---------------------------------------------------------------------
-- Collapse / inversion rejection (TSO 2026-05-20): IN at-or-past OUT
-- (or OUT at-or-past IN) must log + no-op rather than reach the SQL
-- CHECK(duration_frames > 0). Successful return models a UX no-op.
-- c1 is currently (150, 280).
-- ---------------------------------------------------------------------
local function expect_no_mutation(args, label)
    local before = Clip.load("c1")
    local r = command_manager.execute_interactive("SetMarkAndTrimIfClip", args)
    assert(r and r.success, label .. ": must report success (UX no-op)")
    local after = Clip.load("c1")
    assert(after.source_in  == before.source_in
       and after.source_out == before.source_out
       and after.duration   == before.duration,
        label .. ": must NOT mutate the clip")
end

expect_no_mutation({ _positional = { "in"  }, frame = 280 }, "IN at OUT")
expect_no_mutation({ _positional = { "in"  }, frame = 281 }, "IN past OUT")
expect_no_mutation({ _positional = { "out" }, frame = 150 }, "OUT at IN")
print("  PASS collapse / inversion presses are no-ops")

print("\nPASS test_set_mark_and_trim_if_clip_routes_to_trim.lua")
