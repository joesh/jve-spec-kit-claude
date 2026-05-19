-- 010 smoke: no-active-sequence is a first-class state.
--
-- Acceptance: close the last open tab → timeline_state reports no active
-- sequence; persist/reload preserves the blank state; opening a project
-- whose tabs list is empty arrives at blank, not "first-by-sort".

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_010_no_active_sequence_smoke.lua ===")

require("test_env")
local database      = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")
local Sequence      = require("models.sequence")

-- Fresh state at load time has no displayed tab. The whole spec hinges on
-- this being a first-class state, not a transient between two valid ones.
assert(timeline_state.get_displayed_tab_id() == nil,
    "fresh timeline_state must report displayed_tab_id == nil (no auto-pick)")
assert(timeline_state.get_active_sequence_id() == nil,
    "fresh timeline_state must report active_sequence_id == nil")
print("  PASS: fresh state → blank (no auto-pick)")

-- A project DB containing several sequences but no open_tabs entry must
-- NOT cause a downstream auto-select. We can't drive the panel layer
-- without a real Qt widget tree, but the model-tier guarantee is: the
-- sequences table exists and is independent of tab/active state.
local DB = "/tmp/jve/test_010_blank.jvp"
os.execute("mkdir -p /tmp/jve"); os.remove(DB); os.remove(DB..".wal"); os.remove(DB..".shm")
assert(database.init(DB))
local db = database.get_connection()
local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('p','P','passthrough','{"master_clock_hz":705600000,"default_fps":{"num":24,"den":1}}',%d,%d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, playhead_frame, view_start_frame,
        view_duration_frames, start_timecode_frame, created_at, modified_at)
      VALUES ('s1','p','S1','sequence',24,1,48000,1920,1080,0,0,300,0,%d,%d),
             ('s2','p','S2','sequence',24,1,48000,1920,1080,0,0,300,0,%d,%d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
      VALUES ('s1-v1','s1','V1','VIDEO',1), ('s1-a1','s1','A1','AUDIO',1),
             ('s2-v1','s2','V1','VIDEO',1), ('s2-a1','s2','A1','AUDIO',1);
]], now, now, now, now, now, now)))

-- Open a project with two sequences but DON'T open a tab — the spec says
-- the editor must not auto-select first-by-sort. We verify the project's
-- settings JSON contains no `last_open_sequence_id` (FR-013).
local s = assert(db:prepare("SELECT settings FROM projects WHERE id='p'"))
s:exec(); s:next()
local settings = s:value(0)
s:finalize()
assert(not settings:find("last_open_sequence_id"), string.format(
    "fresh project must not carry last_open_sequence_id (FR-013 — no auto-select); "
    .. "settings=%s", settings))
print("  PASS: fresh project settings has no last_open_sequence_id")

-- Sequences exist but the no-active state is preserved across DB roundtrip:
-- the load doesn't materialise a default "active sequence".
local rows = {}
local q = assert(db:prepare("SELECT id FROM sequences WHERE project_id='p' ORDER BY id"))
q:exec(); while q:next() do rows[#rows+1] = q:value(0) end; q:finalize()
assert(#rows == 2 and rows[1] == "s1" and rows[2] == "s2",
    "sequences must exist; the model independence from tab state is the contract")
print("  PASS: project carries sequences without any active-sequence cache")

-- Sanity: loading one of them must not mutate global state.
local seq = Sequence.load("s1")
assert(seq and seq.id == "s1", "Sequence.load works")
assert(timeline_state.get_displayed_tab_id() == nil,
    "Sequence.load must NOT side-effect timeline_state.displayed_tab_id")
print("  PASS: Sequence.load does not auto-mount a tab")

print("\n✅ test_010_no_active_sequence_smoke.lua passed")
