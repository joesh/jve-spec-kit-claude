-- Branch-tip redo: redo follows the user's current branch, not orphan
-- siblings parked by a prior undo-then-different-direction sequence.
--
-- Reproduces Joe's 2026-05-14 TSO bug: an old DeleteSequence (parent=1,
-- global stack) sat as a redoable child of the global cursor forever.
-- A casual Cmd+Shift+Z, while the user was working on a sequence whose
-- per-sequence cursor was much further along, walked the GLOBAL stack
-- back to the orphan and replayed it — nuking the active edit target.
--
-- With the tip fix, the global stack's tip stays at 1 (no global redo
-- available), the orphan stays in the DB but unreachable, and merged
-- redo returns the per-sequence child of the per-sequence cursor on
-- the user's actual branch.

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

print("\n=== Undo Tip / Branch Tests ===")

local db_path = "/tmp/jve/test_undo_tip_branch.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

local project_id = "proj_tip_001"
local sequence_id = "seq_tip_001"
local now = os.time()
db:exec(string.format(
    "INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at) "
    .. "VALUES ('%s', 'T', 'resample', '{\"master_clock_hz\":192000,\"default_fps\":{\"num\":24,\"den\":1}}', %d, %d)", project_id, now, now))
db:exec(string.format(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('%s', '%s', 'S', 'sequence', 30, 1, 48000, 1920, 1080, %d, %d)",
    sequence_id, project_id, now, now))

-- Build a commands tree that mirrors the TSO bug.
-- Cmd #1: RelinkClips (project-level, sequence_id NULL).
-- Cmd #28: DeleteSequence orphan — parent=1, sequence_id NULL. Carries
--          the live sequence_id in args, but the column is NULL so the
--          global-scope redo query sees it.
-- Cmds #25, #29-#38: per-sequence work on seq_tip_001 (parent_sequence_number
--          chain on the same stack).
local function insert_cmd(seq_num, cmd_type, parent, seq_id_col)
    local stmt = db:prepare([[
        INSERT INTO commands (id, sequence_number, command_type, command_args,
                              parent_sequence_number, sequence_id, timestamp)
        VALUES (?, ?, ?, '{}', ?, ?, ?)
    ]])
    stmt:bind_value(1, "cmd_" .. seq_num)
    stmt:bind_value(2, seq_num)
    stmt:bind_value(3, cmd_type)
    if parent ~= nil then stmt:bind_value(4, parent) end
    if seq_id_col ~= nil then stmt:bind_value(5, seq_id_col) end
    stmt:bind_value(6, now * 1000)
    assert(stmt:exec(), "insert_cmd failed for #" .. seq_num)
    stmt:finalize()
end

insert_cmd(1,  "RelinkClips",    nil, nil)
insert_cmd(28, "DeleteSequence", 1,   nil)            -- orphan branch sibling
insert_cmd(25, "DeleteClip",     1,   sequence_id)    -- start of live branch
insert_cmd(29, "SetMarkIn",      25,  sequence_id)
insert_cmd(30, "SetMarkOut",     29,  sequence_id)
insert_cmd(37, "SetMarkIn",      30,  sequence_id)
insert_cmd(38, "SetMarkOut",     37,  sequence_id)

command_history.init(db, sequence_id, project_id)

-- ============================================================
-- Reproduce the bug: per-seq cursor at 37 (user just undid #38),
-- global cursor at 1 (project-level commands haven't been touched).
-- Tip for per-seq is 38 (user's leaf). Tip for global is 1 (no
-- forward progress on the global stack — cmd #28 is on a sibling
-- branch, not the live one).
-- ============================================================
print("\n--- orphan-branch redo invariant ---")
do
    local seq_stack = command_history.stack_id_for_sequence(sequence_id)
    local seq_state = command_history.ensure_stack_state(seq_stack)
    seq_state.current_sequence_number = 37
    seq_state.current_branch_tip = 38

    local global_state = command_history.ensure_stack_state(command_history.GLOBAL_STACK_ID)
    global_state.current_sequence_number = 1
    global_state.current_branch_tip = 1

    local target = command_history.find_merged_redo_target(sequence_id)
    check("redo target exists", target ~= nil)
    check("redo target is the per-seq next (cmd 38, SetMarkOut), not the orphan (cmd 28, DeleteSequence)",
        target and target.sequence_number == 38)
    check("redo target is sequence-scoped, not global",
        target and target.sequence_id == sequence_id)
end

-- ============================================================
-- When global tip IS ahead of global cursor (user undid a global
-- command and wants to redo it), the global redo SHOULD surface.
-- ============================================================
print("\n--- global redo when tip is real ---")
do
    -- Add a real global command on a fresh project so the cursor/tip
    -- relationship is unambiguous.
    insert_cmd(50, "SetGlobalThing", nil, nil)
    insert_cmd(51, "SetGlobalThing", 50,  nil)

    -- Simulate "user did 50 and 51, then undid 51": global cursor=50, tip=51.
    local global_state = command_history.ensure_stack_state(command_history.GLOBAL_STACK_ID)
    global_state.current_sequence_number = 50
    global_state.current_branch_tip = 51
    -- Clear per-seq redo to isolate the global path.
    local seq_state = command_history.ensure_stack_state(
        command_history.stack_id_for_sequence(sequence_id))
    seq_state.current_sequence_number = 38
    seq_state.current_branch_tip = 38

    local target = command_history.find_merged_redo_target(sequence_id)
    check("global redo target returned when tip is ahead of cursor",
        target ~= nil and target.sequence_number == 51)
end

print("")
print(string.format("PASS: %d / FAIL: %d", pass_count, pass_count + fail_count))
if fail_count > 0 then os.exit(1) end
print("✅ test_undo_tip_branch.lua passed")
