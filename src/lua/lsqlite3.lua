--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~95 LOC
-- Volatility: unknown
--
-- @file lsqlite3.lua
-- Original intent (unreviewed):
-- Lightweight compatibility shim for environments without the native lsqlite3
-- C module. Tries to load the real module first; if unavailable, falls back to
-- a thin wrapper over the existing core.sqlite3 FFI binding.
-- Prefer the native library if it is installed (Lua loader runs before C
-- searchers, so we explicitly ask the C searchers for "lsqlite3").
local function try_native()
    local searchers = package.searchers or package.loaders
    if type(searchers) ~= "table" then
        return nil
    end

    for i = 3, #searchers do
        local loader = searchers[i]
        if type(loader) == "function" then
            local ok, fn_or_err, param = pcall(loader, "lsqlite3")
            if ok and type(fn_or_err) == "function" then
                local ok_open, native = pcall(fn_or_err, param)
                if ok_open and native then
                    return native
                end
            end
        end
    end

    return nil
end

local native = try_native()
if native then
    return native
end

-- Fallback shim
local core = require("core.sqlite3")

local sqlite3 = {
    OK = 0,
    ROW = 100,
    DONE = 101,
    OPEN_READONLY = 1
}

local db_mt = {}
db_mt.__index = db_mt

local stmt_mt = {}
stmt_mt.__index = stmt_mt

function sqlite3.open(path, _flags)
    local db, err = core.open(path)
    if not db then
        return nil, err
    end
    return setmetatable({_db = db}, db_mt)
end

function sqlite3.open_memory()
    return sqlite3.open(":memory:")
end

function db_mt:close()
    if self._db then
        self._db:close()
        self._db = nil
    end
end

function db_mt:prepare(sql)
    local stmt, err = self._db:prepare(sql)
    if not stmt then
        return nil, err
    end
    return setmetatable({
        _stmt = stmt,
        _started = false
    }, stmt_mt)
end

function stmt_mt:bind_value(index, value)
    if not self._stmt then
        return false
    end
    return self._stmt:bind_value(index, value)
end

function stmt_mt:step()
    if not self._stmt then
        return sqlite3.DONE
    end

    if not self._started then
        self._started = true
        local ok = self._stmt:exec()
        if not ok then
            return sqlite3.DONE
        end
        local rc = self._stmt:last_result_code()
        return rc == sqlite3.ROW and sqlite3.ROW or sqlite3.DONE
    end

    local has_next = self._stmt:next()
    return has_next and sqlite3.ROW or sqlite3.DONE
end

function stmt_mt:get_value(index)
    if not self._stmt then
        return nil
    end
    return self._stmt:value(index)
end

function stmt_mt:finalize()
    if self._stmt then
        self._stmt:finalize()
        self._stmt = nil
    end
end

return sqlite3
