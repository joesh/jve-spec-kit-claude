-- Optimistic-CAS guard on cursor writes — sibling-session race protection.
--
-- Two Claude sessions can have the same .jvp open under SQLite WAL.
-- Each writes its own in-memory cursor through to the DB. Without a CAS
-- guard, the second session's write silently overwrites the first's — the
-- cursors desync and stale-redo bugs follow.
--
-- This test simulates a sibling session by mutating the cursor column
-- directly (outside the command_history API). The next API-side write
-- MUST fail loudly so the caller can re-read and recover.

require("test_env")

local database = require("core.database")
local command_history = require("core.command_history")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

local function expect_error(label, fn, pattern)
    local ok, err = pcall(fn)
    if ok then
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
        return nil
    end
    if pattern and not tostring(err):match(pattern) then
        fail_count = fail_count + 1
        print("FAIL (wrong error): " .. label .. " got: " .. tostring(err))
        return err
    end
    pass_count = pass_count + 1
    return err
end

print("\n=== Cursor CAS Tests ===")

local db_path = "/tmp/jve/test_undo_cursor_cas.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

local project_id = "proj_cas_001"
local sequence_id = "seq_cas_001"
local now = os.time()
db:exec(string.format(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('%s', 'Test', 'resample', %d, %d)",
    project_id, now, now))
db:exec(string.format(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('%s', '%s', 'Seq1', 'sequence', 30, 1, 48000, 1920, 1080, %d, %d)",
    sequence_id, project_id, now, now))

-- ============================================================
-- Per-sequence cursor: sibling write detected
-- ============================================================
print("\n--- per-sequence cursor CAS ---")
do
    command_history.init(db, sequence_id, project_id)

    -- First write — establishes our "last persisted" value at 5.
    command_history.set_current_sequence_number(5)
    check("save 1 succeeds", pcall(command_history.save_undo_position))

    -- Sibling session writes directly to the DB.
    db:exec(string.format(
        "UPDATE sequences SET current_sequence_number = 99 WHERE id = '%s'", sequence_id))

    -- Our next write must detect the mismatch.
    command_history.set_current_sequence_number(6)
    expect_error("save after sibling write fails loudly",
        command_history.save_undo_position,
        "cursor moved by another writer")
end

-- ============================================================
-- Global cursor: sibling write detected
-- ============================================================
print("\n--- global cursor CAS ---")
do
    command_history.init(db, sequence_id, project_id)

    -- First write — establishes baseline.
    command_history.set_global_cursor(5)

    -- Sibling write.
    db:exec(string.format(
        "UPDATE projects SET global_undo_cursor = 99 WHERE id = '%s'", project_id))

    -- Detected on next write.
    expect_error("global cursor sibling write detected",
        function() command_history.set_global_cursor(6) end,
        "cursor moved by another writer")
end

-- ============================================================
-- Happy path still works
-- ============================================================
print("\n--- happy path unaffected ---")
do
    -- Fresh project so prior tests' final state doesn't bleed in.
    local project_id2 = "proj_cas_002"
    local sequence_id2 = "seq_cas_002"
    db:exec(string.format(
        "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
        .. "VALUES ('%s', 'Test2', 'resample', %d, %d)",
        project_id2, now, now))
    db:exec(string.format(
        "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
        .. "audio_sample_rate, width, height, created_at, modified_at) "
        .. "VALUES ('%s', '%s', 'Seq2', 'sequence', 30, 1, 48000, 1920, 1080, %d, %d)",
        sequence_id2, project_id2, now, now))
    command_history.init(db, sequence_id2, project_id2)

    command_history.set_current_sequence_number(3)
    check("seq save 3 ok", pcall(command_history.save_undo_position))
    command_history.set_current_sequence_number(4)
    check("seq save 4 ok (in-sync sequential)", pcall(command_history.save_undo_position))

    check("global set 7 ok", pcall(function() command_history.set_global_cursor(7) end))
    check("global set 8 ok (in-sync sequential)",
        pcall(function() command_history.set_global_cursor(8) end))
end

print("")
print(string.format("PASS: %d / FAIL: %d", pass_count, pass_count + fail_count))
if fail_count > 0 then
    os.exit(1)
end
print("✅ test_undo_cursor_cas.lua passed")
