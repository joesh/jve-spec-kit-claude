#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua"

-- Preserve original modules/functions so other tests remain unaffected.
local original_sqlite3 = package.loaded["core.sqlite3"]
local original_database = package.loaded["core.database"]
local original_os_remove = os.remove
local original_io_popen = io.popen

-- Unload database so we get a fresh instance that uses our mock sqlite3
package.loaded["core.database"] = nil

local open_calls = 0
local removed_paths = {}

-- Stub os.remove so we can assert the cleanup behaviour without touching real files.
os.remove = function(path) -- luacheck: ignore 122
    table.insert(removed_paths, path)
    return true
end

-- Prevent macl detection from running external commands inside the test.
io.popen = function() -- luacheck: ignore 122
    return nil
end

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
assert(not ok, "database.set_path should fail on disk I/O error (no implicit WAL/SHM cleanup fallbacks)")
assert(open_calls == 1, "sqlite3.open must not be retried implicitly after disk I/O error")
assert(#removed_paths == 0, "database.set_path must not delete WAL/SHM sidecars implicitly")

print("✅ database.set_path does not perform implicit WAL/SHM cleanup fallbacks")

-- Restore globals/modules for safety.
os.remove = original_os_remove -- luacheck: ignore 122
io.popen = original_io_popen -- luacheck: ignore 122
package.loaded["core.sqlite3"] = original_sqlite3
package.loaded["core.database"] = original_database
