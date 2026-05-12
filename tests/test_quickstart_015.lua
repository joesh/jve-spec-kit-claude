#!/usr/bin/env luajit

-- T024 (015) — Quickstart Steps 1–17 integration skeleton (--test mode).
--
-- Mechanizes quickstart.md against a live JVEEditor process. Each step's
-- "Expected" outcome is an assertion. Run with:
--   ./build/bin/JVEEditor --test tests/test_quickstart_015.lua
--
-- Expected: FAIL on virtually every step today. This file defines the
-- complete integration-level red-green target for Phase 3.3/3.4 work.
-- Initial failure log saved to /tmp/015_t024_initial_failures.txt by the
-- run script; individual steps print their failure to stdout.
--
-- Steps 1–3 and 13 require the C++ Qt UI to render and respond;
-- pure-DB and pure-signal assertions use the live DB path provided by
-- the running editor.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_quickstart_015.lua ===")

-- ── Setup: bootstrap a project + sequences for non-UI steps ──────────────────
local DB = "/tmp/jve/test_quickstart_015.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'QS015', 'resample', %d, %d)
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('rec', 'proj', 'Record', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('src', 'proj', 'Source', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))

-- Record tracks: V1 + A1-A3
db:exec([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('rec_v1', 'rec', 'V1', 'VIDEO', 1, 1)]])
for i = 1, 3 do
    db:exec(string.format(
        [[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('rec_a%d', 'rec', 'A%d', 'AUDIO', %d, 1)]], i, i, i))
end

-- Source tracks: V1 + A1-A8
db:exec([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('src_v1', 'src', 'V1', 'VIDEO', 1, 1)]])
for i = 1, 8 do
    db:exec(string.format(
        [[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('src_a%d', 'src', 'A%d', 'AUDIO', %d, 1)]], i, i, i))
end

-- Set sync_mode. FAIL here if schema migration T025 not applied.
assert(db:exec("UPDATE tracks SET sync_mode='ripple' WHERE sequence_id='rec'"),
    "FAIL Step 9: tracks.sync_mode missing — schema migration T025 not applied")

command_manager.init("rec", "proj")

-- ── Step 4: SourceTab not present by default (FR-001a) ───────────────────────
print("-- Step 4: SourceTab absent by default --")
-- Query project_settings for open_sequence_ids. SourceTab must NOT be in it at cold start.
local settings_s = db:prepare("SELECT settings FROM projects WHERE id='proj'")
assert(settings_s); settings_s:exec(); settings_s:next()
local settings_json = settings_s:value(0); settings_s:finalize()
-- settings_json may be NULL at DB init; that is acceptable (no SourceTab stored).
local has_source_tab = settings_json and settings_json:find('"source_tab"') ~= nil
assert(not has_source_tab,
    "FAIL Step 4: SourceTab must not be present in project_settings at cold start (FR-001a)")
print("  Step 4: SourceTab absent by default — OK")

-- ── Step 5: patch on/off toggle — non-undoable ───────────────────────────────
print("-- Step 5: patch toggle (non-undoable) --")
-- Requires patches table (schema migration) and SetPatch command (T028).
local r5a = command_manager.execute("SetPatch", {
    sequence_id        = "rec",
    project_id         = "proj",
    track_type         = "AUDIO",
    source_track_index = 1,
    record_track_index = 1,
    enabled            = true,
})
assert(r5a and r5a.success,
    "FAIL Step 5: SetPatch create failed: " .. tostring(r5a and r5a.error_message))

local r5b = command_manager.execute("SetPatch", {
    sequence_id        = "rec",
    project_id         = "proj",
    track_type         = "AUDIO",
    source_track_index = 1,
    enabled            = false,
})
assert(r5b and r5b.success,
    "FAIL Step 5: SetPatch disable failed: " .. tostring(r5b and r5b.error_message))

-- Verify enabled=0 in DB.
local p5 = db:prepare(
    "SELECT enabled FROM patches WHERE sequence_id='rec' AND source_track_index=1")
assert(p5); p5:exec(); p5:next()
local p5_enabled = p5:value(0); p5:finalize()
assert(p5_enabled == 0, string.format(
    "FAIL Step 5: patches.enabled=%s, expected 0", tostring(p5_enabled)))

-- Non-undoable: undo must not revert.
command_manager.undo()
p5 = db:prepare("SELECT enabled FROM patches WHERE sequence_id='rec' AND source_track_index=1")
assert(p5); p5:exec(); p5:next()
local p5_after_undo = p5:value(0); p5:finalize()
assert(p5_after_undo == 0,
    "FAIL Step 5: undo reverted SetPatch — must be non-undoable (FR-040)")
print("  Step 5: patch toggle non-undoable — OK")

-- ── Step 6: drag-redirect (plain drag) ───────────────────────────────────────
print("-- Step 6: drag-redirect --")
local r6 = command_manager.execute("SetPatch", {
    sequence_id        = "rec",
    project_id         = "proj",
    track_type         = "AUDIO",
    source_track_index = 2,
    record_track_index = 4,
    enabled            = true,
})
assert(r6 and r6.success,
    "FAIL Step 6: SetPatch redirect failed: " .. tostring(r6 and r6.error_message))

local p6 = db:prepare(
    "SELECT record_track_index FROM patches WHERE sequence_id='rec' AND source_track_index=2")
assert(p6); p6:exec(); p6:next()
local p6_rec = p6:value(0); p6:finalize()
assert(p6_rec == 4, string.format(
    "FAIL Step 6: record_track_index=%s, expected 4", tostring(p6_rec)))

command_manager.undo()
p6 = db:prepare(
    "SELECT record_track_index FROM patches WHERE sequence_id='rec' AND source_track_index=2")
assert(p6); p6:exec(); p6:next()
local p6_after_undo = p6:value(0); p6:finalize()
assert(p6_after_undo == 4,
    "FAIL Step 6: undo reverted drag-redirect — must be non-undoable (FR-040)")
print("  Step 6: drag-redirect non-undoable — OK")

-- ── Step 9: sync-mode cycle + Cut branch ─────────────────────────────────────
print("-- Step 9: sync-mode cycle --")
-- Cycle via SetSyncMode. Each write persists; no snapshots.
for _, mode in ipairs({"off", "ripple", "cut"}) do
    local r9 = command_manager.execute("SetSyncMode", {
        track_id   = "rec_a1",
        sync_mode  = mode,
        project_id = "proj",
    })
    assert(r9 and r9.success,
        "FAIL Step 9: SetSyncMode '" .. mode .. "' failed: " ..
        tostring(r9 and r9.error_message))

    local sm = db:prepare("SELECT sync_mode FROM tracks WHERE id='rec_a1'")
    assert(sm); sm:exec(); sm:next()
    local got = sm:value(0); sm:finalize()
    assert(got == mode, string.format(
        "FAIL Step 9: sync_mode='%s', expected '%s'", tostring(got), mode))
end
print("  Step 9: off/ripple/cut cycle persists — OK")

local function get_sync_mode(track_id)
    local s = db:prepare("SELECT sync_mode FROM tracks WHERE id=?")
    assert(s); s:bind_value(1, track_id); s:exec(); s:next()
    local v = s:value(0); s:finalize()
    assert(v ~= nil, "get_sync_mode: track not found: " .. tostring(track_id))
    return v
end

-- Non-undoable.
local sm_before_undo = get_sync_mode("rec_a1")
command_manager.undo()
local sm_after_undo = get_sync_mode("rec_a1")
assert(sm_after_undo == sm_before_undo,
    "FAIL Step 9: undo reverted SetSyncMode — must be non-undoable (FR-040)")
print("  Step 9: SetSyncMode non-undoable — OK")

-- ── Step 10: Off-mode immunity ────────────────────────────────────────────────
-- (Full ripple+off scenario covered by T012. Quickstart asserts the concept.)
print("-- Step 10: Off-mode (schema check) --")
local r10 = command_manager.execute("SetSyncMode", {
    track_id   = "rec_a2",
    sync_mode  = "off",
    project_id = "proj",
})
assert(r10 and r10.success,
    "FAIL Step 10: SetSyncMode 'off' failed: " .. tostring(r10 and r10.error_message))
print("  Step 10: off-mode set — OK (full behavior tested in T012/test_ripple_sync_off.lua)")

-- ── Step 11: FR-040a — Solo/Mute/Lock non-undoable ───────────────────────────
print("-- Step 11: Solo/Mute/Lock non-undoable --")
for _, prop in ipairs({"soloed", "muted", "locked"}) do
    local r11 = command_manager.execute("ToggleTrackPreference", {
        track_id   = "rec_a1",
        property   = prop,
        project_id = "proj",
    })
    assert(r11 and r11.success,
        "FAIL Step 11: ToggleTrackPreference '" .. prop .. "' failed: " ..
        tostring(r11 and r11.error_message))

    local fld = db:prepare("SELECT " .. prop .. " FROM tracks WHERE id='rec_a1'")
    assert(fld); fld:exec(); fld:next()
    local v_after = fld:value(0); fld:finalize()
    assert(v_after == 1, string.format(
        "FAIL Step 11: %s=%s, expected 1 after toggle", prop, tostring(v_after)))

    command_manager.undo()

    fld = db:prepare("SELECT " .. prop .. " FROM tracks WHERE id='rec_a1'")
    assert(fld); fld:exec(); fld:next()
    local v_undo = fld:value(0); fld:finalize()
    assert(v_undo == 1, string.format(
        "FAIL Step 11: undo reverted %s — must be non-undoable (FR-040a)", prop))
    print(string.format("  Step 11: %s non-undoable — OK", prop))
end

-- ── Step 12: Solo + Mute coexist (no mutex) ──────────────────────────────────
print("-- Step 12: Solo + Mute coexist --")
-- Both are now 1 from Step 11 toggles; assert they can both be 1 simultaneously.
local sm12 = db:prepare("SELECT muted, soloed FROM tracks WHERE id='rec_a1'")
assert(sm12); sm12:exec(); sm12:next()
local muted12, soloed12 = sm12:value(0), sm12:value(1); sm12:finalize()
assert(muted12 == 1 and soloed12 == 1, string.format(
    "FAIL Step 12: muted=%s soloed=%s — both must be 1 simultaneously (no mutex)",
    tostring(muted12), tostring(soloed12)))
print("  Step 12: muted=1 and soloed=1 simultaneously — OK")

-- ── Step 14: 3-point math ─────────────────────────────────────────────────────
print("-- Step 14: 3-point math --")
local tpm_ok, tpm = pcall(require, "core.three_point_math")
assert(tpm_ok,
    "FAIL Step 14: core.three_point_math not found — T044 not applied: " .. tostring(tpm))
-- Fixture: 24fps both sides; src_in=100, src_out=220, rec_in=480 → rec_out=600.
local result14 = tpm.compute(
    { src_in=100, src_out=220, rec_in=480 },
    {24, 1}, {24, 1})
assert(result14 and result14.rec_out == 600, string.format(
    "FAIL Step 14: computed rec_out=%s, expected 600", tostring(result14 and result14.rec_out)))
print("  Step 14: 3-point math rec_out=600 — OK (UI ghost-mark in --test T044)")

-- ── Step 17: auto-create record tracks ───────────────────────────────────────
print("-- Step 17: auto-create record tracks --")

local function count_rec_audio()
    local s = db:prepare(
        "SELECT COUNT(*) FROM tracks WHERE sequence_id='rec' AND track_type='AUDIO'")
    assert(s); s:exec(); s:next(); local n = s:value(0); s:finalize(); return n
end

-- Add patches for A4-A8 (record tracks don't exist yet).
for i = 4, 8 do
    assert(db:exec(string.format([[
        INSERT INTO patches
            (id, sequence_id, track_type, source_track_index, record_track_index, enabled, created_at)
        VALUES ('p_%d', 'rec', 'AUDIO', %d, %d, 1, 0)
    ]], i, i, i)), "FAIL Step 17: patches INSERT failed for source_track_index=" .. i)
end

local rec_before = count_rec_audio()
assert(rec_before == 3,
    "FAIL Step 17: setup expected 3 audio tracks, got " .. tostring(rec_before))

local r17 = command_manager.execute("Insert", {
    sequence_id        = "rec",
    project_id         = "proj",
    source_sequence_id = "src",
    timeline_start_frame = 0,
})
assert(r17 and r17.success,
    "FAIL Step 17: Insert failed: " .. tostring(r17 and r17.error_message))

local rec_after = count_rec_audio()
assert(rec_after == 8, string.format(
    "FAIL Step 17: expected 8 audio tracks after Insert, got %d — T042 not implemented",
    rec_after))
print("  Step 17: 8 audio tracks after Insert — OK")

command_manager.undo()
local rec_undo = count_rec_audio()
assert(rec_undo == 3, string.format(
    "FAIL Step 17: after undo expected 3 audio tracks, got %d", rec_undo))
print("  Step 17: undo removes auto-created tracks — OK")

-- ── Steps requiring --test mode UI rendering ─────────────────────────────────
-- Step 1  (source monitor populated): requires C++ Qt SequenceMonitor.
-- Step 2  (SourceTab blue accent, tab strip):  requires Qt timeline_panel.
-- Step 3  (timeline body shows source content): requires Qt render path.
-- Step 8  (view-toggle modifier hover):        requires Qt key-modifier events.
-- Step 13 (video Mute/Solo compositing):       requires Qt TMB render pipeline.
-- Step 15 (edit targets active seq while SourceTab displayed): requires Qt dispatch.
-- Step 16 (project save/close/reopen persistence round-trip): requires full process.
-- See T016/T017/T018/T019/T020 --test mode tests for those assertions.

print("\n✅ test_quickstart_015.lua passed")
