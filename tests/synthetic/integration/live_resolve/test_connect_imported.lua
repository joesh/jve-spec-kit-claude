-- T050 — LIVE first sync of an imported project, no connect step
--          (spec 023, FR-011b/c; quickstart "imported a graded DRP,
--          hook up the grade" flow; connect fold 2026-06-12 — identity
--          discovery runs automatically inside every sync).
--
-- Scenario, built self-contained against the VM's Resolve Studio:
--   1. Sequence e1 ("the original sender") SendToResolve's 3 clips —
--      the imported timeline's items carry e1's identity markers.
--   2. Each item gets a DISTINCT known CDL (apply_test_grade).
--   3. Sequence e2 simulates "JVE opened a project imported from the
--      colorist's DRP": same edit (names, positions, source ranges,
--      media) but FRESH clip ids and an EMPTY identity ledger — the
--      resolve_bridge_link reset below constructs exactly the state a
--      newly-imported .jvp is in (it has never sent or synced).
--   4. SyncGradesFromResolve(e2) — the ONLY user action. Its built-in
--      auto-discovery must run first: the marker channel must MISS
--      (the live markers carry e1's ids, which are not in e2 —
--      cross-sequence ids are ignored by design) and the position/
--      content channel must match all 3 pairs, positionally correct,
--      nothing unmatched/ambiguous — all asserted via the sync
--      result's `discovery` report.
--   5. The same single sync lands each position's exact CDL on the
--      RIGHT e2 clip, none scrambled.
--   6. Teardown: delete the fixture timeline.
--
-- ⚠ State-changing on the CURRENT Resolve project: run against the VM
-- test environment only (memory: project_vm_test_environment).
--
-- Run via (absolute path, on the VM):
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--       $PWD/tests/synthetic/integration/live_resolve/test_connect_imported.lua

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

-- resolve_repo_path: on the guest (JVE_IN_VM=1) fixture media resolves
-- through the virtiofs share — scp'd copies in the synced tree do NOT
-- survive sync-to-vm.sh, and Resolve must be able to READ this path to
-- link the media (the DRT Clip blob embeds it).
local MEDIA_PATH = test_env.resolve_repo_path(
    "tests/fixtures/media/A005_C052_0925BL_001.mp4")
local FPS_NUM, FPS_DEN = 24000, 1001
local MEDIA_FRAMES = 108
local TOL = 1e-3

-- One clip per timeline position; each position gets its own CDL.
-- Distinct, channel-asymmetric values — a positional swap cannot pass.
local POSITIONS = {
    { name = "t050 alpha", seq_start = 120, dur = 36, src_in = 11,
      cdl = { slope = {1.2, 0.9, 0.85}, offset = {0.02, -0.01, 0.03},
              power = {0.95, 1.1, 1.05}, sat = 0.8 } },
    { name = "t050 beta",  seq_start = 240, dur = 24, src_in = 47,
      cdl = { slope = {0.9, 1.0, 1.1}, offset = {0.05, 0.04, 0.03},
              power = {1.2, 1.1, 1.0}, sat = 1.1 } },
    { name = "t050 gamma", seq_start = 320, dur = 30, src_in = 71,
      cdl = { slope = {1.0, 1.15, 0.8}, offset = {-0.03, 0.0, 0.02},
              power = {1.05, 0.9, 1.15}, sat = 0.95 } },
}

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

-- ── DB fixture: two sequences over the same master/media ───────────
local DB_PATH = "/tmp/jve/test_connect_imported.db"
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
for _, seq_id in ipairs({ "e1", "e2" }) do
    Sequence.create("jve-t050-connect-" .. seq_id, "p1",
        { fps_numerator = FPS_NUM, fps_denominator = FPS_DEN },
        1920, 1080, { id = seq_id, kind = "sequence",
                      audio_sample_rate = 48000 }):save()
    Track.create_video("V1", seq_id,
        { id = seq_id .. "-v1", index = 1 }):save()
end
Track.create_video("V1", "m", { id = "m-v1", index = 1 }):save()
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

-- e1 (JVE-native sender) keeps its user-chosen names. e2 simulates a
-- project imported from the colorist's DRP, and Resolve rewrites every
-- timeline item's Name to the pool-clip (media) name on DRT import
-- (live-proven 2026-06-10: probe4 re-export carried
-- 'A005_C052_0925BL_001.mp4' for all items, never the sent names) — so
-- a DRP-imported clip can only ever carry the media name, and the
-- position channel's name check (FR-011c) compares against exactly that.
local function seed_clip(id, seq_id, pos)
    local clip_name = (seq_id == "e2") and "A005_C052_0925BL_001.mp4"
        or pos.name
    local sub_in, sub_out = Clip.subframe_defaults_for_track_type("VIDEO")
    assert(Clip.create({
        id = id, project_id = "p1", owner_sequence_id = seq_id,
        track_id = seq_id .. "-v1", sequence_id = "m", name = clip_name,
        sequence_start_frame = pos.seq_start, duration_frames = pos.dur,
        source_in_frame = pos.src_in,
        source_out_frame = pos.src_in + pos.dur,
        source_in_subframe = sub_in, source_out_subframe = sub_out,
        master_layer_track_id = nil, fps_mismatch_policy = "passthrough",
        enabled = true, volume = 1.0, playhead_frame = 0,
    }) == id)
end

local e1_ids, e2_ids = {}, {}
for i, pos in ipairs(POSITIONS) do
    e1_ids[i] = string.format("0b50c0de-1111-4aaa-8aaa-%012d", i)
    e2_ids[i] = string.format("0b50c0de-2222-4aaa-8aaa-%012d", i)
    seed_clip(e1_ids[i], "e1", pos)
    seed_clip(e2_ids[i], "e2", pos)
end

command_manager.init("e1", "p1")
supervisor.configure(
    driver.repo_root() .. "/tools/resolve-helper/helper.py")
driver.skip_unless_live("test_connect_imported")

-- ── 1. original sender exports the timeline ─────────────────────────
local send = driver.run_bridge_command("SendToResolve",
    "send_to_resolve_completed", { project_id = "p1", sequence_id = "e1" })
assert(#send.result.mapping == 3 and #send.result.unrelinked == 0,
    string.format("T050 send: expected 3 mapped / 0 unrelinked, got "
        .. "%d/%d", #send.result.mapping, #send.result.unrelinked))
local tl = send.result.resolve_timeline_id
local item_by_e1 = {}
for _, row in ipairs(send.result.mapping) do
    item_by_e1[row.jve_guid] = row.resolve_item_id
end
print("  ✓ send: 3 clips mapped, timeline " .. tl)

-- ── 2. grade each item with its position's CDL ─────────────────────
for i, pos in ipairs(POSITIONS) do
    driver.helper_request("apply_test_grade", {
        resolve_item_id = item_by_e1[e1_ids[i]], cdl = pos.cdl,
        change_token = driver.fresh_token("p1", "e1"),
    })
end
print("  ✓ graded all 3 items (distinct CDLs by position)")

-- ── 3. construct the freshly-imported-project state ────────────────
-- A .jvp imported from the colorist's DRP has never sent or connected:
-- its identity ledger is empty. e2 (fresh ids, same edit) plus this
-- reset IS that state — without it, e1's rows from step 1 would
-- violate the one-clip-per-resolve-item ledger invariant the moment
-- e2 connects.
assert(db:exec("DELETE FROM resolve_bridge_link"),
    "T050: ledger reset failed")

-- ── 4. first sync: auto-discovery + grades, ONE user action ─────────
-- The connect fold (2026-06-12): there is no user-visible connect
-- step. SyncGradesFromResolve runs discovery itself (read-only,
-- ledger-idempotent) before pulling grades, and surfaces the match
-- report on its result. This sync starts from the EMPTY ledger built
-- in step 3 — if auto-discovery regressed, the join is empty and the
-- ClipGrade asserts below fail.
local sync = driver.run_bridge_command("SyncGradesFromResolve",
    "sync_grades_from_resolve_completed",
    { project_id = "p1", sequence_id = "e2" })
local disc = sync.discovery
assert(type(disc) == "table",
    "T050: sync result must carry the auto-discovery report")
assert(#disc.matched == 3, string.format(
    "T050: expected all 3 clips matched, got %d (unmatched=%d "
    .. "ambiguous=%d)", #disc.matched, #disc.unmatched,
    #disc.ambiguous))
assert(#disc.unmatched == 0 and #disc.ambiguous == 0,
    "T050: nothing may be unmatched/ambiguous on an identical edit")
assert(disc.rate_mismatch == nil,
    "T050: rates agree by construction; position channel must run")
assert(disc.already_linked == 0,
    "T050: ledger was reset in step 3 — nothing may be pre-linked")
-- Auto-stamp (FR-012): discovery stamps each new position match. The
-- live items already carry e1's identity markers (written at import in
-- step 1) with DIFFERENT customData, so all 3 stamps must REFUSE —
-- conflicting identity is surfaced, never overwritten — while the
-- ledger links (and the grade application below) work regardless.
assert(#disc.stamp_failures == 3 and #disc.stamped == 0,
    string.format("T050: expected 3 refused stamps on e1-marked items, "
        .. "got stamped=%d skipped=%d failures=%d",
        #disc.stamped, #disc.stamp_skipped, #disc.stamp_failures))
local e2_pos_by_id, item_pos_by_id = {}, {}
for i in ipairs(POSITIONS) do
    e2_pos_by_id[e2_ids[i]] = i
    item_pos_by_id[item_by_e1[e1_ids[i]]] = i
end
for _, m in ipairs(disc.matched) do
    assert(m.source == "position_match", string.format(
        "T050: e1's markers must not match e2 ids (cross-sequence "
        .. "ignored); expected position_match, got %q for %s",
        tostring(m.source), tostring(m.clip_id)))
    local cpos = e2_pos_by_id[m.clip_id]
    local ipos = item_pos_by_id[m.resolve_item_id]
    assert(cpos and ipos and cpos == ipos, string.format(
        "T050: positional mis-link — e2 clip at position %s linked to "
        .. "live item at position %s", tostring(cpos), tostring(ipos)))
end
print("  ✓ auto-discovery: 3/3 position-matched, positionally correct")

-- ── 5. grades landed on the right clips (same single sync) ──────────
for i, pos in ipairs(POSITIONS) do
    local g = ClipGrade.load(e2_ids[i], db)
    assert(g and g.fidelity == "primary" and cdl_close(g.cdl, pos.cdl),
        string.format("T050: clip %q (position %d) must carry exactly "
            .. "its position's CDL", pos.name, i))
end
print("  ✓ sync: every imported clip carries its position's grade")

-- ── 6. teardown ─────────────────────────────────────────────────────
local del = driver.helper_request("delete_timeline", {
    resolve_timeline_id = tl,
    change_token = driver.fresh_token("p1", "e1"),
})
assert(del.deleted == true, "T050 teardown: delete failed")
print("  ✓ teardown: fixture timeline deleted")

supervisor.shutdown()
print("✅ test_connect_imported.lua passed")
