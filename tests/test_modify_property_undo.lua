-- Regression: ModifyProperty and SetProperty call Property APIs that don't exist.
-- ModifyProperty calls Property.load(entity_id, db) — no such method.
-- SetProperty calls Property.create(property_name, entity_id) — no such method.
-- Both would crash immediately if invoked.
--
-- The REAL property command is SetClipProperty (tested in test_set_clip_property.lua).
-- This test documents that these dead commands are indeed broken.

require("test_env")

local Property = require("models.property")

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

print("\n=== ModifyProperty / SetProperty Dead Command Tests ===")

-- Verify the Property model does NOT have the methods these commands call
check("Property.load does not exist", Property.load == nil)
check("Property.create does not exist", Property.create == nil)

-- Verify the methods that DO exist
check("Property.load_for_clip exists", type(Property.load_for_clip) == "function")
check("Property.save_for_clip exists", type(Property.save_for_clip) == "function")
check("Property.copy_for_clip exists", type(Property.copy_for_clip) == "function")
check("Property.delete_for_clip exists", type(Property.delete_for_clip) == "function")
check("Property.delete_by_ids exists", type(Property.delete_by_ids) == "function")

-- Verify the commands themselves would fail when called
local modify_property = require("core.commands.modify_property")
check("modify_property module loads", modify_property ~= nil)

-- Simulate command registration to verify executor crashes
local executors = {}
local undoers = {}
local database = require("core.database")
local db_path = "/tmp/jve/test_dead_property_cmds.db"
os.remove(db_path)
database.init(db_path)
local db = database.get_connection()

local last_error = nil -- luacheck: ignore 231
local function set_last_error(msg) last_error = msg end

modify_property.register(executors, undoers, db, set_last_error)
check("ModifyProperty executor registered", executors["ModifyProperty"] ~= nil)
check("ModifyProperty has NO undoer", undoers["ModifyProperty"] == nil)

-- Calling the executor should crash (Property.load doesn't exist)
local mock_command = {
    get_all_parameters = function()
        return {entity_id = "fake", entity_type = "clip", property_name = "volume", value = 0.5}
    end,
    set_parameter = function() end,
}
local ok, err = pcall(executors["ModifyProperty"], mock_command)
check("ModifyProperty crashes (Property.load missing)", not ok)
check("error mentions nil/call", tostring(err):match("nil") ~= nil or tostring(err):match("call") ~= nil)

-- Same for SetProperty
local set_property = require("core.commands.set_property")
local sp_executors = {}
set_property.register(sp_executors, {}, db, set_last_error)
check("SetProperty executor registered", sp_executors["SetProperty"] ~= nil)

ok = pcall(sp_executors["SetProperty"], mock_command)
check("SetProperty crashes (Property.create missing)", not ok)

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("✅ test_modify_property_undo.lua passed")
