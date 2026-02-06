--- Test: command_manager.end_undo_group propagates commit errors
-- Regression: pcall swallowed db_module.commit() failures
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end

-- We need to test end_undo_group's commit path.
-- Strategy: mock the database module and history module to control the flow.

-- Mock history module
local current_group_id = "group_42"
local group_ended = false
package.loaded["core.command_history"] = {
    begin_undo_group = function(label) return current_group_id end,
    end_undo_group = function()
        group_ended = true
        local gid = current_group_id
        current_group_id = nil  -- simulate outermost group closing
        return gid
    end,
    get_current_undo_group_id = function()
        return current_group_id
    end,
}

-- Mock database module
local commit_should_fail = false
package.loaded["core.database"] = {
    savepoint = function(name) return true end,
    release_savepoint = function(name) end,
    commit = function()
        if commit_should_fail then
            error("disk I/O error: database is locked")
        end
    end,
    get_connection = function() return {} end,
    init = function() return true end,
}

-- Mock logger to suppress output
package.loaded["core.logger"] = {
    info = function() end,
    debug = function() end,
    warn = function() end,
    error = function() end,
    trace = function() end,
    fatal = function() end,
    set_level = function() end,
}

-- Mock other deps command_manager needs
package.loaded["core.command_registry"] = {
    init = function() end,
    get_executor = function() return nil end,
}
package.loaded["core.command_schema"] = {
    apply_rules = function(_, params) return params end,
}

-- Now load command_manager
local command_manager = require("core.command_manager")

-- Test 1: commit failure propagates as error
commit_should_fail = true
current_group_id = "group_42"
group_ended = false

-- begin_undo_group to set up state
command_manager.begin_undo_group("test group")

-- end_undo_group should propagate the commit error
local ok, err = pcall(function()
    command_manager.end_undo_group()
end)

check("commit error propagates", not ok)
check("error message contains original error", err and tostring(err):find("disk I/O error") ~= nil)

-- Test 2: savepoint release failure also propagates
commit_should_fail = false
current_group_id = "group_99"

-- Make release_savepoint fail
package.loaded["core.database"].release_savepoint = function(name)
    error("savepoint does not exist: " .. name)
end

command_manager.begin_undo_group("test group 2")

local ok2, err2 = pcall(function()
    command_manager.end_undo_group()
end)

check("savepoint release error propagates", not ok2)
check("error message contains savepoint info", err2 and tostring(err2):find("savepoint") ~= nil)

if failed > 0 then
    print(string.format("❌ test_commit_failure_propagates.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_commit_failure_propagates.lua passed (%d assertions)", passed))
