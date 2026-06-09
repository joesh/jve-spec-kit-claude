#!/usr/bin/env luajit
--- MovePlayhead: duration-literal driven playhead movement.
---
--- Verifies the literal grammar (Nf / Ns, signed) + clamp behavior +
--- error paths against the model layer (sequence.playhead_position).
--- No mocks: MovePlayhead routes through core.playhead.set which
--- writes the sequence row and clamps to start_timecode_frame.

require("test_env")

local database       = require("core.database")
local command_manager = require("core.command_manager")
local Sequence       = require("models.sequence")

local DB = "/tmp/jve/test_move_playhead_command.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('proj', 'Test', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
              %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, start_timecode_frame, created_at, modified_at)
      VALUES ('seq', 'proj', 'Seq', 'sequence', 24, 1, 48000, 1920, 1080,
              0, 500, 100, 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled,
        locked, muted, soloed, volume, pan)
      VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now)))

command_manager.init("seq", "proj")

local function park(frame)
    local seq = Sequence.load("seq")
    seq.playhead_position = frame
    seq:save()
end

local function playhead_in_db()
    return Sequence.load("seq").playhead_position
end

local function exec(literal)
    return command_manager.execute("MovePlayhead", {
        _positional = { literal },
        project_id = "proj",
    })
end

print("=== test_move_playhead_command.lua ===")

-- ── Frame literals ─────────────────────────────────────────────────────
park(100)
local r = exec("1f")
assert(r.success, "1f must succeed")
assert(playhead_in_db() == 101, string.format("100+1f → 101, got %s", playhead_in_db()))
print("  PASS 1f from 100 → 101")

park(100)
exec("-1f")
assert(playhead_in_db() == 99, string.format("100-1f → 99, got %s", playhead_in_db()))
print("  PASS -1f from 100 → 99")

-- ── Second literals (24fps → 24-frame step) ────────────────────────────
park(100)
exec("1s")
assert(playhead_in_db() == 124, string.format("100+1s at 24fps → 124, got %s", playhead_in_db()))
print("  PASS 1s at 24fps from 100 → 124")

park(100)
exec("-1s")
assert(playhead_in_db() == 76, string.format("100-1s at 24fps → 76, got %s", playhead_in_db()))
print("  PASS -1s at 24fps from 100 → 76")

park(0)
exec("30f")
assert(playhead_in_db() == 30, string.format("0+30f → 30, got %s", playhead_in_db()))
print("  PASS 30f from 0 → 30")

-- ── Clamp at sequence start_timecode_frame (0) ─────────────────────────
park(100)
exec("-200f")
assert(playhead_in_db() == 0, string.format(
    "100-200f below start_timecode_frame must clamp to 0; got %s",
    playhead_in_db()))
print("  PASS -200f from 100 clamps to 0")

-- ── Error paths ────────────────────────────────────────────────────────
park(100)
local rm = command_manager.execute("MovePlayhead",
    { _positional = {}, project_id = "proj" })
assert(not rm.success, "missing positional arg must fail")
print("  PASS missing positional arg → error")

park(100)
local ri = command_manager.execute("MovePlayhead",
    { _positional = { "abc" }, project_id = "proj" })
assert(not ri.success, "malformed literal 'abc' must fail")
print("  PASS literal 'abc' → error")

park(100)
local ru = command_manager.execute("MovePlayhead",
    { _positional = { "1x" }, project_id = "proj" })
assert(not ru.success, "unknown unit '1x' must fail")
print("  PASS unknown unit '1x' → error")

-- ── Non-zero TC origin: clamp must respect it (not 0) ──────────────────
-- Regression for source-viewer Shift+Back (TSO 2026-05-20): old
-- `math.max(0, ...)` clamp let MovePlayhead seek below a master's
-- start_frame and trip the engine's start-boundary assert.
do
    local seq = Sequence.load("seq")
    seq.start_timecode_frame = 2086474
    seq.playhead_position    = 2086474
    seq:save()

    exec("-1f")
    assert(playhead_in_db() == 2086474, string.format(
        "-1f at start_timecode_frame=2086474 must clamp to 2086474 "
        .. "(not 0 or below); got %s", playhead_in_db()))
    print("  PASS clamp at non-zero TC origin")
end

print("\nPASS test_move_playhead_command.lua")
