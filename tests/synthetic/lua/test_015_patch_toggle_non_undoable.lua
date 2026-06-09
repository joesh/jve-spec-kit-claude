#!/usr/bin/env luajit

-- 015 — FR-040 / FR-035a: patch on/off toggle is a non-snapshotting,
-- non-undoable command. Companion to test_track_preference_non_undoable
-- (which covers solo/mute/lock per FR-040a).
--
-- Spec FR-040: "The following per-track / per-sequence toggles are
-- session-level non-undoable routing preferences: ... Patch on/off
-- (`patches.enabled`), Patch drag-redirect (`patches.record_track_index`)
-- ... They persist in the project DB and survive close+reopen, but they
-- DO NOT land on the per-sequence undo stack — Cmd-Z does not revert
-- any of these toggles."
--
-- Verifies:
--   1. SetPatch creating a new patch produces NO snapshots row.
--   2. SetPatch toggling enabled produces NO snapshots row.
--   3. SetPatch dragging record_track_index produces NO snapshots row.
--   4. command_manager.undo() does NOT revert any of those changes.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local Patch           = require("models.patch")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_015_patch_toggle_non_undoable.lua ===")

local DB = "/tmp/jve/test_015_patch_toggle_non_undoable.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('seq', 'proj', 'S', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, sync_mode)
    VALUES
      ('trk_a1', 'seq', 'A1', 'AUDIO', 1, 1, 'ripple'),
      ('trk_a2', 'seq', 'A2', 'AUDIO', 2, 1, 'ripple');
]], now, now, now, now))

command_manager.init("seq", "proj")

local function snapshot_count()
    local s = db:prepare("SELECT COUNT(*) FROM snapshots")
    s:exec(); s:next()
    local n = s:value(0); s:finalize()
    return n
end

-- ── (1) SetPatch create → no snapshot row ────────────────────────────────
print("-- (1) create patch via SetPatch --")
local snaps0 = snapshot_count()
local r1 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    track_type         = "AUDIO",
    source_shape       = 1,
    source_track_index = 1,
    record_track_index = 1,
    project_id         = "proj",
    enabled            = 1,
})
assert(r1 and r1.success, "SetPatch (create) failed: " .. tostring(r1 and r1.error_message))
assert(snapshot_count() == snaps0, string.format(
    "FAIL: SetPatch (create) wrote a snapshots row — must be non-snapshotting "
    .. "(FR-040). snapshots before=%d after=%d", snaps0, snapshot_count()))
print("  no snapshot row from create — OK")

-- ── (2) SetPatch toggle enabled → no snapshot row ───────────────────────
print("-- (2) toggle patch.enabled --")
local snaps1 = snapshot_count()
local r2 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    track_type         = "AUDIO",
    source_shape       = 1,
    source_track_index = 1,
    project_id         = "proj",
    enabled            = 0,   -- toggle off
})
assert(r2 and r2.success, "SetPatch (toggle) failed: " .. tostring(r2 and r2.error_message))
assert(snapshot_count() == snaps1, string.format(
    "FAIL: SetPatch (toggle) wrote a snapshots row — must be non-snapshotting. "
    .. "before=%d after=%d", snaps1, snapshot_count()))

local p_after_toggle = Patch.find_by_source("seq", "AUDIO", 1, 1)
assert(p_after_toggle.enabled == 0, string.format(
    "FAIL: enabled not toggled to 0, got %s", tostring(p_after_toggle.enabled)))
print("  no snapshot row from toggle; enabled=0 persisted — OK")

-- ── (3) SetPatch drag-redirect → no snapshot row ────────────────────────
print("-- (3) drag-redirect record_track_index --")
local snaps2 = snapshot_count()
local r3 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    track_type         = "AUDIO",
    source_shape       = 1,
    source_track_index = 1,
    record_track_index = 2,   -- redirect
    project_id         = "proj",
})
assert(r3 and r3.success, "SetPatch (redirect) failed: " .. tostring(r3 and r3.error_message))
assert(snapshot_count() == snaps2, string.format(
    "FAIL: SetPatch (redirect) wrote a snapshots row — must be non-snapshotting. "
    .. "before=%d after=%d", snaps2, snapshot_count()))

local p_after_redirect = Patch.find_by_source("seq", "AUDIO", 1, 1)
assert(p_after_redirect.record_track_index == 2, string.format(
    "FAIL: record_track_index not redirected to 2, got %s",
    tostring(p_after_redirect.record_track_index)))
print("  no snapshot row from redirect; rec=2 persisted — OK")

-- ── (4) Cmd-Z (undo) does NOT revert any of these changes ──────────────
print("-- (4) undo is a no-op against patch state --")
command_manager.undo()
command_manager.undo()
command_manager.undo()

local p_after_undo = Patch.find_by_source("seq", "AUDIO", 1, 1)
assert(p_after_undo, "FAIL: patch removed by undo — patches must survive Cmd-Z")
assert(p_after_undo.enabled == 0, string.format(
    "FAIL: undo reverted enabled toggle — got enabled=%s, expected 0 "
    .. "(FR-040 patches are non-undoable)", tostring(p_after_undo.enabled)))
assert(p_after_undo.record_track_index == 2, string.format(
    "FAIL: undo reverted record_track_index — got %s, expected 2",
    tostring(p_after_undo.record_track_index)))
print("  patches state untouched by undo — OK")

print("\nâœ… test_015_patch_toggle_non_undoable.lua passed")
