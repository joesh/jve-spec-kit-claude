#!/usr/bin/env luajit
-- Regression: per-sequence undo isolation for SetClipProperty.
--
-- Per feature 006 (per-sequence-undo) FR-001 and acceptance scenario 8:
-- each sequence's undo stack is independent. A SetClipProperty on a
-- clip in seqA must NOT be visible from seqB's merged undo view.
-- Switching to seqB and pressing Cmd-Z walks only (seqB cursor +
-- global cursor) — seqA-scoped commands are invisible.
--
-- TSO 2026-04-21 15:24:18 shows this working wrong: undo from active
-- timeline e7032af4 reached into a SetClipProperty that targeted
-- clip on sequence 5b126be6, then crashed in apply_command_mutations
-- because the active cache didn't contain that clip. Root cause:
-- SetClipProperty was landing on the GLOBAL stack (not seqA's) because
-- its SPEC.args doesn't declare sequence_id and the Inspector didn't
-- pass one. Global commands are visible in every merged view — wrong.
--
-- Domain behavior:
--   1. SetClipProperty executed while seqA is active attaches to seqA.
--   2. Switching active to seqB makes seqA's command invisible.
--      can_undo() from seqB is false (assuming no seqB or global
--      commands present).
--   3. Switching back to seqA makes it visible again; undo works.
package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"
require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local timeline_state = require("ui.timeline.timeline_state")

print("=== Mutations to non-active sequence must not crash ===")

local db_path = "/tmp/jve/test_mutations_cross_sequence_skip.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require('import_schema'))
db:exec([[
    CREATE TABLE IF NOT EXISTS properties (
        id TEXT PRIMARY KEY,
        clip_id TEXT NOT NULL,
        property_name TEXT NOT NULL,
        property_value TEXT,
        property_type TEXT,
        default_value TEXT
    );
]])

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('p1', 'Cross Seq Test', 'resample', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES
        ('seqA', 'p1', 'A', 'nested', 24000, 1001, 48000, 1920, 1080,
            0, 240, 0, '[]', '[]', %d, %d),
        ('seqB', 'p1', 'B', 'timeline', 24000, 1001, 48000, 1920, 1080,
            0, 240, 0, '[]', '[]', %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES
        ('tA', 'seqA', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0),
        ('tB', 'seqB', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now, now, now))

-- One clip on seqA, one on seqB.
for _, row in ipairs({
    {id="cA", tid="tA", tl=0,   dur=120},
    {id="cB", tid="tB", tl=0,   dur=60 },
}) do
    local stmt = db:prepare([[
        INSERT INTO clips (id, project_id, clip_kind, owner_sequence_id,
            track_id, media_id, name,
            timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
            fps_numerator, fps_denominator, enabled, created_at, modified_at)
        VALUES (?, 'p1', 'timeline', ?, ?, NULL, ?,
            ?, ?, 0, ?, 24000, 1001, 1, ?, ?)
    ]])
    stmt:bind_value(1, row.id)
    stmt:bind_value(2, row.tid == "tA" and "seqA" or "seqB")
    stmt:bind_value(3, row.tid)
    stmt:bind_value(4, row.id .. "-name")
    stmt:bind_value(5, row.tl); stmt:bind_value(6, row.dur); stmt:bind_value(7, row.dur)
    stmt:bind_value(8, now); stmt:bind_value(9, now)
    assert(stmt:exec(), "clip insert failed for " .. row.id)
    stmt:finalize()
end

-- Activate seqA, edit cA. Inspector-style: pass sequence_id so the
-- command gets scope-routed to seqA's stack (not global).
timeline_state.init("seqA", "p1")
command_manager.init("seqA", "p1")
local cmd = Command.create("SetClipProperty", "p1")
cmd:set_parameter("clip_id", "cA")
cmd:set_parameter("sequence_id", "seqA")   -- scope to seqA's undo stack
cmd:set_parameter("property_name", "duration")
cmd:set_parameter("value", 156)
cmd:set_parameter("property_type", "NUMBER")
assert(command_manager.execute(cmd).success, "precondition: execute on seqA failed")

-- ----------------------------------------------------------------------
-- Check 1: while seqA is active, can_undo() is true (the edit is ours).
-- ----------------------------------------------------------------------
print("Check 1: seqA sees its own SetClipProperty")
assert(command_manager.can_undo(),
    "seqA should see its own SetClipProperty in its merged view")

-- Switch to seqB (simulates user clicking a different timeline tab).
timeline_state.init("seqB", "p1")
command_manager.init("seqB", "p1")
assert(timeline_state.get_sequence_id() == "seqB",
    "precondition: active sequence should be seqB after switch")

-- ----------------------------------------------------------------------
-- Check 2: from seqB, can_undo() is false — the seqA-scoped command
-- is invisible in seqB's merged view (seqB cursor is empty, global
-- cursor is empty, seqA commands don't count). Pressing Cmd-Z here
-- must return "Nothing to undo", NOT reach into seqA's stack.
-- ----------------------------------------------------------------------
print("Check 2: seqB does NOT see seqA's SetClipProperty (isolation)")
assert(not command_manager.can_undo(), string.format(
    "seqB should NOT see seqA's SetClipProperty — per-sequence undo " ..
    "isolation broken. If this fires, SetClipProperty is landing on " ..
    "the GLOBAL stack (visible everywhere) instead of seqA's stack. " ..
    "Fix: declare sequence_id in SetClipProperty's SPEC.args and have " ..
    "the caller pass it."))

local undo_result = command_manager.undo()
assert(not undo_result.success,
    "seqB.undo() should fail cleanly (nothing to undo), not reach into seqA")

-- ----------------------------------------------------------------------
-- Check 3: switch back to seqA, undo works.
-- ----------------------------------------------------------------------
print("Check 3: back on seqA, undo of SetClipProperty succeeds")
timeline_state.init("seqA", "p1")
command_manager.init("seqA", "p1")
assert(command_manager.can_undo(),
    "seqA should still see its SetClipProperty after round-trip")
local undo_a = command_manager.undo()
assert(undo_a.success,
    "seqA undo should succeed: " .. tostring(undo_a.error_message))

-- ----------------------------------------------------------------------
-- Check 4: cA's DB row reverted.
-- ----------------------------------------------------------------------
print("Check 4: cA.duration_frames restored to 120")
local q = db:prepare("SELECT duration_frames FROM clips WHERE id = 'cA'")
assert(q and q:exec() and q:next(), "could not query cA duration")
local db_dur = q:value(0)
q:finalize()
assert(db_dur == 120, string.format(
    "cA duration should revert to 120 in DB, got %s", tostring(db_dur)))

print("✅ test_mutations_cross_sequence_skip.lua passed (Checks 1-4)")
