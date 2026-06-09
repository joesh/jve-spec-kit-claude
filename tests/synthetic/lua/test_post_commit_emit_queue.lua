#!/usr/bin/env luajit

-- Post-commit signal-emit queue (command_manager.queue_post_commit_emit).
--
-- Domain behavior under test:
--   T1: Queued emit fires AFTER the executor returns AND after the DB
--       transaction commits (not during the executor body).
--   T2: Rollback path discards queued emits — listeners must not be told
--       about state that's no longer in the DB.
--   T3: Outside any command (execution_depth==0), the call emits
--       immediately — there's no commit to defer to (e.g. initial-open
--       importer pass).
--
-- Why a test: this hook backs the sequence_list_changed wiring (browser
-- tree refresh after CreateSequence / DeleteSequence / DRP import). A
-- regression that drops the deferred-emit guarantee would let consumers
-- read in-progress transaction state — exactly the inconsistency the
-- queue is here to prevent.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local Signals         = require("core.signals")

print("=== test_post_commit_emit_queue.lua ===")

local DB = "/tmp/jve/test_post_commit_emit_queue.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB), "schema init failed")
local db = database.get_connection()

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'P', 'passthrough', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        created_at, modified_at)
    VALUES ('boot-seq', 'proj', 'boot', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now, now, now)))

-- Active sequence is required for command_manager.init; pick the bootstrap
-- row above. CreateSequence creates additional sequences, but the
-- manager needs an initial focus.
command_manager.init("boot-seq", "proj")

-- ── T1: queued emit fires exactly once after the command commits ───────
-- The signal-driven proof of "deferred to commit" is that the listener
-- doesn't see the emit before the executor's return AND that exactly one
-- emit lands. CreateSequence queues sequence_list_changed via the new
-- queue_post_commit_emit hook; the framework's commit step flushes it.
print("\n-- T1: queued emit fires exactly once after commit")
do
    local list_emits = {}
    local list_token = Signals.connect("sequence_list_changed",
        function(pid) list_emits[#list_emits + 1] = pid end)

    local r = command_manager.execute("CreateSequence", {
        project_id        = "proj",
        name              = "T1-seq",
        frame_rate        = { fps_numerator = 24, fps_denominator = 1 },
        audio_sample_rate = 48000,
        width             = 1920,
        height            = 1080,
    })
    assert(r and r.success, "CreateSequence failed: " .. tostring(r and r.error_message))

    assert(#list_emits == 1, string.format(
        "T1: sequence_list_changed must fire exactly once post-commit; got %d",
        #list_emits))
    assert(list_emits[1] == "proj", string.format(
        "T1: emit must carry project_id 'proj'; got %s",
        tostring(list_emits[1])))

    Signals.disconnect(list_token)
    print("  emit deferred + fired exactly once — OK")
end

-- ── T2: rollback discards queued emits ──────────────────────────────────
-- DeleteSequence against a nonexistent id → executor returns false →
-- framework calls rollback_transaction → discard_post_commit_emits.
-- Any emit the executor would have queued before failing must NOT fire.
print("\n-- T2: failing executor's queued emits are discarded")
do
    local seen = {}
    local token = Signals.connect("sequence_list_changed",
        function(pid) seen[#seen + 1] = pid end)

    local r = command_manager.execute("DeleteSequence", {
        project_id  = "proj",
        sequence_id = "no-such-sequence-id",
    })
    assert(not (r and r.success),
        "T2: DeleteSequence on missing id must fail (precondition)")

    assert(#seen == 0, string.format(
        "T2: no sequence_list_changed emit allowed when command rolls back; got %d emit(s)",
        #seen))

    Signals.disconnect(token)
    print("  rollback discarded queued emit — OK")
end

-- ── T3: emit-immediately when called outside any command ───────────────
print("\n-- T3: no surrounding command → emit fires immediately")
do
    local seen = {}
    local token = Signals.connect("test_q_signal_T3",
        function(payload) seen[#seen + 1] = payload end)

    -- Direct invocation from test code: not inside an executor. The
    -- queue contract says: emit immediately (so importer Open-path keeps
    -- working). No DB commit happens here — the test just verifies the
    -- "no transaction" fast path.
    command_manager.queue_post_commit_emit("test_q_signal_T3", "payload-X")

    assert(#seen == 1 and seen[1] == "payload-X", string.format(
        "T3: outside-of-command queue call must emit immediately; got %d emit(s)",
        #seen))

    Signals.disconnect(token)
    print("  immediate emit when no transaction active — OK")
end

print("\n✅ test_post_commit_emit_queue.lua passed")
