-- Regression (spec 023, FR-016 + rule 2.32): a grade sync whose APPLY
-- phase fails on an internal fault MUST terminate through the one
-- completion signal as a loud failure — it must not vanish.
--
-- Domain requirement (NOT traced from code): FR-016 says the on-screen
-- "Syncing…" indicator clears when the sync completes; the no-silent-
-- failure rule says a sync that cannot finish must SURFACE a terminal
-- failure so the UI recovers and the user is told. Therefore: if the
-- apply phase hits a fault (here: a grade row references a baked .cube
-- that is missing from disk — a bake-pipeline inconsistency), the
-- operation must still emit `sync_grades_from_resolve_completed` with a
-- failure code. It must NOT hang with the indicator stuck forever.
--
-- Why this is the right black-box probe: the bridge response is
-- delivered on a C++ socket callback whose error boundary SWALLOWS Lua
-- errors (logs + continues, never re-raises). So an un-caught apply
-- assert would never reach the completion signal and the indicator
-- would stick until app restart. This test asserts the observable
-- contract — completion fires with a failure — without naming the
-- mechanism that delivers it.

require("test_env")

local database = require("core.database")
local ClipGrade = require("models.clip_grade")  -- luacheck: ignore (schema dep parity)
local identity_ledger = require("core.resolve_bridge.identity_ledger")
local supervisor = require("core.resolve_bridge.helper_supervisor")
local sync_grades = require("core.commands.sync_grades_from_resolve")
local Signals = require("core.signals")

local pass = 0
local fail = 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== SyncGradesFromResolve apply-failure terminates ===")

local db_path = "/tmp/jve/test_sync_grades_apply_failure.db"
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
    VALUES ('c1', 'p', 'one', 't', 's', 's', 0, 96, 0, 96, NULL, NULL,
        1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now))

-- Ledger link so the synthetic grade row attributes to the clip and the
-- apply loop reaches the cube read (sync-time discovery would seed this).
identity_ledger.upsert("c1", { resolve_item_id = "live_1" }, db)

-- A baked-cube path that does NOT exist on disk — the bake-pipeline
-- inconsistency that makes the apply phase's identity read assert.
local missing_cube = "/tmp/jve/test_sync_grades_apply_failure_missing.cube"
os.remove(missing_cube)

-- read_grades response: ONE wire-valid grade row carrying a lut whose
-- baked cube is missing. fidelity=unrepresentable carries no cdl (FR-015)
-- and drives the on-disk cube read in the apply phase.
local response = {
    grades = {
        {
            resolve_item_id = "live_1",
            fidelity        = "unrepresentable",
            lut             = { ref = missing_cube },
        },
    },
    warnings = {},
}

-- Fake client: discovery fold (read_identities/read_timeline) serves
-- empty so it neither relinks nor unlinks the seeded ledger row; the
-- integer rate matches the 24000/1001 sequence so the rate guard passes.
local fake_client = {}
function fake_client:request(verb, _, cb)
    if verb == "read_identities" then
        cb({ result = { items = {} } }, nil, nil)
    elseif verb == "read_timeline" then
        cb({ result = { items = {}, timeline_integer_rate = 24 } }, nil, nil)
    else
        assert(verb == "read_grades",
            "fake_client: unexpected verb " .. tostring(verb))
        cb({ result = response }, nil, nil)
    end
end
local orig_ensure_client = supervisor.ensure_client
supervisor.ensure_client = function() return fake_client end

local fake_command = { parameters = { sequence_id = "s" } }
function fake_command:get_all_parameters() return self.parameters end
function fake_command:set_parameter(key, value) self.parameters[key] = value end

-- Observe the one terminal signal the FR-016 indicator listens to.
local completions = {}
local conn_id = Signals.connect("sync_grades_from_resolve_completed",
    function(result, code, message)
        completions[#completions + 1] =
            { result = result, code = code, message = message }
    end)

local ok = pcall(function()
    sync_grades.execute({ sequence_id = "s" }, db, fake_command)
end)

Signals.disconnect(conn_id)
supervisor.ensure_client = orig_ensure_client

-- The apply fault must NOT escape execute() as an unhandled error: it is
-- routed through the terminal path instead (pre-fix it propagated /
-- was swallowed and the signal never fired).
check("execute did not raise — apply fault routed, not escaped", ok)
check("completion signal fired exactly once", #completions == 1)
check("completion is a FAILURE (result == nil)",
    completions[1] ~= nil and completions[1].result == nil)
check("failure code is non-empty (UI can surface + clear indicator)",
    completions[1] ~= nil and type(completions[1].code) == "string"
        and completions[1].code ~= "")
check("failure code names a JVE-internal apply fault, not a resolve API error",
    completions[1] ~= nil and completions[1].code == "apply_failed")

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0,
    "test_sync_grades_apply_failure_terminates.lua: failures present")
print("✅ test_sync_grades_apply_failure_terminates.lua passed")
