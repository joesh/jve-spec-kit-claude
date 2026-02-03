require("test_env")

local Command = require("command")
local json = require("dkjson")
local database = require("core.database")

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

--- Mock query object for parse_from_query tests.
-- @param values  array of column values (0-indexed via closure)
-- @param col_count  column_count to report via record():count()
local function mock_query(values, col_count)
    return {
        value = function(_, idx) return values[idx] end,
        record = function()
            return { count = function() return col_count or 0 end }
        end,
    }
end

print("\n=== Command Error Paths Tests (T6) ===")


-- ═══════════════════════════════════════════════════════════════
-- 1. deserialize
-- ═══════════════════════════════════════════════════════════════

print("\n--- 1. deserialize ---")

-- 1a. nil → (nil, "JSON string is empty")
local cmd, err = Command.deserialize(nil)
check("deserialize(nil) → nil", cmd == nil)
check("deserialize(nil) reason", err == "JSON string is empty")

-- 1b. empty string → (nil, "JSON string is empty")
cmd, err = Command.deserialize("")
check("deserialize('') → nil", cmd == nil)
check("deserialize('') reason", err == "JSON string is empty")

-- 1c. invalid JSON → (nil, "Failed to decode JSON: ...")
cmd, err = Command.deserialize("{bad json###")
-- dkjson doesn't throw, returns (nil, pos, errmsg). pcall(json.decode, ...) succeeds
-- with decoded=nil, so falls through to "not a table" check
check("deserialize(bad json) → nil", cmd == nil)
check("deserialize(bad json) reason", type(err) == "string" and err:match("not a table"))

-- 1d. JSON string (not table) → (nil, "Decoded JSON is not a table")
cmd, err = Command.deserialize('"just a string"')
check("deserialize(string) → nil", cmd == nil)
check("deserialize(string) reason", err == "Decoded JSON is not a table")

-- 1e. JSON null → (nil, "Decoded JSON is not a table")
cmd, err = Command.deserialize("null")
check("deserialize(null) → nil", cmd == nil)
check("deserialize(null) reason", err == "Decoded JSON is not a table")

-- 1f. JSON number → (nil, "Decoded JSON is not a table")
cmd, err = Command.deserialize("42")
check("deserialize(number) → nil", cmd == nil)
check("deserialize(number) reason", err == "Decoded JSON is not a table")

-- 1g. Valid JSON → command object
local valid_json = json.encode({
    type = "InsertClip",
    project_id = "proj1",
    sequence_number = 5,
    status = "Executed",
    parameters = { clip_id = "c1", track_id = "t1" },
    playhead_value = 100,
    playhead_rate = 24,
})
cmd, err = Command.deserialize(valid_json)
check("deserialize valid → command", cmd ~= nil)
check("deserialize valid → no error", err == nil)
check("deserialized type", cmd.type == "InsertClip")
check("deserialized project_id", cmd.project_id == "proj1")
check("deserialized sequence_number", cmd.sequence_number == 5)
check("deserialized params.clip_id", cmd:get_parameter("clip_id") == "c1")
check("deserialized playhead_value", cmd.playhead_value == 100)
check("deserialized playhead_rate", cmd.playhead_rate == 24)


-- ═══════════════════════════════════════════════════════════════
-- 2. serialize
-- ═══════════════════════════════════════════════════════════════

print("\n--- 2. serialize ---")

-- 2a. Valid serialize with numeric playhead_rate
cmd = Command.create("TestCmd", "proj1")
cmd.playhead_value = 50
cmd.playhead_rate = 24
cmd.executed_at = os.time()
local json_str = cmd:serialize()
check("serialize valid → string", type(json_str) == "string")
local decoded = json.decode(json_str)
check("serialized type", decoded.type == "TestCmd")
check("serialized playhead_value", decoded.playhead_value == 50)
check("serialized playhead_rate", decoded.playhead_rate == 24)

-- 2b. Table playhead_rate with valid denominator
cmd = Command.create("TestCmd", "proj1")
cmd.playhead_value = 100
cmd.playhead_rate = { fps_numerator = 24000, fps_denominator = 1001 }
cmd.executed_at = os.time()
json_str = cmd:serialize()
decoded = json.decode(json_str)
check("table playhead_rate → numeric", type(decoded.playhead_rate) == "number")
check("table playhead_rate value", math.abs(decoded.playhead_rate - 24000/1001) < 0.001)

-- 2c. Table playhead_rate with zero denominator → error
cmd = Command.create("TestCmd", "proj1")
cmd.playhead_rate = { fps_numerator = 24, fps_denominator = 0 }
expect_error("serialize zero denominator → error", function()
    cmd:serialize()
end, "playhead_rate missing fps_denominator")

-- 2d. Table playhead_rate with nil denominator → error
cmd = Command.create("TestCmd", "proj1")
cmd.playhead_rate = { fps_numerator = 24 }
expect_error("serialize nil denominator → error", function()
    cmd:serialize()
end, "playhead_rate missing fps_denominator")

-- 2e. Table playhead_value (Rational-like) → extracts .frames
cmd = Command.create("TestCmd", "proj1")
cmd.playhead_value = { frames = 77 }
cmd.playhead_rate = 24
cmd.executed_at = os.time()
json_str = cmd:serialize()
decoded = json.decode(json_str)
check("Rational playhead_value.frames extracted", decoded.playhead_value == 77)

-- 2f. Ephemeral parameters excluded
cmd = Command.create("TestCmd", "proj1")
cmd.playhead_value = 0
cmd.playhead_rate = 24
cmd.executed_at = os.time()
cmd:set_parameter("visible_param", "yes")
cmd:set_parameter("__ephemeral", "secret")
json_str = cmd:serialize()
decoded = json.decode(json_str)
check("ephemeral excluded from serialize", decoded.parameters.__ephemeral == nil)
check("visible included in serialize", decoded.parameters.visible_param == "yes")


-- ═══════════════════════════════════════════════════════════════
-- 3. parse_from_query
-- ═══════════════════════════════════════════════════════════════

print("\n--- 3. parse_from_query ---")

-- 3a. nil query → nil
cmd = Command.parse_from_query(nil, "proj1")
check("parse_from_query(nil) → nil", cmd == nil)

-- 3b. Layout 2 (<17 cols) with valid JSON params
local q = mock_query({
    [0] = "cmd_id_1",     -- id
    [1] = "InsertClip",   -- command_type
    [2] = '{"clip_id":"c1","track_id":"t1"}',  -- command_args JSON
    [3] = 1,              -- sequence_number
    [4] = 0,              -- parent_sequence_number
    [5] = "hash_pre",     -- pre_hash
    [6] = "hash_post",    -- post_hash
    [7] = 1000,           -- timestamp / executed_at
    [8] = 50,             -- playhead_value
    [9] = 24,             -- playhead_rate
}, 12)

cmd = Command.parse_from_query(q, "proj1")
check("parse layout2 → command", cmd ~= nil)
check("parse layout2 id", cmd.id == "cmd_id_1")
check("parse layout2 type", cmd.type == "InsertClip")
check("parse layout2 params.clip_id", cmd.parameters.clip_id == "c1")
check("parse layout2 project_id from arg", cmd.project_id == "proj1")
check("parse layout2 playhead_value", cmd.playhead_value == 50)

-- 3c. Layout 2 with invalid JSON → graceful (empty params)
q = mock_query({
    [0] = "cmd_id_2",
    [1] = "DeleteClip",
    [2] = "{corrupted###",
    [3] = 2,
}, 12)

cmd = Command.parse_from_query(q, "proj1")
check("parse bad JSON → command (not nil)", cmd ~= nil)
check("parse bad JSON → empty params", next(cmd.parameters) == nil)
check("parse bad JSON → type preserved", cmd.type == "DeleteClip")

-- 3d. Layout 2 with empty JSON string → empty params
q = mock_query({
    [0] = "cmd_id_3",
    [1] = "NudgeClip",
    [2] = "",
    [3] = 3,
}, 10)

cmd = Command.parse_from_query(q, nil)
check("parse empty JSON → empty params", next(cmd.parameters) == nil)

-- 3e. Layout 1 (17+ cols) with valid JSON
q = mock_query({
    [0] = "cmd_id_4",     -- id
    [1] = "parent_1",     -- parent_id
    [2] = 10,             -- sequence_number
    [3] = "SplitClip",    -- command_type
    [4] = '{"position":42}',  -- command_args
    [5] = 0,              -- parent_sequence_number
    [6] = "pre",          -- pre_hash
    [7] = "post",         -- post_hash
    [8] = 2000,           -- timestamp
    [9] = 99,             -- playhead_value
    [10] = 24,            -- playhead_rate
    [11] = "[]",          -- selected_clip_ids
    [12] = "[]",          -- selected_edge_infos
    [13] = "[]",          -- selected_gap_infos
    [14] = "[]",          -- selected_clip_ids_pre
    [15] = "[]",          -- selected_edge_infos_pre
    [16] = "[]",          -- selected_gap_infos_pre
    [17] = "Executed",    -- status
}, 18)

cmd = Command.parse_from_query(q, "proj1")
check("parse layout1 → command", cmd ~= nil)
check("parse layout1 type", cmd.type == "SplitClip")
check("parse layout1 params.position", cmd.parameters.position == 42)
check("parse layout1 parent_id", cmd.parent_id == "parent_1")
check("parse layout1 playhead_value", cmd.playhead_value == 99)

-- 3f. project_id fallback: nil arg → uses args_table.project_id
q = mock_query({
    [0] = "cmd_id_5",
    [1] = "TestCmd",
    [2] = '{"project_id":"from_args"}',
    [3] = 1,
}, 10)

cmd = Command.parse_from_query(q, nil)
check("parse project_id fallback from args", cmd.project_id == "from_args")

-- 3g. parse_from_query sets metatable (methods available)
check("parsed cmd has :label()", type(cmd.label) == "function")
check("parsed cmd has :serialize()", type(cmd.serialize) == "function")


-- ═══════════════════════════════════════════════════════════════
-- 4. create_undo
-- ═══════════════════════════════════════════════════════════════

print("\n--- 4. create_undo ---")

-- 4a. Undo type = "Undo" .. original type
cmd = Command.create("InsertClip", "proj1", { clip_id = "c1" })
local undo = cmd:create_undo()
check("undo type = UndoInsertClip", undo.type == "UndoInsertClip")
check("undo project_id", undo.project_id == "proj1")
check("undo has clip_id param", undo:get_parameter("clip_id") == "c1")

-- 4b. Ephemeral params NOT copied to undo
cmd = Command.create("DeleteClip", "proj1")
cmd:set_parameter("clip_id", "c2")
cmd:set_parameter("__runtime_cache", { temp = true })
undo = cmd:create_undo()
check("undo excludes __ephemeral", undo:get_parameter("__runtime_cache") == nil)
check("undo includes non-ephemeral", undo:get_parameter("clip_id") == "c2")

-- 4c. Undo gets fresh UUID
check("undo has different id", undo.id ~= cmd.id)


-- ═══════════════════════════════════════════════════════════════
-- 5. save (with real database)
-- ═══════════════════════════════════════════════════════════════

print("\n--- 5. save ---")

local db_path = "/tmp/jve/test_command_error_paths.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

-- Seed project
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d);
]], now, now))

-- 5a. save with nil db and no global connection → false
-- (Can't easily test since database.init already set connection.
--  Instead, test save(nil) which falls through to get_connection — success)

-- 5b. Missing playhead_value → FATAL
cmd = Command.create("TestCmd", "proj1")
cmd.playhead_rate = 24
cmd.executed_at = now
-- playhead_value is nil by default
expect_error("save nil playhead_value → FATAL", function()
    cmd:save(db)
end, "requires playhead_value")

-- 5c. playhead_rate = 0 → FATAL
cmd = Command.create("TestCmd", "proj1")
cmd.playhead_value = 100
cmd.playhead_rate = 0
cmd.executed_at = now
expect_error("save playhead_rate=0 → FATAL", function()
    cmd:save(db)
end, "requires playhead_value")

-- 5d. Missing executed_at → FATAL
cmd = Command.create("TestCmd", "proj1")
cmd.playhead_value = 100
cmd.playhead_rate = 24
-- executed_at is nil by default
expect_error("save nil executed_at → FATAL", function()
    cmd:save(db)
end, "requires executed_at")

-- 5e. Valid save (INSERT path)
cmd = Command.create("InsertClip", "proj1", { clip_id = "c1", track_id = "t1" })
cmd.playhead_value = 50
cmd.playhead_rate = 24
cmd.executed_at = now
cmd.sequence_number = 1
local ok = cmd:save(db)
check("save INSERT → true", ok == true)

-- Verify in DB
local verify = db:prepare("SELECT command_type, command_args, playhead_value FROM commands WHERE id = ?")
assert(verify)
verify:bind_value(1, cmd.id)
assert(verify:exec() and verify:next())
check("saved command_type", verify:value(0) == "InsertClip")
local saved_args = json.decode(verify:value(1))
check("saved params.clip_id", saved_args.clip_id == "c1")
check("saved playhead_value", verify:value(2) == 50)
verify:finalize()

-- 5f. Valid save (UPDATE path — same id, different data)
cmd.playhead_value = 75
cmd:set_parameter("clip_id", "c1_updated")
ok = cmd:save(db)
check("save UPDATE → true", ok == true)

verify = db:prepare("SELECT playhead_value, command_args FROM commands WHERE id = ?")
assert(verify)
verify:bind_value(1, cmd.id)
assert(verify:exec() and verify:next())
check("updated playhead_value", verify:value(0) == 75)
saved_args = json.decode(verify:value(1))
check("updated params.clip_id", saved_args.clip_id == "c1_updated")
verify:finalize()

-- 5g. Table playhead_rate in save → converts to numeric
cmd = Command.create("TestCmd2", "proj1")
cmd.playhead_value = 10
cmd.playhead_rate = { fps_numerator = 30000, fps_denominator = 1001 }
cmd.executed_at = now
cmd.sequence_number = 2
ok = cmd:save(db)
check("save table playhead_rate → true", ok == true)

verify = db:prepare("SELECT playhead_rate FROM commands WHERE id = ?")
assert(verify)
verify:bind_value(1, cmd.id)
assert(verify:exec() and verify:next())
local rate_val = verify:value(0)
check("saved rate ≈ 29.97", math.abs(rate_val - 30000/1001) < 0.01)
verify:finalize()

-- 5h. Ephemeral params excluded from save
cmd = Command.create("TestCmd3", "proj1", { visible = "yes", __hidden = "no" })
cmd.playhead_value = 0
cmd.playhead_rate = 24
cmd.executed_at = now
cmd.sequence_number = 3
ok = cmd:save(db)
check("save with ephemeral → true", ok == true)

verify = db:prepare("SELECT command_args FROM commands WHERE id = ?")
assert(verify)
verify:bind_value(1, cmd.id)
assert(verify:exec() and verify:next())
saved_args = json.decode(verify:value(0))
check("ephemeral excluded from DB", saved_args.__hidden == nil)
check("visible included in DB", saved_args.visible == "yes")
verify:finalize()

-- 5i. Rational playhead_value (table with .frames) → extracts frames
cmd = Command.create("TestCmd4", "proj1")
cmd.playhead_value = { frames = 42 }
cmd.playhead_rate = 24
cmd.executed_at = now
cmd.sequence_number = 4
ok = cmd:save(db)
check("save Rational playhead → true", ok == true)

verify = db:prepare("SELECT playhead_value FROM commands WHERE id = ?")
assert(verify)
verify:bind_value(1, cmd.id)
assert(verify:exec() and verify:next())
check("saved Rational playhead_value = 42", verify:value(0) == 42)
verify:finalize()


-- ═══════════════════════════════════════════════════════════════
-- 6. Parameter management
-- ═══════════════════════════════════════════════════════════════

print("\n--- 6. Parameter management ---")

cmd = Command.create("TestCmd", "proj1")

-- 6a. set_parameter / get_parameter
cmd:set_parameter("key1", "val1")
check("get_parameter", cmd:get_parameter("key1") == "val1")

-- 6b. get nonexistent → nil
check("get nonexistent → nil", cmd:get_parameter("nope") == nil)

-- 6c. set_parameters bulk
cmd:set_parameters({ a = 1, b = 2, c = 3 })
check("set_parameters bulk a", cmd:get_parameter("a") == 1)
check("set_parameters bulk b", cmd:get_parameter("b") == 2)

-- 6d. set_parameters(nil) → no-op
cmd:set_parameters(nil)
check("set_parameters(nil) no-op", cmd:get_parameter("a") == 1)

-- 6e. clear_parameter
cmd:clear_parameter("a")
check("clear_parameter", cmd:get_parameter("a") == nil)
check("other params intact", cmd:get_parameter("b") == 2)

-- 6f. get_all_parameters
local all = cmd:get_all_parameters()
check("get_all_parameters", type(all) == "table" and all.b == 2)

-- 6g. get_persistable_parameters filters __
cmd:set_parameter("__temp", "hidden")
cmd:set_parameter("regular", "shown")
local persistable = cmd:get_persistable_parameters()
check("persistable excludes __temp", persistable.__temp == nil)
check("persistable includes regular", persistable.regular == "shown")


-- ═══════════════════════════════════════════════════════════════
-- 7. label
-- ═══════════════════════════════════════════════════════════════

print("\n--- 7. label ---")

-- 7a. Custom display_label takes priority
cmd = Command.create("InsertClip", "proj1", { display_label = "Custom Label" })
check("custom label", cmd:label() == "Custom Label")

-- 7b. No display_label → falls back to command_labels
cmd = Command.create("InsertClip", "proj1")
local label = cmd:label()
check("label returns string", type(label) == "string" and label ~= "")


-- ═══════════════════════════════════════════════════════════════
-- Summary
-- ═══════════════════════════════════════════════════════════════

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
    print("❌ test_command_error_paths.lua FAILED")
    os.exit(1)
else
    print("✅ test_command_error_paths.lua passed")
end
