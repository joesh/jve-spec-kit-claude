local function read_file(path)
    local file, err = io.open(path, "r")
    assert(file, "Failed to open " .. tostring(path) .. ": " .. tostring(err))
    local content = file:read("*all")
    file:close()
    return content
end

local schema_sql = read_file("../src/core/persistence/schema.sql")

-- Stock SQLite (e.g. /usr/bin/sqlite3 on macOS) requires the RAISE() error message
-- in triggers to be a string literal. Do not use concatenation like:
--   RAISE(ABORT, 'msg=' || NEW.column)
assert(
    not schema_sql:match("RAISE%(%s*[%u%l_]+%s*,%s*'[^']*'%s*%|%|"),
    "schema.sql uses a concatenated RAISE() message; use a string literal for portability"
)

