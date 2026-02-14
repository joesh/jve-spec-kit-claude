require('test_env')

-- Regression: command_registry.module_path_for("Undo") stripped the "Undo" prefix,
-- leaving empty string, and tried to load "core.commands." (no filename).
-- The literal command "Undo" should load "core.commands.undo", not be treated as
-- an undo-variant of a base command.

print("=== Test command_registry Undo/Redo module loading ===")

local import_schema = require("import_schema")
local database = require("core.database")

-- Set up DB (command_registry.init needs a db)
local db_path = "/tmp/jve/test_command_registry_undo_load.db"
os.remove(db_path)
os.remove(db_path .. "-wal")
os.remove(db_path .. "-shm")
assert(database.set_path(db_path))
local db = database.get_connection()
assert(db:exec(import_schema))

local command_registry = require("core.command_registry")
command_registry.init(db, function() end)

-- Test 1: "Undo" command loads successfully
print("\nTest 1: Undo command module loads")
local loaded = command_registry.load_command_module("Undo")
assert(loaded, "Undo command module should load")
local executor = command_registry.get_executor("Undo")
assert(executor, "Undo executor should be registered")
local spec = command_registry.get_spec("Undo")
assert(spec, "Undo spec should be registered")
print("  ✓ Undo module loaded, executor and spec registered")

-- Test 2: "Redo" command loads successfully
print("\nTest 2: Redo command module loads")
loaded = command_registry.load_command_module("Redo")
assert(loaded, "Redo command module should load")
executor = command_registry.get_executor("Redo")
assert(executor, "Redo executor should be registered")
spec = command_registry.get_spec("Redo")
assert(spec, "Redo spec should be registered")
print("  ✓ Redo module loaded, executor and spec registered")

-- Test 3: "UndoInsert" still loads Insert's module (not treated as literal "UndoInsert")
print("\nTest 3: UndoInsert loads Insert module")
loaded = command_registry.load_command_module("UndoInsert")
assert(loaded, "UndoInsert should load Insert's module")
-- After loading UndoInsert, the Insert executor should be registered
local insert_executor = command_registry.get_executor("Insert")
assert(insert_executor, "Insert executor should be registered after loading UndoInsert")
print("  ✓ UndoInsert loads Insert module correctly")

-- Test 4: Undo executor is a callable function (not just non-nil)
print("\nTest 4: Undo executor is callable")
executor = command_registry.get_executor("Undo")
assert(type(executor) == "function",
    "Undo executor should be a function, got " .. type(executor))
print("  ✓ Undo executor is type 'function'")

-- Test 5: Nonexistent undo-variant fails to load (error path)
print("\nTest 5: UndoNonexistent fails to load")
loaded = command_registry.load_command_module("UndoNonexistentCommand99")
assert(loaded == false, "UndoNonexistentCommand99 should fail to load")
print("  ✓ UndoNonexistentCommand99 correctly failed to load")

-- Test 6: Redo executor is also callable
print("\nTest 6: Redo executor is callable")
executor = command_registry.get_executor("Redo")
assert(type(executor) == "function",
    "Redo executor should be a function, got " .. type(executor))
print("  ✓ Redo executor is type 'function'")

print("\n✅ test_command_registry_undo_load.lua passed")
