-- 006 smoke: undo within sequence A walks only A's cursor; B's cursor unaffected.
--
-- Acceptance Scenario 1/2: two sequences A and B with interleaved edits.
-- Executing on B then undoing from A must NOT touch B's stack. The cursors
-- are independent.

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_006_per_sequence_undo_smoke.lua ===")

require("test_env")
local database = require("core.database")
local command_manager = require("core.command_manager")

local DB = "/tmp/jve/test_006_per_seq_undo.jvp"
os.execute("mkdir -p /tmp/jve"); os.remove(DB); os.remove(DB..".wal"); os.remove(DB..".shm")
assert(database.init(DB))
local db = database.get_connection()
require("core.command_implementations").register_commands({}, {}, db)
local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('p','P','passthrough','{"master_clock_hz":705600000,"default_fps":{"num":24,"den":1}}',%d,%d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, playhead_frame, view_start_frame,
        view_duration_frames, start_timecode_frame, created_at, modified_at)
      VALUES ('a','p','A','sequence',24,1,48000,1920,1080,0,0,300,0,%d,%d),
             ('b','p','B','sequence',24,1,48000,1920,1080,0,0,300,0,%d,%d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
      VALUES ('a-v1','a','V1','VIDEO',1), ('b-v1','b','V1','VIDEO',1);
]], now, now, now, now, now, now)))

-- Execute one command on each sequence; SetSequenceMetadata is convenient.
command_manager.init("a", "p")
local r1 = command_manager.execute("SetSequenceMetadata", {
    project_id = "p", sequence_id = "a",
    field = "start_timecode_frame", value = 100,
})
assert(r1 and r1.success, "exec on A failed: " .. tostring(r1 and r1.error_message))

command_manager.init("b", "p")
local r2 = command_manager.execute("SetSequenceMetadata", {
    project_id = "p", sequence_id = "b",
    field = "start_timecode_frame", value = 200,
})
assert(r2 and r2.success, "exec on B failed: " .. tostring(r2 and r2.error_message))

local function read_tc(seq_id)
    local s = db:prepare("SELECT start_timecode_frame FROM sequences WHERE id = ?")
    s:bind_value(1, seq_id)
    s:exec(); s:next()
    local v = s:value(0); s:finalize()
    return v
end

assert(read_tc("a") == 100 and read_tc("b") == 200,
    string.format("after edits: A=%s B=%s expected 100/200",
        tostring(read_tc("a")), tostring(read_tc("b"))))
print("  PASS: edits applied to both sequences (A=100, B=200)")

-- Undo while displaying sequence A: only A's cursor walks back.
command_manager.init("a", "p")
local ok_undo = command_manager.undo()
assert(ok_undo, "undo from A's perspective failed")
assert(read_tc("a") == 0, string.format(
    "undo from A: A's TC should revert to 0; got %s", tostring(read_tc("a"))))
assert(read_tc("b") == 200, string.format(
    "undo from A must NOT touch B's stack; B's TC should remain 200; got %s",
    tostring(read_tc("b"))))
print("  PASS: undo from A reverted A only — B's cursor untouched")

print("\n✅ test_006_per_sequence_undo_smoke.lua passed")
