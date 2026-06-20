-- T030 — SyncGradesFromResolve apply + undo (spec 023, FR-017).
--
-- Black-box: feed the command a synthetic helper response (the shape
-- helper-protocol.md defines for `read_grades`), assert clip_grade rows
-- match. Then restore the captured before-state and assert it reverts —
-- including that a clip that started UNGRADED has no grade row again
-- (data-model.md: undo restores prior state).
--
-- The test exercises apply()/restore() as pure-data functions; the full
-- command:execute() path is exercised by integration once T029 (helper
-- read_grades verb) is implemented. Same architectural rule as other
-- non-mocked tests: NO mocks — apply()/restore() take a literal grades
-- list (the shape the helper would deliver) and a db handle; the test
-- constructs the list directly.

require("test_env")

local database = require("core.database")
local ClipGrade = require("models.clip_grade")
local identity_ledger = require("core.resolve_bridge.identity_ledger")
local sync_grades = require("core.commands.sync_grades_from_resolve")
local Signals = require("core.signals")

local pass = 0
local fail = 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== SyncGradesFromResolve Tests ===")

local db_path = "/tmp/jve/test_sync_grades_command.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings,
                          created_at, modified_at)
    VALUES ('p', 'P', 'resample',
        '{"master_clock_hz":705600000,"default_fps":{"num":24,"den":1}}',
        %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame,
        view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('s', 'p', 'S', 'sequence', 24000, 1001, 48000, 1920, 1080,
        0, 240, 0, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('t', 's', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id,
        sequence_id, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, source_in_subframe,
        source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        volume, playhead_frame)
    VALUES ('c_pre',  'p', 'pre',  't', 's', 's', 0,   96, 0, 96, NULL, NULL,
        1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
           ('c_none', 'p', 'none', 't', 's', 's', 96, 96, 0, 96, NULL, NULL,
        1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now, now, now))

-- c_pre has a starting grade; c_none does not. Non-identity values so
-- the test cannot pass by accident (rule test_quality / 2.32).
local PRE_CDL = {
    slope_r = 1.05, slope_g = 0.98, slope_b = 0.92,
    offset_r = 0.01, offset_g = 0.0, offset_b = -0.02,
    power_r  = 1.1,  power_g  = 1.0, power_b  = 0.95,
    saturation = 0.85,
}
ClipGrade.upsert("c_pre", {
    cdl = PRE_CDL, lut_ref = nil, fidelity = "primary",
    reproduction = "full", source = "user", stale = 0, synced_at = now,
}, db)

-- Ledger seeding: sync-time auto-discovery would have populated these
-- rows. Post-FR-021 architectural fix, sync_grades joins helper
-- response rows (keyed on resolve_item_id) to clip.id via the ledger
-- — no ledger row ⇒ unmatched. The runtime resolve_item_id is NOT
-- equal to clip.id even when clip.id is the adopted DRP DbId
-- (spec.md T047 spike, 0/1003 match).
identity_ledger.upsert("c_pre",  { resolve_item_id = "live_pre"  }, db)
identity_ledger.upsert("c_none", { resolve_item_id = "live_none" }, db)

-- ─── apply: a sync delivers fresh grades for both clips ─────────────
local POST_CDL_pre = {
    slope_r = 1.20, slope_g = 1.15, slope_b = 1.10,
    offset_r = -0.01, offset_g = -0.02, offset_b = -0.03,
    power_r  = 0.95,  power_g  = 1.05, power_b  = 1.00,
    saturation = 0.70,
}
local POST_CDL_none = {
    slope_r = 0.90, slope_g = 1.00, slope_b = 1.10,
    offset_r = 0.05, offset_g = 0.04, offset_b = 0.03,
    power_r  = 1.20,  power_g  = 1.10, power_b  = 1.00,
    saturation = 1.10,
}
local to_wire = require("synthetic.helpers.grade_wire").cdl_model_to_wire
local response = {
    grades = {
        { resolve_item_id = "live_pre",  cdl = to_wire(POST_CDL_pre),
          fidelity = "primary", lut = nil },
        { resolve_item_id = "live_none", cdl = to_wire(POST_CDL_none),
          fidelity = "primary", lut = nil },
    },
    -- always present per helper-protocol.md §read_grades (possibly
    -- empty); the execute handler asserts it as a version-skew tripwire
    warnings = {},
}
local captured = sync_grades.apply(response, "s", db, now + 60)

local applied_pre = ClipGrade.load("c_pre", db)
check("c_pre post-apply slope_r is new value",
    applied_pre and applied_pre.cdl
        and applied_pre.cdl.slope_r == POST_CDL_pre.slope_r)
check("c_pre source recorded as 'resolve'",
    applied_pre and applied_pre.source == "resolve")
local applied_none = ClipGrade.load("c_none", db)
check("c_none post-apply has a grade row now",
    applied_none ~= nil)
check("c_none post-apply saturation is new value",
    applied_none and applied_none.cdl
        and applied_none.cdl.saturation == POST_CDL_none.saturation)

-- ─── restore: undo reverts to captured state ───────────────────────
sync_grades.restore(captured, db)
local restored_pre = ClipGrade.load("c_pre", db)
check("c_pre restored slope_r matches original",
    restored_pre and restored_pre.cdl
        and restored_pre.cdl.slope_r == PRE_CDL.slope_r)
check("c_pre restored source matches original",
    restored_pre and restored_pre.source == "user")
local restored_none = ClipGrade.load("c_none", db)
check("c_none restored has NO grade row (was ungraded before sync)",
    restored_none == nil)

-- ─── FR-013a: a clip in the sequence whose Resolve item is absent
-- from the response keeps its grade but is marked stale ─────────────
-- Restore first so we're back to {c_pre graded, c_none ungraded}.
sync_grades.restore(captured, db)

-- FR-013a only applies to ledger-linked clips (the prior-link
-- contract). Both c_pre and c_none were seeded into identity_ledger
-- at the top of this test (mapping to live_pre / live_none).

-- Resolve also lost c_pre between syncs (absent from response.grades).
-- c_pre had a grade; FR-013a requires it survives, marked stale=1.
-- c_none had no grade and Resolve still has nothing — no stale row.
local response_missing_pre = { grades = {} }
local stale_captured = sync_grades.apply(response_missing_pre, "s",
    db, now + 90)
local pre_after_absent = ClipGrade.load("c_pre", db)
check("FR-013a: c_pre keeps its grade after Resolve drops it",
    pre_after_absent ~= nil
        and pre_after_absent.cdl
        and pre_after_absent.cdl.slope_r == PRE_CDL.slope_r)
check("FR-013a: c_pre marked stale=1",
    pre_after_absent ~= nil and pre_after_absent.stale == 1)
local none_after_absent = ClipGrade.load("c_none", db)
check("FR-013a: c_none with no prior grade stays ungraded (no row)",
    none_after_absent == nil)

-- Undo the stale-mark: c_pre back to stale=0.
sync_grades.restore(stale_captured, db)
local pre_after_undo_stale = ClipGrade.load("c_pre", db)
check("FR-013a undo: c_pre stale=0 restored",
    pre_after_undo_stale ~= nil and pre_after_undo_stale.stale == 0)

-- ─── re-apply after restore yields the same captured state ─────────
-- Idempotency check: apply→restore→apply should land at the post-state.
local captured2 = sync_grades.apply(response, "s", db, now + 120)
local reapplied_pre = ClipGrade.load("c_pre", db)
check("re-apply: c_pre slope_r is post-state again",
    reapplied_pre and reapplied_pre.cdl
        and reapplied_pre.cdl.slope_r == POST_CDL_pre.slope_r)
check("re-apply captured the post-restore state",
    captured2 ~= nil and #captured2.entries == 2)

-- ─── grades_changed signal (FR-016): apply()/restore() MUST notify
-- the View layer so a parked monitor re-pulls. Regression — without
-- this, the per-clip cache in sequence_monitor kept showing the
-- pre-sync grade until the next scrub/play. ──────────────────────────
local emissions = {}
local conn = Signals.connect("grades_changed", function(seq_id)
    emissions[#emissions + 1] = seq_id
end)

local sig_captured = sync_grades.apply(response, "s", db, now + 180)
check("grades_changed fires on apply()", #emissions == 1)
check("grades_changed payload is the synced sequence_id",
    emissions[1] == "s")

sync_grades.restore(sig_captured, db)
check("grades_changed fires on restore()", #emissions == 2)
check("grades_changed restore payload is the synced sequence_id",
    emissions[2] == "s")

Signals.disconnect(conn)

-- ─── M.execute persists captured back onto the live Command ─────────
-- Regression: prior code returned captured only via notify() result; the
-- async read_grades handler never wrote it onto the command, so the
-- undoer's `args.captured` was always nil and undo asserted. The fix
-- threads the command handle through register_executor and the async
-- tail calls command:set_parameter("captured", captured) before notify.
-- This test would have failed pre-fix because the supervisor wasn't
-- invoked at all — we inject one to make the test hermetic.
local supervisor = require("core.resolve_bridge.helper_supervisor")
local orig_ensure_client = supervisor.ensure_client

-- Reset c_pre + ensure c_none ungraded (prior section left both graded).
ClipGrade.upsert("c_pre", {
    cdl = PRE_CDL, lut_ref = nil, fidelity = "primary",
    reproduction = "full", source = "user", stale = 0, synced_at = now,
}, db)
db:exec("DELETE FROM clip_grade WHERE clip_id = 'c_none'")

-- Fake client whose request() invokes cb synchronously with the response
-- a real helper would deliver. Matches `helper-protocol.md §read_grades`.
-- The sync's built-in auto-discovery (connect fold) pulls
-- read_identities + read_timeline first; serve both empty (no markers,
-- no live items) so discovery finds nothing to (re)link or stamp and
-- the test keeps exercising ONLY the captured-persistence regression.
-- timeline_integer_rate matches the 24000/1001 sequence (integer TC
-- counter 24) so the rate guard passes. (Tracked mock debt —
-- todo_remove_mocks_from_tests; do not grow this fake's behavior.)
local fake_client = {}
function fake_client:request(verb, _, cb)
    if verb == "read_identities" then
        cb({ result = { items = {} } }, nil, nil)
    elseif verb == "read_timeline" then
        cb({ result = { items = {}, timeline_integer_rate = 24 } },
            nil, nil)
    else
        assert(verb == "read_grades",
            "fake_client: unexpected verb " .. tostring(verb))
        cb({ result = response }, nil, nil)
    end
end
supervisor.ensure_client = function() return fake_client end

-- Minimal Command stand-in matching command_manager's get/set API.
local fake_command = { parameters = { sequence_id = "s" } }
function fake_command:get_all_parameters() return self.parameters end
function fake_command:set_parameter(key, value)
    self.parameters[key] = value
end

local sync_grades_module = require("core.commands.sync_grades_from_resolve")
sync_grades_module.execute({ sequence_id = "s" }, db, fake_command)

check("M.execute persists captured onto command.parameters",
    type(fake_command.parameters.captured) == "table")
check("captured.entries non-empty (apply() ran via async tail)",
    fake_command.parameters.captured
        and #fake_command.parameters.captured.entries >= 2)
check("captured.sequence_id stashed for restore()'s grades_changed emit",
    fake_command.parameters.captured
        and fake_command.parameters.captured.sequence_id == "s")

-- Sanity: apply() actually mutated the model via the async tail.
local c_pre_after = ClipGrade.load("c_pre", db)
check("c_pre took the POST grade after M.execute via fake client",
    c_pre_after and c_pre_after.cdl
        and c_pre_after.cdl.slope_r == POST_CDL_pre.slope_r)

-- Now exercise the undoer path: it reads command:get_all_parameters()
-- and calls M.restore(args.captured, db). Pre-fix this asserted because
-- captured was never written back.
sync_grades_module.restore(fake_command.parameters.captured, db)
local c_pre_undone = ClipGrade.load("c_pre", db)
check("undo restored c_pre to PRE_CDL (captured was persisted+honored)",
    c_pre_undone and c_pre_undone.cdl
        and c_pre_undone.cdl.slope_r == PRE_CDL.slope_r)

supervisor.ensure_client = orig_ensure_client

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_sync_grades_command.lua: failures present")
print("✅ test_sync_grades_command.lua passed")
