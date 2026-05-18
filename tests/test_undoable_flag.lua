#!/usr/bin/env luajit

-- T005 (015) — Smoke test: SPEC.undoable = false already works in command_manager.
--
-- Domain: a command with SPEC.undoable = false must not leave a revertible
-- entry on the undo stack. After execution, Cmd-Z must be a no-op for that
-- command (prior state NOT restored).
--
-- Expected PASS today — the mechanism exists in command_manager.lua.
-- Characterizes existing behavior before new 015 commands depend on it.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local registry = require("core.command_registry")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_undoable_flag.lua ===")

local DB = "/tmp/jve/test_undoable_flag.db"
os.remove(DB)
os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'BEFORE', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d)
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('seq', 'proj', 'S', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))

command_manager.init("seq", "proj")

-- ── Register a minimal test command with SPEC.undoable = false ────────────
local undoer_called = false
registry.register_executor(
    "TestNonUndoableCmd",
    function(command)
        local args = command:get_all_parameters()
        local stmt = db:prepare("UPDATE projects SET name = ? WHERE id = 'proj'")
        assert(stmt, "prepare failed")
        stmt:bind_value(1, args.new_name)
        stmt:exec(); stmt:finalize()
        return true
    end,
    function(_command)
        undoer_called = true   -- must never fire
        return true
    end,
    {
        undoable = false,
        args = {
            new_name = { required = true, kind = "string" },
        },
    }
)

-- ── Execute ───────────────────────────────────────────────────────────────
local r = command_manager.execute("TestNonUndoableCmd", {
    new_name   = "AFTER",
    project_id = "proj",
})
assert(r and r.success, string.format(
    "TestNonUndoableCmd execute failed: %s", tostring(r and r.error_message)))
print("  execute: succeeded")

local function read_name()
    local s = db:prepare("SELECT name FROM projects WHERE id = 'proj'")
    assert(s); s:exec(); s:next(); local v = s:value(0); s:finalize(); return v
end

assert(read_name() == "AFTER",
    "projects.name must be 'AFTER' after exec, got: " .. tostring(read_name()))
print("  side effect landed: name='AFTER'")

-- ── Undo must be a no-op ──────────────────────────────────────────────────
command_manager.undo()
assert(not undoer_called,
    "FAIL: undoer was called for SPEC.undoable=false command")
assert(read_name() == "AFTER",
    "FAIL: undo reverted the change — SPEC.undoable=false not respected; got: "
    .. tostring(read_name()))
print("  undo is no-op: name still 'AFTER'")

print("\n✅ test_undoable_flag.lua passed")
