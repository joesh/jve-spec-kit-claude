-- SyncGradesFromResolve apply + undo (spec 023, FR-013/FR-014/FR-017).
--
-- Black-box: feed the command a synthetic helper response (the shape
-- helper-protocol.md defines for `read_grades`), assert clip_grade
-- entries match, undo via command_manager, assert original state
-- restored — including that a clip that started UNGRADED has no grade
-- again (data-model.md: undo restores prior state).
--
-- The outer SyncGradesFromResolve is non-undoable; M.apply dispatches
-- ONE synchronous SetClipGrades batch command covering every affected
-- clip. command_manager records a single undo entry; one Cmd-Z reverts
-- the whole sync. Tests drive M.apply directly to exercise the batch
-- dispatch, and command_manager.undo() to exercise rollback. FR-022 —
-- no model mocks; tests pass the real wire data structures and let the
-- model layer mutate.

require("test_env")

local database        = require("core.database")
local ClipGrade       = require("models.clip_grade")
local identity_ledger = require("core.resolve_bridge.identity_ledger")
local sync_grades     = require("core.commands.sync_grades_from_resolve")
local command_manager = require("core.command_manager")
local Signals         = require("core.signals")

local pass, fail = 0, 0
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
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('s', 'p', 'S', 'sequence', 24000, 1001, 48000, 1920, 1080,
        0, 240, 0, '[]', '[]', '[]', 0, %d, %d);
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
-- the test cannot pass by accident.
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

-- Ledger seeding: sync-time auto-discovery would have populated these.
-- Post-FR-021, sync_grades joins helper response rows (keyed on
-- resolve_item_id) to clip.id via the ledger — no ledger row ⇒ unmatched.
identity_ledger.upsert("c_pre",  { resolve_item_id = "live_pre"  }, db)
identity_ledger.upsert("c_none", { resolve_item_id = "live_none" }, db)

command_manager.init("s", "p")

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
    warnings = {},
}

-- ─── apply: writes grades for all matched clips in one batch ──────
local summary = sync_grades.apply(response, "s", db, now + 60)

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
check("summary.applied_count = 2",
    summary.applied_count == 2)
check("summary.unmatched_resolve_items empty",
    #summary.unmatched_resolve_items == 0)

-- ─── undo via command_manager: one Cmd-Z reverts the whole group ────
local undo_result = command_manager.undo()
check("command_manager.undo() succeeds", undo_result and undo_result.success)
local restored_pre = ClipGrade.load("c_pre", db)
check("c_pre restored slope_r matches original",
    restored_pre and restored_pre.cdl
        and restored_pre.cdl.slope_r == PRE_CDL.slope_r)
check("c_pre restored source matches original",
    restored_pre and restored_pre.source == "user")
local restored_none = ClipGrade.load("c_none", db)
check("c_none restored has NO grade row (was ungraded before sync)",
    restored_none == nil)

-- ─── FR-013a stale walk ────────────────────────────────────────────
-- Apply again so c_pre is graded by Resolve, then a follow-up apply
-- whose response is empty — c_pre's prior grade survives, marked stale=1.
sync_grades.apply(response, "s", db, now + 90)
local response_missing_pre = { grades = {} }
sync_grades.apply(response_missing_pre, "s", db, now + 120)
local pre_after_absent = ClipGrade.load("c_pre", db)
check("FR-013a: c_pre keeps its grade after Resolve drops it",
    pre_after_absent ~= nil
        and pre_after_absent.cdl
        and pre_after_absent.cdl.slope_r == POST_CDL_pre.slope_r)
check("FR-013a: c_pre marked stale=1",
    pre_after_absent ~= nil and pre_after_absent.stale == 1)
-- Both clips were just graded by the prior apply; the empty response
-- covers neither, so the stale walk marks both as stale=1.
local none_after_absent = ClipGrade.load("c_none", db)
check("FR-013a: c_none marked stale=1 (also covered by the walk)",
    none_after_absent ~= nil and none_after_absent.stale == 1)

-- Undo the stale-mark batch: c_pre returns to stale=0.
local undo_stale = command_manager.undo()
check("undo of stale-walk batch succeeds",
    undo_stale and undo_stale.success)
local pre_after_undo_stale = ClipGrade.load("c_pre", db)
check("FR-013a undo: c_pre stale=0 restored",
    pre_after_undo_stale ~= nil and pre_after_undo_stale.stale == 0)
check("FR-013a undo: c_pre cdl preserved",
    pre_after_undo_stale ~= nil and pre_after_undo_stale.cdl
        and pre_after_undo_stale.cdl.slope_r == POST_CDL_pre.slope_r)
-- Both clips were stale-marked in the same batch — undo MUST restore
-- both. A bug that undoes only the first op would slip through if we
-- only checked c_pre.
local none_after_undo_stale = ClipGrade.load("c_none", db)
check("FR-013a undo: c_none stale=0 restored",
    none_after_undo_stale ~= nil and none_after_undo_stale.stale == 0)
check("FR-013a undo: c_none cdl preserved",
    none_after_undo_stale ~= nil and none_after_undo_stale.cdl
        and none_after_undo_stale.cdl.saturation == POST_CDL_none.saturation)

-- ─── re-apply after undo lands at the post-state ───────────────────
sync_grades.apply(response, "s", db, now + 180)
local reapplied_pre = ClipGrade.load("c_pre", db)
check("re-apply: c_pre slope_r is post-state again",
    reapplied_pre and reapplied_pre.cdl
        and reapplied_pre.cdl.slope_r == POST_CDL_pre.slope_r)

-- ─── grades_changed signal (FR-016): SetClipGrades emits ONCE per
-- batch (apply and undo each), so a parked monitor re-pulls exactly
-- once per sync — not N times. Asserting equality, not >= 1, catches
-- a regression where a future per-clip emit cascade reappears.
local emissions = {}
local conn = Signals.connect("grades_changed", function(seq_id)
    emissions[#emissions + 1] = seq_id
end)
sync_grades.apply(response, "s", db, now + 240)
check("grades_changed fires exactly once per apply batch",
    #emissions == 1)
check("grades_changed payload is the synced sequence_id",
    emissions[1] == "s")
emissions = {}
command_manager.undo()
check("grades_changed fires exactly once per undo batch",
    #emissions == 1)
check("undo emission carries the synced sequence_id",
    emissions[1] == "s")
Signals.disconnect(conn)

-- ─── M.execute via mocked supervisor: end-to-end async dispatch ─────
-- Patch at supervisor.with_client (the actual call site sync_grades
-- uses) rather than supervisor.ensure_client (an internal delegate) —
-- mirrors test_sync_grades_lut_bake_path.lua so an internal refactor
-- of with_client can't silently route the test to the live helper.
local supervisor = require("core.resolve_bridge.helper_supervisor")
local orig_with_client = supervisor.with_client

-- Reset to PRE state before re-running the end-to-end path.
ClipGrade.upsert("c_pre", {
    cdl = PRE_CDL, lut_ref = nil, fidelity = "primary",
    reproduction = "full", source = "user", stale = 0, synced_at = now,
}, db)
db:exec("DELETE FROM clip_grade WHERE clip_id = 'c_none'")

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
supervisor.with_client = function(_notify, _args, fn) fn(fake_client) end

local completed_result, completed_err
local exec_result = command_manager.execute("SyncGradesFromResolve", {
    project_id  = "p",
    sequence_id = "s",
    on_complete = function(result, err)
        completed_result, completed_err = result, err
    end,
})
check("command_manager.execute(SyncGradesFromResolve) ok",
    exec_result and exec_result.success)
check("on_complete fired without error",
    completed_err == nil and completed_result ~= nil)
check("on_complete carries applied_count = 2",
    completed_result and completed_result.applied_count == 2)

local c_pre_after = ClipGrade.load("c_pre", db)
check("c_pre took the POST grade via M.execute → M.apply → SetClipGrades",
    c_pre_after and c_pre_after.cdl
        and c_pre_after.cdl.slope_r == POST_CDL_pre.slope_r)

-- One Cmd-Z reverts the whole sync via the group.
local end_to_end_undo = command_manager.undo()
check("end-to-end command_manager.undo() succeeds",
    end_to_end_undo and end_to_end_undo.success)
local c_pre_undone = ClipGrade.load("c_pre", db)
check("undo reverts c_pre to PRE_CDL after end-to-end sync",
    c_pre_undone and c_pre_undone.cdl
        and c_pre_undone.cdl.slope_r == PRE_CDL.slope_r)
local c_none_undone = ClipGrade.load("c_none", db)
check("undo deletes c_none (was ungraded before end-to-end sync)",
    c_none_undone == nil)

supervisor.with_client = orig_with_client

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_sync_grades_command.lua: failures present")
print("✅ test_sync_grades_command.lua passed")
