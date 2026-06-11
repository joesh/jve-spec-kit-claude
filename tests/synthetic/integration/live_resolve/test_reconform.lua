-- T037 — LIVE re-conform (spec 023, FR-012; quickstart step 5).
--
-- Full production round-trip against the VM's Resolve Studio, driven
-- through the REAL commands (no transport shortcuts on the JVE side):
--   1. SendToResolve a 2-clip sequence (DB fixture → payload_builder →
--      drt_writer → helper import; ledger rows persisted).
--   2. Grade BOTH items in Resolve (apply_test_grade, distinct
--      non-trivial CDLs).
--   3. SyncGradesFromResolve → both JVE clips carry their CDL.
--   4. SplitClip the graded main clip — both halves must carry the
--      parent's grade (FR-012 bladed-both-inherit), bystander
--      untouched.
--   5. SendToResolve AGAIN — the re-conform: all THREE clips map
--      (left keeps the parent id, right is a fresh id stamped at
--      import), nothing unrelinked, identities not scrambled, and the
--      new timeline uid differs (a replayed ledger response here would
--      mean the mutation_generation never advanced across the edit).
--   6. Teardown: delete both fixture timelines.
--
-- ⚠ State-changing on the CURRENT Resolve project: run against the VM
-- test environment only (memory: project_vm_test_environment).
--
-- Run via (absolute path, on the VM):
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--       $PWD/tests/synthetic/integration/live_resolve/test_reconform.lua

local test_env = require("test_env")
local database = require("core.database")
local Project = require("models.project")
local Sequence = require("models.sequence")
local Track = require("models.track")
local Media = require("models.media")
local Clip = require("models.clip")
local ClipGrade = require("models.clip_grade")
local command_manager = require("core.command_manager")
local supervisor = require("core.resolve_bridge.helper_supervisor")
local driver = require(
    "synthetic.integration.live_resolve.command_driver")
local repo_root = driver.repo_root

-- Share path: SendToResolve derives media_paths from this and the
-- helper pre-imports it into Resolve's pool — must exist on the guest
-- AND be readable by Resolve (synced-tree copies don't survive
-- sync-to-vm.sh).
local MEDIA_PATH = test_env.resolve_repo_path(
    "tests/fixtures/media/A005_C052_0925BL_001.mp4")
local FPS_NUM, FPS_DEN = 24000, 1001
local MEDIA_FRAMES = 108

-- Distinct, channel-asymmetric CDLs (non-trivial; a swapped clip or
-- channel cannot pass).
local CDL_MAIN = { slope = {1.2, 0.9, 0.85}, offset = {0.02, -0.01, 0.03},
                   power = {0.95, 1.1, 1.05}, sat = 0.8 }
local CDL_BY   = { slope = {0.9, 1.0, 1.1}, offset = {0.05, 0.04, 0.03},
                   power = {1.2, 1.1, 1.0}, sat = 1.1 }
local TOL = 1e-3

local function cdl_close(model_cdl, wire_cdl)
    local pairs_to_check = {
        { model_cdl.slope_r,    wire_cdl.slope[1] },
        { model_cdl.slope_g,    wire_cdl.slope[2] },
        { model_cdl.slope_b,    wire_cdl.slope[3] },
        { model_cdl.offset_r,   wire_cdl.offset[1] },
        { model_cdl.offset_g,   wire_cdl.offset[2] },
        { model_cdl.offset_b,   wire_cdl.offset[3] },
        { model_cdl.power_r,    wire_cdl.power[1] },
        { model_cdl.power_g,    wire_cdl.power[2] },
        { model_cdl.power_b,    wire_cdl.power[3] },
        { model_cdl.saturation, wire_cdl.sat },
    }
    for _, p in ipairs(pairs_to_check) do
        if type(p[1]) ~= "number" or math.abs(p[1] - p[2]) > TOL then
            return false
        end
    end
    return true
end

-- ── DB fixture ───────────────────────────────────────────────────────
local DB_PATH = "/tmp/jve/test_reconform.db"
os.remove(DB_PATH)
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB_PATH), "schema init failed")
local db = database.get_connection()
db:exec(require("import_schema"))

Project.create("p", {
    id = "p1", fps_mismatch_policy = "passthrough",
    settings = { master_clock_hz = 705600000,
                 default_fps = { num = FPS_NUM, den = FPS_DEN } },
}):save()
Sequence.create("m", "p1",
    { fps_numerator = FPS_NUM, fps_denominator = FPS_DEN },
    1920, 1080, { id = "m", kind = "master" }):save()
Sequence.create("jve-t037-reconform", "p1",
    { fps_numerator = FPS_NUM, fps_denominator = FPS_DEN },
    1920, 1080, { id = "e", kind = "sequence",
                  audio_sample_rate = 48000 }):save()
Track.create_video("V1", "m", { id = "m-v1", index = 1 }):save()
Track.create_video("V1", "e", { id = "e-v1", index = 1 }):save()
db:exec("UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm'")
Media.create({
    id = "med-a005", project_id = "p1", name = "A005_C052_0925BL_001.mp4",
    file_path = MEDIA_PATH, duration_frames = MEDIA_FRAMES,
    fps_numerator = FPS_NUM, fps_denominator = FPS_DEN,
    audio_channels = 0,
    metadata = string.format(
        '{"start_tc_value":0,"start_tc_rate":%d}', FPS_NUM),
}):save()
db:exec(string.format([[
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames, audio_sample_rate,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr-a005', 'p1', 'm', 'm-v1', 'med-a005', 0, %d, 0, %d,
        NULL, 1, 1.0, 0, 0, 0);
]], MEDIA_FRAMES, MEDIA_FRAMES))

local MAIN = "0b37c0de-1111-4aaa-8aaa-000000000001"
local BY   = "0b37c0de-2222-4aaa-8aaa-000000000002"
local function seed_clip(id, name, seq_start, dur, src_in)
    local sub_in, sub_out = Clip.subframe_defaults_for_track_type("VIDEO")
    assert(Clip.create({
        id = id, project_id = "p1", owner_sequence_id = "e",
        track_id = "e-v1", sequence_id = "m", name = name,
        sequence_start_frame = seq_start, duration_frames = dur,
        source_in_frame = src_in, source_out_frame = src_in + dur,
        source_in_subframe = sub_in, source_out_subframe = sub_out,
        master_layer_track_id = nil, fps_mismatch_policy = "passthrough",
        enabled = true, volume = 1.0, playhead_frame = 0,
    }) == id)
end
seed_clip(MAIN, "t037 main",      120, 48, 11)
seed_clip(BY,   "t037 bystander", 240, 36, 65)

command_manager.init("e", "p1")
supervisor.configure(repo_root() .. "/tools/resolve-helper/helper.py")

driver.skip_unless_live("test_reconform")

-- ── 1. first send ────────────────────────────────────────────────────
local send1 = driver.run_bridge_command("SendToResolve",
    "send_to_resolve_completed", { project_id = "p1", sequence_id = "e" })
assert(#send1.result.mapping == 2 and #send1.result.unrelinked == 0,
    string.format("T037 send#1: expected 2 mapped / 0 unrelinked, got "
        .. "%d/%d", #send1.result.mapping, #send1.result.unrelinked))
local tl1 = send1.result.resolve_timeline_id
local item_of = {}
for _, row in ipairs(send1.result.mapping) do
    item_of[row.jve_guid] = row.resolve_item_id
end
print("  ✓ send #1: 2 clips mapped, timeline " .. tl1)

-- ── 2. grade both items in Resolve ──────────────────────────────────
local function fresh_token()
    return driver.fresh_token("p1", "e")
end
driver.helper_request("apply_test_grade", {
    resolve_item_id = item_of[MAIN], cdl = CDL_MAIN,
    change_token = fresh_token(),
})
driver.helper_request("apply_test_grade", {
    resolve_item_id = item_of[BY], cdl = CDL_BY,
    change_token = fresh_token(),
})
print("  ✓ graded both items in Resolve")

-- ── 3. sync grades back ─────────────────────────────────────────────
driver.run_bridge_command("SyncGradesFromResolve",
    "sync_grades_from_resolve_completed",
    { project_id = "p1", sequence_id = "e" })
local g_main = ClipGrade.load(MAIN, db)
local g_by   = ClipGrade.load(BY, db)
assert(g_main and g_main.fidelity == "primary"
    and cdl_close(g_main.cdl, CDL_MAIN),
    "T037 sync: main clip grade wrong/missing")
assert(g_by and g_by.fidelity == "primary"
    and cdl_close(g_by.cdl, CDL_BY),
    "T037 sync: bystander grade wrong/missing")
print("  ✓ sync: both JVE clips carry their Resolve grade")

-- ── 4. blade the graded clip ────────────────────────────────────────
assert(command_manager.execute("SplitClip", {
    project_id = "p1", sequence_id = "e",
    clip_id = MAIN, split_frame = 140,
}), "SplitClip failed")
local right = database.select_rows(db,
    "SELECT id FROM clips WHERE track_id = 'e-v1' AND id NOT IN (?, ?)",
    { MAIN, BY }, function(stmt) return stmt:value(0) end)[1]
assert(right, "T037: blade produced no right half")
assert(cdl_close(ClipGrade.load(MAIN, db).cdl, CDL_MAIN)
    and cdl_close(ClipGrade.load(right, db).cdl, CDL_MAIN),
    "T037 FR-012: both halves must carry the parent grade after blade")
assert(cdl_close(ClipGrade.load(BY, db).cdl, CDL_BY),
    "T037: bystander grade scrambled by the blade")
print("  ✓ blade: both halves graded, bystander untouched")

-- ── 5. re-send (the re-conform) ─────────────────────────────────────
local send2 = driver.run_bridge_command("SendToResolve",
    "send_to_resolve_completed", { project_id = "p1", sequence_id = "e" })
assert(#send2.result.mapping == 3 and #send2.result.unrelinked == 0,
    string.format("T037 send#2: expected 3 mapped / 0 unrelinked, got "
        .. "%d/%d — a 2-row replay means mutation_generation never "
        .. "advanced across the blade",
        #send2.result.mapping, #send2.result.unrelinked))
local tl2 = send2.result.resolve_timeline_id
assert(tl2 ~= tl1, "T037 send#2 returned the first timeline uid — "
    .. "idempotency ledger replayed a stale response")
local mapped_ids = {}
for _, row in ipairs(send2.result.mapping) do
    mapped_ids[row.jve_guid] = true
end
assert(mapped_ids[MAIN] and mapped_ids[right] and mapped_ids[BY],
    "T037 send#2: identity scrambled — mapping must carry exactly "
    .. "the left half (parent id), right half, and bystander")
local ids = driver.helper_request("read_identities", {})
assert(#ids.items == 3 and ids.unkeyed_count == 0, string.format(
    "T037: re-conformed timeline must have 3 keyed items, got %d "
    .. "keyed / %d unkeyed", #ids.items, ids.unkeyed_count))
print("  ✓ re-send: 3 clips mapped, identities intact, new timeline "
    .. tl2)

-- JVE grades untouched by the send (send mutates no grade state)
assert(cdl_close(ClipGrade.load(MAIN, db).cdl, CDL_MAIN)
    and cdl_close(ClipGrade.load(right, db).cdl, CDL_MAIN)
    and cdl_close(ClipGrade.load(BY, db).cdl, CDL_BY),
    "T037: a send must not mutate JVE grade rows")

-- ── 6. teardown ─────────────────────────────────────────────────────
for _, tl in ipairs({ tl2, tl1 }) do
    local del = driver.helper_request("delete_timeline", {
        resolve_timeline_id = tl, change_token = fresh_token(),
    })
    assert(del.deleted == true,
        "T037 teardown: failed to delete fixture timeline " .. tl)
end
print("  ✓ teardown: both fixture timelines deleted")

supervisor.shutdown()
print("✅ test_reconform.lua passed")
