-- SQLite3 FFI wrapper for LuaJIT
-- Provides minimal interface matching the API used by command_manager and models

local ffi = require("ffi")

-- SQLite3 C API definitions
ffi.cdef[[
    typedef struct sqlite3 sqlite3;
    typedef struct sqlite3_stmt sqlite3_stmt;

    int sqlite3_open(const char *filename, sqlite3 **ppDb);
    int sqlite3_close(sqlite3 *db);
    int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
    int sqlite3_step(sqlite3_stmt *pStmt);
    int sqlite3_finalize(sqlite3_stmt *pStmt);
    int sqlite3_reset(sqlite3_stmt *pStmt);
    int sqlite3_bind_text(sqlite3_stmt *pStmt, int idx, const char *text, int n, void(*destructor)(void*));
    int sqlite3_bind_int(sqlite3_stmt *pStmt, int idx, int value);
    int sqlite3_bind_int64(sqlite3_stmt *pStmt, int idx, int64_t value);
    int sqlite3_bind_double(sqlite3_stmt *pStmt, int idx, double value);
    int sqlite3_bind_null(sqlite3_stmt *pStmt, int idx);

    const unsigned char *sqlite3_column_text(sqlite3_stmt *pStmt, int iCol);
    int sqlite3_column_int(sqlite3_stmt *pStmt, int iCol);
    int64_t sqlite3_column_int64(sqlite3_stmt *pStmt, int iCol);
    double sqlite3_column_double(sqlite3_stmt *pStmt, int iCol);
    int sqlite3_column_type(sqlite3_stmt *pStmt, int iCol);
    int sqlite3_column_count(sqlite3_stmt *pStmt);

    const char *sqlite3_errmsg(sqlite3 *db);
    int sqlite3_changes(sqlite3 *db);
    int64_t sqlite3_last_insert_rowid(sqlite3 *db);
]]

-- Constants
local SQLITE_OK = 0
local SQLITE_ROW = 100
local SQLITE_DONE = 101
local SQLITE_INTEGER = 1
local SQLITE_FLOAT = 2
local SQLITE_TEXT = 3
local SQLITE_BLOB = 4
local SQLITE_NULL = 5
local SQLITE_TRANSIENT = ffi.cast("void(*)(void*)", -1)

-- Load SQLite library
local sqlite3_lib = ffi.load("/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib")

local M = {}

-- Forward declare Statement for use in Database
local Statement = {}
Statement.__index = Statement

-- Database object
local Database = {}
Database.__index = Database

function M.open(filename)
    local db_ptr = ffi.new("sqlite3*[1]")
    local rc = sqlite3_lib.sqlite3_open(filename, db_ptr)

    if rc ~= SQLITE_OK then
        return nil, "Failed to open database: " .. filename
    end

    local db = setmetatable({
        _db = db_ptr[0],
        _filename = filename,
    }, Database)

    return db
end

function Database:close()
    if self._db ~= nil then
        sqlite3_lib.sqlite3_close(self._db)
        self._db = nil
    end
end

function Database:prepare(sql)
    local stmt_ptr = ffi.new("sqlite3_stmt*[1]")
    local rc = sqlite3_lib.sqlite3_prepare_v2(self._db, sql, #sql, stmt_ptr, nil)

    if rc ~= SQLITE_OK then
        return nil, self:last_error()
    end

    local stmt = setmetatable({
        _stmt = stmt_ptr[0],
        _db = self,
        _current_row = 0,
        _has_row = false,
    }, Statement)

    return stmt
end

function Database:last_error()
    return ffi.string(sqlite3_lib.sqlite3_errmsg(self._db))
end

function Database:changes()
    return sqlite3_lib.sqlite3_changes(self._db)
end

function Database:last_insert_rowid()
    return tonumber(sqlite3_lib.sqlite3_last_insert_rowid(self._db))
end

-- Statement methods (declaration is at top of file)

function Statement:bind_value(index, value)
    local value_type = type(value)
    local rc

    if value == nil then
        rc = sqlite3_lib.sqlite3_bind_null(self._stmt, index)
    elseif value_type == "number" then
        if math.floor(value) == value then
            rc = sqlite3_lib.sqlite3_bind_int64(self._stmt, index, value)
        else
            rc = sqlite3_lib.sqlite3_bind_double(self._stmt, index, value)
        end
    elseif value_type == "string" then
        rc = sqlite3_lib.sqlite3_bind_text(self._stmt, index, value, #value, SQLITE_TRANSIENT)
    elseif value_type == "boolean" then
        rc = sqlite3_lib.sqlite3_bind_int(self._stmt, index, value and 1 or 0)
    else
        error("Unsupported value type: " .. value_type)
    end

    return rc == SQLITE_OK
end

function Statement:exec()
    -- Reset before execution
    sqlite3_lib.sqlite3_reset(self._stmt)
    self._current_row = 0
    self._has_row = false

    -- Execute first step
    local rc = sqlite3_lib.sqlite3_step(self._stmt)

    if rc == SQLITE_ROW then
        self._has_row = true
        return true
    elseif rc == SQLITE_DONE then
        return true
    else
        return false
    end
end

function Statement:next()
    if not self._has_row then
        return false
    end

    -- If this is the first call after exec(), we already have a row
    if self._current_row == 0 then
        self._current_row = 1
        return true
    end

    -- Step to next row
    local rc = sqlite3_lib.sqlite3_step(self._stmt)

    if rc == SQLITE_ROW then
        self._current_row = self._current_row + 1
        return true
    else
        self._has_row = false
        return false
    end
end

function Statement:value(index)
    local col_type = sqlite3_lib.sqlite3_column_type(self._stmt, index)

    if col_type == SQLITE_INTEGER then
        return tonumber(sqlite3_lib.sqlite3_column_int64(self._stmt, index))
    elseif col_type == SQLITE_FLOAT then
        return tonumber(sqlite3_lib.sqlite3_column_double(self._stmt, index))
    elseif col_type == SQLITE_TEXT then
        local text_ptr = sqlite3_lib.sqlite3_column_text(self._stmt, index)
        if text_ptr ~= nil then
            return ffi.string(text_ptr)
        else
            return nil
        end
    elseif col_type == SQLITE_NULL then
        return nil
    else
        return nil
    end
end

function Statement:record()
    return {
        count = function()
            return sqlite3_lib.sqlite3_column_count(self._stmt)
        end
    }
end

function Statement:last_error()
    return self._db:last_error()
end

function Statement:finalize()
    if self._stmt ~= nil then
        sqlite3_lib.sqlite3_finalize(self._stmt)
        self._stmt = nil
    end
end

Statement.__gc = Statement.finalize

return M
