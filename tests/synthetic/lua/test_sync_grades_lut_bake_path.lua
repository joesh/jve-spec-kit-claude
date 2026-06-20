-- spec 023 — verify SyncGradesFromResolve passes bake_lut_dir to the
-- helper (per-project JVE-side cache: ~/.jve/resolve_bake/<project_id>/)
-- and that apply stores any returned lut.ref onto clip_grade.lut_ref.
--
-- Wire/model boundary for LUT field: helper emits row with `lut.ref`
-- (absolute path on disk). apply() maps it to clip_grade.lut_ref.
-- Renderer LUT stage (Piece 3, separate commit) consumes that path.

require("test_env")

local database          = require("core.database")
local ClipGrade         = require("models.clip_grade")
local identity_ledger   = require("core.resolve_bridge.identity_ledger")
local sync_grades       = require("core.commands.sync_grades_from_resolve")
local supervisor        = require("core.resolve_bridge.helper_supervisor")

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

-- apply() classifies each baked LUT (FR-015 reproduction axis), so the
-- referenced cubes must be REAL files on disk. Write a 2^3 cube: `graded`
-- false → identity (passthrough = a spatial grade that didn't bake);
-- graded true → a real transform.
local function write_cube(path, graded)
    local f = assert(io.open(path, "w"))
    f:write("LUT_3D_SIZE 2\n")
    for b = 0, 1 do for g = 0, 1 do for r = 0, 1 do
        if graded then
            f:write("0 0 0\n")                       -- crush everything to black
        else
            f:write(string.format("%d %d %d\n", r, g, b))  -- identity
        end
    end end end
    f:close()
end

print("\n=== SyncGradesFromResolve LUT-bake path Tests ===")

local db_path = "/tmp/jve/test_sync_grades_lut_bake_path.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings,
                          created_at, modified_at)
    VALUES ('proj_alpha', 'Alpha', 'resample',
        '{"master_clock_hz":705600000,"default_fps":{"num":24,"den":1}}',
        %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos,
        created_at, modified_at)
    VALUES ('seq_one', 'proj_alpha', 'S', 'sequence', 24000, 1001, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('t', 'seq_one', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id,
        sequence_id, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, source_in_subframe,
        source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        volume, playhead_frame)
    VALUES ('clip_partial', 'proj_alpha', 'P', 't', 'seq_one', 'seq_one',
        0, 96, 0, 96, NULL, NULL, 1, %d, %d, NULL, NULL,
        'resample', 1.0, 0);
]], now, now, now, now, now, now))

identity_ledger.upsert("clip_partial",
    { resolve_item_id = "live_partial" }, db)

-- ─── apply: response row with lut.ref → clip_grade.lut_ref written ──
-- The cube carries a REAL transform → reproduction 'approximate' (JVE
-- shows part of the grade via the bake).
local lut_path = "/tmp/jve/test_sync_grades_lut_bake_path_graded.cube"
write_cube(lut_path, true)
local response = {
    grades = {
        {
            resolve_item_id = "live_partial",
            fidelity        = "partial",
            lut             = { ref = lut_path },
        },
    },
}
local captured = sync_grades.apply(response, "seq_one", db, now + 60)
local g = ClipGrade.load("clip_partial", db)
check("partial row written", g ~= nil and g.fidelity == "partial")
check("lut_ref stored verbatim from row.lut.ref",
    g and g.lut_ref == lut_path)
check("real-transform LUT → reproduction 'approximate'",
    g and g.reproduction == "approximate")
check("carrier present -> no_carrier_count is 0",
    captured.no_carrier_count == 0)
sync_grades.restore(captured, db)

-- ─── apply: partial/unrepresentable WITHOUT lut.ref = clip with no
-- displayable carrier (renders ungraded; view_grade_pull returns nil).
-- The 2026-06-10 incident silently produced 623 of these when the
-- user switched Resolve off the Color page mid-bake. apply() must
-- count them (captured.no_carrier_count) so the sync can warn. ──────
db:exec(([[
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id,
        sequence_id, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, source_in_subframe,
        source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        volume, playhead_frame)
    VALUES ('clip_partial2', 'proj_alpha', 'P2', 't', 'seq_one', 'seq_one',
        96, 96, 0, 96, NULL, NULL, 1, %d, %d, NULL, NULL,
        'resample', 1.0, 0);
]]):format(now, now))
identity_ledger.upsert("clip_partial2",
    { resolve_item_id = "live_partial2" }, db)

local no_carrier_response = {
    grades = {
        {
            resolve_item_id = "live_partial",
            fidelity        = "partial",
            lut             = { ref = lut_path },
        },
        {
            resolve_item_id = "live_partial2",
            fidelity        = "unrepresentable",
            -- bake failed Resolve-side: no lut field at all
        },
    },
}
local captured2 = sync_grades.apply(no_carrier_response, "seq_one", db,
    now + 120)
check("carrier-less unrepresentable row still written",
    (function()
        local g2 = ClipGrade.load("clip_partial2", db)
        return g2 ~= nil and g2.fidelity == "unrepresentable"
            and g2.lut_ref == nil
    end)())
check("carrier-less grade → reproduction 'not_shown'",
    (ClipGrade.load("clip_partial2", db) or {}).reproduction == "not_shown")
check("no_carrier_count counts exactly the carrier-less row",
    captured2.no_carrier_count == 1)
sync_grades.restore(captured2, db)

-- ─── apply: a SPATIAL grade (power window / sizing) bakes to an IDENTITY
-- cube — the carrier exists but is passthrough. reproduction must be
-- 'not_shown', never silently "graded" (FR-015 / rule 2.32). This is the
-- 01:33:27:16 case that motivated the badge. ────────────────────────
db:exec(([[
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id,
        sequence_id, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, source_in_subframe,
        source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        volume, playhead_frame)
    VALUES ('clip_spatial', 'proj_alpha', 'PS', 't', 'seq_one', 'seq_one',
        192, 96, 0, 96, NULL, NULL, 1, %d, %d, NULL, NULL,
        'resample', 1.0, 0);
]]):format(now, now))
identity_ledger.upsert("clip_spatial",
    { resolve_item_id = "live_spatial" }, db)
local identity_lut = "/tmp/jve/test_sync_grades_lut_bake_path_identity.cube"
write_cube(identity_lut, false)
local spatial_captured = sync_grades.apply({
    grades = {
        {
            resolve_item_id = "live_spatial",
            fidelity        = "unrepresentable",
            lut             = { ref = identity_lut },
        },
    },
}, "seq_one", db, now + 180)
local gs = ClipGrade.load("clip_spatial", db)
check("spatial grade: lut_ref still stored", gs and gs.lut_ref == identity_lut)
check("identity-cube carrier → reproduction 'not_shown'",
    gs and gs.reproduction == "not_shown")
sync_grades.restore(spatial_captured, db)

-- ─── M.execute: helper_args MUST carry bake_lut_dir derived from
-- ~/.jve/resolve_bake/<project_id>/ ─────────────────────────────────
local captured_helper_args = nil
local captured_request_opts = nil
-- The sync's built-in auto-discovery (connect fold) pulls
-- read_identities + read_timeline first; serve both empty so this test
-- keeps exercising ONLY the outgoing read_grades shape.
-- timeline_integer_rate matches the 24000/1001 sequence (integer TC
-- counter 24). (Tracked mock debt — todo_remove_mocks_from_tests.)
local fake_client = {}
function fake_client:request(verb, helper_args, cb, opts)
    if verb == "read_identities" then
        cb({ result = { items = {} } }, nil, nil); return
    elseif verb == "read_timeline" then
        cb({ result = { items = {}, timeline_integer_rate = 24 } },
            nil, nil); return
    end
    assert(verb == "read_grades", "unexpected verb " .. tostring(verb))
    captured_helper_args = helper_args
    captured_request_opts = opts
    -- Return empty grades; we're testing the OUTGOING shape.
    -- warnings is part of the read_grades contract (always present,
    -- possibly empty — helper-protocol.md §read_grades).
    cb({ result = { grades = {}, warnings = {} } }, nil, nil)
end
local orig_with_client = supervisor.with_client
supervisor.with_client = function(_notify, _args, fn) fn(fake_client) end

local fake_command = { parameters = { sequence_id = "seq_one" } }
function fake_command:get_all_parameters() return self.parameters end
function fake_command:set_parameter(k, v) self.parameters[k] = v end

sync_grades.execute({ sequence_id = "seq_one" }, db, fake_command)
supervisor.with_client = orig_with_client

check("helper_args captured", captured_helper_args ~= nil)
check("helper_args.bake_lut_dir is absolute path",
    captured_helper_args
        and type(captured_helper_args.bake_lut_dir) == "string"
        and captured_helper_args.bake_lut_dir:sub(1, 1) == "/")
check("helper_args.bake_lut_dir contains project_id",
    captured_helper_args
        and captured_helper_args.bake_lut_dir
        and captured_helper_args.bake_lut_dir:find("proj_alpha", 1, true))
check("helper_args.bake_lut_dir under ~/.jve/resolve_bake",
    captured_helper_args
        and captured_helper_args.bake_lut_dir
        and captured_helper_args.bake_lut_dir:find(
            "/.jve/resolve_bake/", 1, true))

-- Per-request timeout override: when baking, the helper may spend
-- several minutes inside ExportLUT (1069 clips × hundreds of ms each
-- on Anamnesis). The default REQUEST_TIMEOUT_MS (30 s) trips long
-- before bake finishes — JVE then logs "request timed out" while the
-- helper continues working in the background, leading to an "unknown
-- id" response when it eventually replies. Sync must pass a
-- bake-sized timeout to override the default for THIS verb call.
check("client:request received opts table when baking",
    type(captured_request_opts) == "table")
check("opts.timeout_ms is a positive number",
    captured_request_opts
        and type(captured_request_opts.timeout_ms) == "number"
        and captured_request_opts.timeout_ms > 0)
check("opts.timeout_ms is at least 10 minutes (bake-sized)",
    captured_request_opts
        and captured_request_opts.timeout_ms >= 600000)

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_sync_grades_lut_bake_path.lua: failures present")
print("✅ test_sync_grades_lut_bake_path.lua passed")
