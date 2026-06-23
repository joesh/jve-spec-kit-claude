-- Regression (spec 023): SyncGradesFromResolve must produce an undoable
-- history entry. The user expectation is "Cmd-Z after a sync reverts
-- the whole sync." Prior implementation made the outer command undoable
-- and stashed a `captured` snapshot on the command object from inside an
-- async helper-response callback — but the command_manager rehydrates
-- commands from the DB at undo time, so the late `set_parameter` never
-- reached the undoer. Result: pressing Cmd-Z after a sync hit
--   "SyncGradesFromResolve undoer: args.captured required"
-- and undo did nothing.
--
-- The architecturally-correct fix mirrors SyncEditsFromResolve: the outer
-- command is non-undoable; apply() dispatches ONE synchronous undoable
-- SetClipGrades batch command covering every affected clip, which
-- captures all per-clip before-state inside its own synchronous
-- execute(). command_manager persists that capture to command_args
-- before any undo can reach it. One Cmd-Z reverts the whole sync.
--
-- This test drives the data layer directly (apply()) and then exercises
-- command_manager.undo() — that catches the architectural property
-- without needing to fake the bridge helper.

require("test_env")

local database        = require("core.database")
local ClipGrade       = require("models.clip_grade")
local identity_ledger = require("core.resolve_bridge.identity_ledger")
local sync_grades     = require("core.commands.sync_grades_from_resolve")
local command_manager = require("core.command_manager")

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== SyncGradesFromResolve: undo via group reverts state ===")

local db_path = "/tmp/jve/test_sync_grades_undo_via_group.db"
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
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos,
        selected_gap_infos, current_sequence_number,
        created_at, modified_at)
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
    VALUES ('c_pre', 'p', 'pre', 't', 's', 's', 0, 96, 0, 96, NULL, NULL,
        1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
           ('c_none', 'p', 'none', 't', 's', 's', 96, 96, 0, 96, NULL, NULL,
        1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now, now, now))

-- Seed a pre-existing grade on c_pre with non-identity values so a
-- bypass cannot accidentally satisfy the post-undo assertion.
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
local pre_grade_fp = ClipGrade.fingerprint(ClipGrade.load("c_pre", db))

identity_ledger.upsert("c_pre", {
    resolve_item_id   = "live_pre",
    grade_fingerprint = pre_grade_fp,
    edit_fingerprint  = "edit-fp-before",
}, db)
identity_ledger.upsert("c_none", {
    resolve_item_id   = "live_none",
    edit_fingerprint  = "edit-fp-before-none",
}, db)

command_manager.init("s", "p")

-- ── apply: a sync delivers fresh grades for both clips ─────────────
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

sync_grades.apply(response, "s", db, now + 60)

local post_pre = ClipGrade.load("c_pre", db)
local post_none = ClipGrade.load("c_none", db)
check("apply mutated c_pre slope_r",
    post_pre and post_pre.cdl and post_pre.cdl.slope_r == POST_CDL_pre.slope_r)
check("apply created c_none grade",
    post_none and post_none.cdl and post_none.cdl.slope_r == POST_CDL_none.slope_r)

-- ── undo via command_manager: one Cmd-Z reverts the whole group ───
check("can_undo after apply (apply must register an undoable history)",
    command_manager.can_undo())

local undo_result = command_manager.undo()
check(string.format("command_manager.undo() succeeds (err=%s)",
    tostring(undo_result and undo_result.error_message)),
    undo_result and undo_result.success)

local reverted_pre  = ClipGrade.load("c_pre",  db)
local reverted_none = ClipGrade.load("c_none", db)
check("undo reverts c_pre to pre-sync slope_r",
    reverted_pre and reverted_pre.cdl
        and reverted_pre.cdl.slope_r == PRE_CDL.slope_r)
check("undo removes c_none grade (it had none before sync)",
    reverted_none == nil)

local reverted_link = identity_ledger.load("c_pre", db)
check("undo reverts c_pre ledger grade_fingerprint",
    reverted_link and reverted_link.grade_fingerprint == pre_grade_fp)
check("undo preserves c_pre ledger resolve_item_id",
    reverted_link and reverted_link.resolve_item_id == "live_pre")
check("undo preserves c_pre ledger edit_fingerprint",
    reverted_link and reverted_link.edit_fingerprint == "edit-fp-before")

print(string.format("\n%d passed, %d failed", pass, fail))
assert(fail == 0, "test_sync_grades_undo_via_group.lua: failures present")
print("✅ test_sync_grades_undo_via_group.lua passed")
