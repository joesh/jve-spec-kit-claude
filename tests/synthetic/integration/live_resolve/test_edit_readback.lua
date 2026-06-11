-- T055 — LIVE edit readback (spec 023, FR-024/FR-025; quickstart
--          "trim/slip/move a connected clip in Resolve; run
--          SyncEditsFromResolve" flow).
--
-- Scenario, self-contained against the VM's Resolve Studio. Four clips
-- on one sent timeline, one per divergence kind:
--   A untouched           → skipped(neither_changed)
--   B Resolve-side edit   → applied: trim (Δsource_in=+6, Δsource_out=
--     −4) + move (Δrecord_start=+12) + disable. The matched JVE clip's
--     record/source/enabled converge to the live values via the REAL
--     command pipeline (Phase A ToggleClipEnabled, Phase B
--     OverwriteTrimEdge ×2, Phase C Nudge).
--   C both-sides edit     → conflict: Resolve moves it +24, JVE locally
--     nudges it +5. Surfaces as skipped(no_modal_v1_unhandled_conflict,
--     kind=both); the LOCAL values must survive — pull never overwrites
--     a locally-edited clip.
--   D JVE-local edit only → skipped(only_jve_changed); local values
--     survive.
--
-- Sync #1 (right after send) is the bootstrap pass: all 4 clips must
-- classify neither_changed with fingerprints persisted. That pass is
-- also the end-to-end proof that read_timeline's wire conventions
-- (record_start base, source_out exclusivity) round-trip a JVE-sent
-- timeline exactly — any off-by-one fails loudly here.
--
-- How "the colorist trims the clip" is simulated: Resolve's scripting
-- API has NO trim/move surface on an existing timeline item (probed
-- live 2026-06-10: TimelineItem exposes only getters +
-- SetClipEnabled/SetName/SetCDL), and items appended via
-- MediaPool.AppendToTimeline read back GetSourceEndFrame = in+dur−1
-- while DRT-imported items read back in+dur — an appended replacement
-- can never fingerprint-match a speed-1 clip state. So the surrogate
-- stays entirely on production channels: apply the target edits to the
-- JVE clips with real commands, SendToResolve a second time (the
-- imported timeline's items carry the trimmed geometry AND the
-- identity markers; the send upsert repoints the ledger to the new
-- items while PRESERVING the stored edit fingerprints), then undo the
-- local edits. End state is identical to a human trim in Resolve's UI:
-- ledger fingerprint == JVE state == pre-trim, live items == post-trim.
--
-- ⚠ State-changing on the CURRENT Resolve project: run against the VM
-- test environment only (memory: project_vm_test_environment).
--
-- Run via (absolute path, on the VM):
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--       $PWD/tests/synthetic/integration/live_resolve/test_edit_readback.lua

local test_env = require("test_env")
local database = require("core.database")
local Project = require("models.project")
local Sequence = require("models.sequence")
local Track = require("models.track")
local Media = require("models.media")
local Clip = require("models.clip")
local command_manager = require("core.command_manager")
local supervisor = require("core.resolve_bridge.helper_supervisor")
local driver = require(
    "synthetic.integration.live_resolve.command_driver")

local MEDIA_PATH = test_env.resolve_repo_path(
    "tests/fixtures/media/A005_C052_0925BL_001.mp4")
local FPS_NUM, FPS_DEN = 24000, 1001
local MEDIA_FRAMES = 108
local SEQ = "jve-t055"

-- One clip per divergence kind. Non-trivial source offsets and
-- distinct durations so a unit mix-up cannot cancel out.
local CLIPS = {
    a = { seq_start = 0,   dur = 24, src_in = 5  },
    b = { seq_start = 120, dur = 36, src_in = 47 },
    c = { seq_start = 240, dur = 24, src_in = 11 },
    d = { seq_start = 300, dur = 30, src_in = 60 },
}
-- Resolve-side target for B (absolute frames; the bootstrap pass
-- proves live frames == JVE sequence frames). Trim-decomposable:
-- Δrecord_dur −10 == Δsource_out −4 − Δsource_in +6.
local B_LIVE = { seq_start = 132, dur = 26, src_in = 53, src_out = 79,
                 enabled = false }
local C_RESOLVE_MOVE = 24
local C_LOCAL_NUDGE = 5
local D_LOCAL_NUDGE = 7

-- ── DB fixture: one sequence over one master/media ──────────────────
local DB_PATH = "/tmp/jve/test_edit_readback.db"
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
Sequence.create(SEQ, "p1",
    { fps_numerator = FPS_NUM, fps_denominator = FPS_DEN },
    1920, 1080, { id = SEQ, kind = "sequence",
                  audio_sample_rate = 48000 }):save()
Track.create_video("V1", SEQ, { id = SEQ .. "-v1", index = 1 }):save()
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

local clip_ids = {}
for key, pos in pairs(CLIPS) do
    local id = string.format("0b55c0de-%s%s%s%s-4aaa-8aaa-000000000001",
        key, key, key, key)
    clip_ids[key] = id
    local sub_in, sub_out = Clip.subframe_defaults_for_track_type("VIDEO")
    assert(Clip.create({
        id = id, project_id = "p1", owner_sequence_id = SEQ,
        track_id = SEQ .. "-v1", sequence_id = "m",
        name = "t055 " .. key,
        sequence_start_frame = pos.seq_start, duration_frames = pos.dur,
        source_in_frame = pos.src_in,
        source_out_frame = pos.src_in + pos.dur,
        source_in_subframe = sub_in, source_out_subframe = sub_out,
        master_layer_track_id = nil, fps_mismatch_policy = "passthrough",
        enabled = true, volume = 1.0, playhead_frame = 0,
    }) == id)
end

command_manager.init(SEQ, "p1")
supervisor.configure(
    driver.repo_root() .. "/tools/resolve-helper/helper.py")
driver.skip_unless_live("test_edit_readback")

local function load_state(key)
    local c = Clip.load(clip_ids[key])
    return { seq_start = c.sequence_start, dur = c.duration,
             src_in = c.source_in, src_out = c.source_out,
             enabled = c.enabled }
end

local function assert_state(key, expect, label)
    local got = load_state(key)
    for field, want in pairs(expect) do
        assert(got[field] == want, string.format(
            "T055 %s: clip %s.%s expected %s, got %s", label, key,
            field, tostring(want), tostring(got[field])))
    end
end

local function original_state(key)
    local pos = CLIPS[key]
    return { seq_start = pos.seq_start, dur = pos.dur,
             src_in = pos.src_in, src_out = pos.src_in + pos.dur,
             enabled = true }
end

local function exec_ok(name, args, label)
    local r = command_manager.execute(name, args)
    assert(r and r.success, string.format(
        "T055 %s: %s failed: %s", label, name,
        tostring(r and r.error_message)))
end

local function send_timeline(label)
    local send = driver.run_bridge_command("SendToResolve",
        "send_to_resolve_completed",
        { project_id = "p1", sequence_id = SEQ })
    assert(#send.result.mapping == 4 and #send.result.unrelinked == 0,
        string.format("T055 %s: expected 4 mapped / 0 unrelinked, got "
            .. "%d/%d", label, #send.result.mapping,
            #send.result.unrelinked))
    return send.result.resolve_timeline_id
end

-- ── 1. send the timeline ────────────────────────────────────────────
local tl1 = send_timeline("send #1")
print("  ✓ send #1: 4 clips mapped, timeline " .. tl1)

-- ── 2. bootstrap sync: nothing changed, fingerprints persisted ─────
local boot = driver.run_bridge_command("SyncEditsFromResolve",
    "sync_edits_from_resolve_completed",
    { project_id = "p1", sequence_id = SEQ })
assert(#boot.applied == 0 and #boot.failed == 0, string.format(
    "T055 bootstrap: nothing may apply/fail on an untouched roundtrip "
    .. "(applied=%d failed=%d)", #boot.applied, #boot.failed))
assert(#boot.skipped == 4, string.format(
    "T055 bootstrap: all 4 clips must classify, got %d skipped",
    #boot.skipped))
for _, s in ipairs(boot.skipped) do
    assert(s.reason == "neither_changed", string.format(
        "T055 bootstrap: clip %s classified %s — wire convention "
        .. "divergence between read_timeline and the JVE clip model",
        tostring(s.clip_id), tostring(s.reason)))
end
assert(#boot.fingerprints_persisted == 4,
    "T055 bootstrap: 4 fingerprints must persist, got "
    .. #boot.fingerprints_persisted)
for _, fp in ipairs(boot.fingerprints_persisted) do
    assert(fp.origin == "bootstrap",
        "T055 bootstrap: fingerprint origin must be bootstrap, got "
        .. tostring(fp.origin))
end
print("  ✓ bootstrap sync: 4× neither_changed, 4 fingerprints persisted")

-- ── 3. "colorist edits in Resolve" ──────────────────────────────────
-- Stage the target live state on the JVE clips with real commands,
-- re-send (imported items carry the trimmed geometry + identity
-- markers; ledger repoints to the new items, fingerprints preserved),
-- then undo back to the original state. See header for why this is the
-- only faithful surrogate.
exec_ok("OverwriteTrimEdge", { clip_id = clip_ids.b, edge = "left",
    delta_frames = B_LIVE.src_in - CLIPS.b.src_in,
    project_id = "p1", sequence_id = SEQ }, "stage B")
exec_ok("OverwriteTrimEdge", { clip_id = clip_ids.b, edge = "right",
    delta_frames = B_LIVE.src_out - (CLIPS.b.src_in + CLIPS.b.dur),
    project_id = "p1", sequence_id = SEQ }, "stage B")
exec_ok("Nudge", { selected_clip_ids = { clip_ids.b },
    nudge_amount = B_LIVE.seq_start
        - (CLIPS.b.seq_start + (B_LIVE.src_in - CLIPS.b.src_in)),
    project_id = "p1", sequence_id = SEQ }, "stage B")
exec_ok("ToggleClipEnabled", { project_id = "p1", sequence_id = SEQ,
    clip_toggles = { { clip_id = clip_ids.b,
        enabled_before = true, enabled_after = false } } }, "stage B")
exec_ok("Nudge", { selected_clip_ids = { clip_ids.c },
    nudge_amount = C_RESOLVE_MOVE,
    project_id = "p1", sequence_id = SEQ }, "stage C")
assert_state("b", B_LIVE, "staged")
local STAGED_COMMANDS = 5

local tl2 = send_timeline("send #2")
assert(tl2 ~= tl1, "T055: re-send must import a NEW timeline")
print("  ✓ send #2: trimmed-state timeline " .. tl2)

-- Drop the pre-trim timeline now so only the "colorist's" timeline
-- remains current for the pull.
local del1 = driver.helper_request("delete_timeline", {
    resolve_timeline_id = tl1,
    change_token = driver.fresh_token("p1", SEQ),
})
assert(del1.deleted == true, "T055: pre-trim timeline delete failed")

for i = 1, STAGED_COMMANDS do
    local u = command_manager.undo()
    assert(u and u.success, string.format(
        "T055: undo %d/%d of staged edits failed: %s", i,
        STAGED_COMMANDS, tostring(u and u.error_message)))
end
assert_state("b", original_state("b"), "post-undo")
assert_state("c", original_state("c"), "post-undo")
print("  ✓ staged edits undone: JVE back at pre-trim state, live "
    .. "timeline carries the trims")

-- ── 4. JVE-local edits (C: conflict half; D: local-only) ───────────
exec_ok("Nudge", { selected_clip_ids = { clip_ids.c },
    nudge_amount = C_LOCAL_NUDGE,
    project_id = "p1", sequence_id = SEQ }, "local C")
exec_ok("Nudge", { selected_clip_ids = { clip_ids.d },
    nudge_amount = D_LOCAL_NUDGE,
    project_id = "p1", sequence_id = SEQ }, "local D")
print("  ✓ local edits: C nudged +5, D nudged +7")

-- ── 5. the pull under test ──────────────────────────────────────────
local sync = driver.run_bridge_command("SyncEditsFromResolve",
    "sync_edits_from_resolve_completed",
    { project_id = "p1", sequence_id = SEQ })

assert(#sync.failed == 0, string.format(
    "T055 pull: no dispatch may fail (failed=%d, first: %s %s)",
    #sync.failed, tostring(sync.failed[1] and sync.failed[1].attempted_verb),
    tostring(sync.failed[1] and sync.failed[1].error)))
assert(#sync.applied == 1
        and sync.applied[1].clip_id == clip_ids.b, string.format(
    "T055 pull: exactly B applies, got %d applied (first=%s)",
    #sync.applied, tostring(sync.applied[1] and sync.applied[1].clip_id)))
local verbs = table.concat(sync.applied[1].attempted_verbs, ",")
assert(verbs == "ToggleClipEnabled,OverwriteTrimEdge,OverwriteTrimEdge,Nudge",
    "T055 pull: B must converge via Phase A+B+B+C, got: " .. verbs)

local skipped_reason = {}
for _, s in ipairs(sync.skipped) do
    skipped_reason[s.clip_id] = s
end
assert(skipped_reason[clip_ids.a]
        and skipped_reason[clip_ids.a].reason == "neither_changed",
    "T055 pull: A must skip as neither_changed")
local c_entry = skipped_reason[clip_ids.c]
assert(c_entry and c_entry.reason == "no_modal_v1_unhandled_conflict"
        and c_entry.kind == "both", string.format(
    "T055 pull: C must surface as conflict (both sides changed), got "
    .. "reason=%s kind=%s", tostring(c_entry and c_entry.reason),
    tostring(c_entry and c_entry.kind)))
assert(skipped_reason[clip_ids.d]
        and skipped_reason[clip_ids.d].reason == "only_jve_changed",
    "T055 pull: D must skip as only_jve_changed")
assert(#sync.fingerprints_persisted == 1
        and sync.fingerprints_persisted[1].clip_id == clip_ids.b
        and sync.fingerprints_persisted[1].origin == "phase_success",
    "T055 pull: only B's fingerprint advances")
print("  ✓ pull: B applied (A+B+B+C), C conflict, D local-kept")

-- ── 6. JVE model state: applied vs preserved ────────────────────────
assert_state("a", original_state("a"), "post-pull")
assert_state("b", B_LIVE, "post-pull")
local c_expect = original_state("c")
c_expect.seq_start = c_expect.seq_start + C_LOCAL_NUDGE
assert_state("c", c_expect,
    "post-pull (conflict must NOT overwrite local)")
local d_expect = original_state("d")
d_expect.seq_start = d_expect.seq_start + D_LOCAL_NUDGE
assert_state("d", d_expect,
    "post-pull (local-only must NOT be overwritten)")
print("  ✓ model: B converged to live; C/D local edits intact")

-- ── 7. teardown ─────────────────────────────────────────────────────
local del2 = driver.helper_request("delete_timeline", {
    resolve_timeline_id = tl2,
    change_token = driver.fresh_token("p1", SEQ),
})
assert(del2.deleted == true, "T055 teardown: delete failed")
print("  ✓ teardown: fixture timeline deleted")

supervisor.shutdown()
print("✅ test_edit_readback.lua passed")
