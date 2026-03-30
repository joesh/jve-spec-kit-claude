-- Regression: stock SQLite (macOS /usr/bin/sqlite3) requires RAISE() error
-- messages to be string literals. Concatenation like RAISE(ABORT, 'msg=' || col)
-- compiles in our bundled SQLite but fails on stock builds.

require("test_env")

local function read_file(path)
    local file, err = io.open(path, "r")
    assert(file, "Failed to open " .. tostring(path) .. ": " .. tostring(err))
    local content = file:read("*all")
    file:close()
    return content
end

local schema_sql = read_file("../src/lua/schema.sql")

assert(
    not schema_sql:match("RAISE%(%s*[%u%l_]+%s*,%s*'[^']*'%s*%|%|"),
    "schema.sql uses a concatenated RAISE() message; use a string literal for portability"
)

-- Also verify the schema actually executes without errors on our SQLite build
local database = require("core.database")
local db_path = "/tmp/jve/test_schema_portability.db"
os.remove(db_path)
assert(database.init(db_path), "schema.sql failed to execute against database")

print("✅ test_schema_sql_portability.lua passed")
