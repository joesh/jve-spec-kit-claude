#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua"

-- Preserve original modules/functions so other tests remain unaffected.
local original_sqlite3 = package.loaded["core.sqlite3"]
local original_event_log = package.loaded["core.event_log"]
local original_os_remove = os.remove
local original_io_popen = io.popen

local open_calls = 0
local removed_paths = {}

-- Stub os.remove so we can assert the cleanup behaviour without touching real files.
os.remove = function(path)
    table.insert(removed_paths, path)
    return true
end

-- Prevent macl detection from running external commands inside the test.
io.popen = function()
    return nil
end

-- Minimal event log stub
package.loaded["core.event_log"] = {
    init = function() end
}

-- Create a mock sqlite3 handle that pretends tag tables exist.
local function make_stmt(sql)
    local has_row = sql:find("tag") ~= nil
    local stmt = {
        _returned = false,
        exec = function() return true end,
        next = function(self)
            if has_row and not self._returned then
                self._returned = true
                return true
            end
            return false
        end,
        value = function() return nil end,
        bind_value = function() end,
        clear_bindings = function() end,
        finalize = function() end
    }
    return stmt
end

local mock_db = {
    busy_timeout = function() end,
    exec = function() return true end,
    close = function() end,
    prepare = function(_, sql) return make_stmt(sql) end,
    last_error = function() return "mock error" end
}

package.loaded["core.sqlite3"] = {
    open = function(path)
        open_calls = open_calls + 1
        if open_calls == 1 then
            return nil, "disk I/O error"
        end
        return mock_db
    end
}

local database = require("core.database")

local ok = database.set_path("/tmp/jve/test_wal_cleanup.db")
assert(ok, "database.set_path should succeed after cleaning WAL/SHM files")
assert(open_calls == 2, "sqlite3.open must be retried after cleanup")
assert(removed_paths[1] == "/tmp/jve/test_wal_cleanup.db-wal", "first cleanup target should be WAL file")
assert(removed_paths[2] == "/tmp/jve/test_wal_cleanup.db-shm", "second cleanup target should be SHM file")

print("✅ WAL/SHM cleanup logic exercised successfully")

-- Restore globals/modules for safety.
os.remove = original_os_remove
io.popen = original_io_popen
package.loaded["core.sqlite3"] = original_sqlite3
package.loaded["core.event_log"] = original_event_log
