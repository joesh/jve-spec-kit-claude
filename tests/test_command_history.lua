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
    if not ok then
        if pattern and not tostring(err):match(pattern) then
            fail_count = fail_count + 1
            print("FAIL (wrong error): " .. label .. " got: " .. tostring(err))
        else
            pass_count = pass_count + 1
        end
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
    end
    return err
end

print("\n=== Command History Tests (T14) ===")

-- ============================================================
-- Database setup
-- ============================================================
local db_path = "/tmp/jve/test_command_history.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

-- Create a project + sequence for undo position persistence
local project_id = "proj_hist_001"
local sequence_id = "seq_hist_001"
local now = os.time()

db:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at) VALUES ('%s', 'Test', %d, %d)",
    project_id, now, now
))
db:exec(string.format(
    "INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at) VALUES ('%s', '%s', 'Seq1', 30, 1, 48000, 1920, 1080, %d, %d)",
    sequence_id, project_id, now, now
))

-- ============================================================
-- init — validation
-- ============================================================
print("\n--- init validation ---")
do
    expect_error("nil sequence_id", function()
        command_history.init(db, nil, project_id)
    end, "sequence_id is required")

    expect_error("empty sequence_id", function()
        command_history.init(db, "", project_id)
    end, "sequence_id is required")

    expect_error("nil project_id", function()
        command_history.init(db, sequence_id, nil)
    end, "project_id is required")

    expect_error("empty project_id", function()
        command_history.init(db, sequence_id, "")
    end, "project_id is required")
end

-- ============================================================
-- init — valid
-- ============================================================
print("\n--- init valid ---")
do
    command_history.init(db, sequence_id, project_id)
    check("last_sequence_number starts at 0 (no commands)", command_history.get_last_sequence_number() == 0)
    check("current_sequence_number nil initially", command_history.get_current_sequence_number() == nil)
    check("active stack is global", command_history.get_current_stack_id() == "global")
end

-- ============================================================
-- reset
-- ============================================================
print("\n--- reset ---")
do
    command_history.set_current_sequence_number(42)
    check("set to 42", command_history.get_current_sequence_number() == 42)

    command_history.reset()
    check("current nil after reset", command_history.get_current_sequence_number() == nil)
    check("last = 0 after reset", command_history.get_last_sequence_number() == 0)
    check("stack reset to global", command_history.get_current_stack_id() == "global")
end

-- ============================================================
-- sequence number management
-- ============================================================
print("\n--- sequence numbers ---")
do
    command_history.reset()
    check("last starts at 0", command_history.get_last_sequence_number() == 0)

    local n1 = command_history.increment_sequence_number()
    check("increment returns 1", n1 == 1)
    check("last now 1", command_history.get_last_sequence_number() == 1)

    local n2 = command_history.increment_sequence_number()
    check("increment returns 2", n2 == 2)

    command_history.decrement_sequence_number()
    check("decrement → 1", command_history.get_last_sequence_number() == 1)

    command_history.set_current_sequence_number(5)
    check("set current to 5", command_history.get_current_sequence_number() == 5)

    -- set_current also updates stack state
    local state = command_history.ensure_stack_state("global")
    check("stack state updated", state.current_sequence_number == 5)
    check("position_initialized true", state.position_initialized == true)
end

-- ============================================================
-- ensure_stack_state
-- ============================================================
print("\n--- ensure_stack_state ---")
do
    command_history.reset()
    local s1 = command_history.ensure_stack_state("new_stack")
    check("creates new state", s1 ~= nil)
    check("new state current nil", s1.current_sequence_number == nil)
    check("new state branch_path empty", #s1.current_branch_path == 0)
    check("new state not initialized", s1.position_initialized == false)

    -- Returns same object on second call
    local s2 = command_history.ensure_stack_state("new_stack")
    check("returns existing state", rawequal(s1, s2))

    -- nil → defaults to global
    local sg = command_history.ensure_stack_state(nil)
    check("nil → global stack", sg ~= nil)
end

-- ============================================================
-- apply_stack_state
-- ============================================================
print("\n--- apply_stack_state ---")
do
    command_history.reset()
    -- Set up a non-global stack with known state
    local state = command_history.ensure_stack_state("custom_stack")
    state.current_sequence_number = 77

    command_history.apply_stack_state("custom_stack")
    check("apply sets active stack", command_history.get_current_stack_id() == "custom_stack")
    check("apply restores current_sequence_number", command_history.get_current_sequence_number() == 77)

    -- nil defaults to global
    command_history.apply_stack_state(nil)
    check("nil → global", command_history.get_current_stack_id() == "global")
end

-- ============================================================
-- set_active_stack with sequence_id
-- ============================================================
print("\n--- set_active_stack ---")
do
    command_history.init(db, sequence_id, project_id)

    command_history.set_active_stack("my_stack", {sequence_id = "seq_abc"})
    check("active stack set", command_history.get_current_stack_id() == "my_stack")

    local seq = command_history.get_current_stack_sequence_id(false)
    check("stack sequence_id set", seq == "seq_abc")
end

-- ============================================================
-- get_current_stack_sequence_id
-- ============================================================
print("\n--- get_current_stack_sequence_id ---")
do
    command_history.init(db, sequence_id, project_id)

    -- Global stack has active_sequence_id from init
    local s1 = command_history.get_current_stack_sequence_id(false)
    check("global stack has sequence_id", s1 == sequence_id)

    -- Switch to empty stack
    command_history.set_active_stack("empty_stack")
    local s2 = command_history.get_current_stack_sequence_id(false)
    check("empty stack → nil (no fallback)", s2 == nil)

    local s3 = command_history.get_current_stack_sequence_id(true)
    check("empty stack → active_sequence_id (with fallback)", s3 == sequence_id)
end

-- ============================================================
-- stack_id_for_sequence (multi_stack_enabled = false by default)
-- ============================================================
print("\n--- stack_id_for_sequence ---")
do
    -- Without JVE_ENABLE_MULTI_STACK_UNDO=1, always returns "global"
    local id1 = command_history.stack_id_for_sequence("some_seq")
    check("multi-stack disabled → global", id1 == "global")

    local id2 = command_history.stack_id_for_sequence(nil)
    check("nil seq → global", id2 == "global")

    local id3 = command_history.stack_id_for_sequence("")
    check("empty seq → global", id3 == "global")
end

-- ============================================================
-- resolve_stack_for_command (multi_stack disabled)
-- ============================================================
print("\n--- resolve_stack_for_command ---")
do
    -- Multi-stack disabled → always global
    local cmd = {type = "TestCommand"}
    local stack_id, opts = command_history.resolve_stack_for_command(cmd)
    check("disabled → global", stack_id == "global")
    check("disabled → nil opts", opts == nil)
end

-- ============================================================
-- undo groups — Emacs-style
-- ============================================================
print("\n--- undo groups ---")
do
    command_history.init(db, sequence_id, project_id)
    command_history.set_current_sequence_number(10)

    -- No active group
    check("no group initially", command_history.get_current_undo_group_id() == nil)
    check("no group cursor", command_history.get_undo_group_cursor_on_entry() == nil)

    -- Begin group with explicit id
    local gid = command_history.begin_undo_group("First group", "group_A")
    check("begin returns group_id", gid == "group_A")
    check("current group = group_A", command_history.get_current_undo_group_id() == "group_A")
    check("cursor_on_entry = 10", command_history.get_undo_group_cursor_on_entry() == 10)

    -- Nested group → collapses to outermost (Emacs semantics)
    command_history.set_current_sequence_number(15)
    local gid2 = command_history.begin_undo_group("Nested group", "group_B")
    check("nested returns group_B", gid2 == "group_B")
    check("current still group_A (outermost)", command_history.get_current_undo_group_id() == "group_A")
    check("cursor still 10 (outermost entry)", command_history.get_undo_group_cursor_on_entry() == 10)

    -- End inner group
    local ended = command_history.end_undo_group()
    check("end inner returns group_B", ended == "group_B")
    check("outer still active", command_history.get_current_undo_group_id() == "group_A")

    -- End outer group
    local ended2 = command_history.end_undo_group()
    check("end outer returns group_A", ended2 == "group_A")
    check("no active group", command_history.get_current_undo_group_id() == nil)

    -- End with no active group → nil
    local ended3 = command_history.end_undo_group()
    check("end with none → nil", ended3 == nil)
end

-- ============================================================
-- undo groups — auto-generated id
-- ============================================================
print("\n--- undo groups auto id ---")
do
    command_history.init(db, sequence_id, project_id)

    local gid = command_history.begin_undo_group("Auto group")
    check("auto id starts with explicit_group_", gid:find("^explicit_group_") ~= nil)

    local gid2 = command_history.begin_undo_group("Second auto")
    check("second auto id different", gid2 ~= gid)

    command_history.end_undo_group()
    command_history.end_undo_group()
end

-- ============================================================
-- undo groups — cursor captures current_sequence_number at entry
-- ============================================================
print("\n--- undo group cursor ---")
do
    command_history.init(db, sequence_id, project_id)

    -- nil current_sequence_number
    command_history.begin_undo_group("nil cursor")
    check("cursor nil when no current", command_history.get_undo_group_cursor_on_entry() == nil)
    command_history.end_undo_group()
end

-- ============================================================
-- save_undo_position / load_sequence_undo_position
-- ============================================================
print("\n--- save/load undo position ---")
do
    command_history.init(db, sequence_id, project_id)
    command_history.set_current_sequence_number(25)

    local saved = command_history.save_undo_position()
    check("save returns true", saved == true)

    -- Load back
    local val, has_row = command_history.load_sequence_undo_position(sequence_id)
    check("loaded value = 25", val == 25)
    check("has_row = true", has_row == true)

    -- nil current → saves 0
    command_history.set_current_sequence_number(nil)
    command_history.save_undo_position()
    local val2, _ = command_history.load_sequence_undo_position(sequence_id)
    check("nil current saved as 0", val2 == 0)

    -- Load nonexistent sequence
    local val3, has3 = command_history.load_sequence_undo_position("nonexistent_seq")
    check("nonexistent → nil value", val3 == nil)
    check("nonexistent → no row", has3 == false)

    -- nil/empty sequence_id
    local val4, has4 = command_history.load_sequence_undo_position(nil)
    check("nil seq → nil", val4 == nil)
    check("nil seq → false", has4 == false)

    local val5, has5 = command_history.load_sequence_undo_position("")
    check("empty seq → nil", val5 == nil)
    check("empty seq → false", has5 == false)
end

-- ============================================================
-- save_undo_position — no db
-- ============================================================
print("\n--- save_undo_position edge cases ---")
do
    -- No sequence_id on stack → false
    command_history.init(db, sequence_id, project_id)
    command_history.set_active_stack("orphan_stack")
    local r = command_history.save_undo_position()
    -- orphan_stack has no sequence_id, fallback to active_sequence_id
    check("fallback to active sequence → true", r == true)
end

-- ============================================================
-- initialize_stack_position_from_db — branches
-- ============================================================
print("\n--- initialize_stack_position_from_db ---")
do
    -- Create a command at sequence_number=42 so the cursor isn't orphaned
    local insert_cmd = db:prepare([[
        INSERT OR REPLACE INTO commands (id, sequence_number, command_type, command_args, timestamp)
        VALUES ('cmd_42', 42, 'TestCmd', '{}', 0)
    ]])
    insert_cmd:exec()
    insert_cmd:finalize()

    -- Save position 42 to DB
    command_history.init(db, sequence_id, project_id)
    command_history.set_current_sequence_number(42)
    command_history.save_undo_position()

    -- Re-init → should pick up saved position (command exists, not orphaned)
    command_history.init(db, sequence_id, project_id)
    check("position restored from DB", command_history.get_current_sequence_number() == 42)

    -- Save 0 → should set current to nil
    command_history.set_current_sequence_number(0)
    -- Manually write 0 to DB
    local upd = db:prepare("UPDATE sequences SET current_sequence_number = 0 WHERE id = ?")
    upd:bind_value(1, sequence_id)
    upd:exec()
    upd:finalize()

    command_history.reset()
    command_history.init(db, sequence_id, project_id)
    check("saved 0 → current nil", command_history.get_current_sequence_number() == nil)

    -- Test orphan detection: set cursor to non-existent command
    db:exec("DELETE FROM commands WHERE sequence_number = 42")
    local upd2 = db:prepare("UPDATE sequences SET current_sequence_number = 999 WHERE id = ?")
    upd2:bind_value(1, sequence_id)
    upd2:exec()
    upd2:finalize()

    command_history.reset()
    command_history.init(db, sequence_id, project_id)
    -- Orphan detected: cursor was 999 but no command exists, should reset to nil (no commands)
    check("orphan cursor reset to nil", command_history.get_current_sequence_number() == nil)
end

-- ============================================================
-- find_latest_child_command
-- ============================================================
print("\n--- find_latest_child_command ---")
do
    command_history.init(db, sequence_id, project_id)

    -- Insert some commands
    local json = require("dkjson")
    local args_json = json.encode({clip_id = "clip_001"})

    db:exec(string.format(
        "INSERT INTO commands (id, command_type, sequence_number, command_args, playhead_value, playhead_rate, timestamp) VALUES ('cmd1', 'InsertClip', 1, '%s', 0, 30, %d)",
        args_json, now
    ))
    db:exec(string.format(
        "INSERT INTO commands (id, command_type, sequence_number, command_args, parent_sequence_number, playhead_value, playhead_rate, timestamp) VALUES ('cmd2', 'SplitClip', 2, '%s', 1, 10, 30, %d)",
        json.encode({split_time = 100}), now
    ))
    db:exec(string.format(
        "INSERT INTO commands (id, command_type, sequence_number, command_args, parent_sequence_number, playhead_value, playhead_rate, timestamp) VALUES ('cmd3', 'DeleteClip', 3, '%s', 1, 20, 30, %d)",
        json.encode({}), now
    ))

    -- Find latest child of parent seq 1
    local child = command_history.find_latest_child_command(1)
    check("found child", child ~= nil)
    check("latest child seq = 3", child.sequence_number == 3)
    check("latest child type = DeleteClip", child.command_type == "DeleteClip")
    check("command_args decoded", type(child.command_args) == "table")

    -- Find top-level commands (parent_sequence_number IS NULL, treated as parent=0)
    local top = command_history.find_latest_child_command(0)
    check("top-level found", top ~= nil)
    check("top-level seq = 1", top.sequence_number == 1)
    check("top-level args decoded", top.command_args.clip_id == "clip_001")

    -- Nonexistent parent
    local none = command_history.find_latest_child_command(999)
    check("nonexistent parent → nil", none == nil)
end

-- ============================================================
-- find_latest_child_command — no db
-- ============================================================
print("\n--- find_latest_child no db ---")
do
    -- Temporarily set db to nil via reset + partial init trick
    -- Actually, we can't easily nil the module-local db. Skip this edge case.
    -- The function guards with `if not db then return nil end`
    pass_count = pass_count + 0 -- placeholder
end

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n=== Command History: %d passed, %d failed ===", pass_count, fail_count))
if fail_count > 0 then
    os.exit(1)
end
print("✅ test_command_history.lua passed")
