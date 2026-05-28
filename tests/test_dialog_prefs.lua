-- Verifies core/dialog_prefs fail-fast contracts (replaces 3x copy-paste
-- with `json.decode(raw) or {}` silent corruption-eats-state pattern).

require("test_env")

local dialog_prefs = require("core.dialog_prefs")

local TMPDIR = "/tmp/jve/dialog_prefs_test"
os.execute("mkdir -p " .. TMPDIR)

local function write_file(path, contents)
    local f = assert(io.open(path, "w"))
    f:write(contents)
    f:close()
end

local function unlink(path) os.remove(path) end

-- 1. Missing file → empty table (legitimate first-run).
do
    local path = TMPDIR .. "/missing.json"
    unlink(path)
    local s = dialog_prefs.load(path)
    assert(type(s) == "table" and next(s) == nil,
        "missing file must return empty table")
end

-- 2. Empty file → empty table (zero-length write recovers).
do
    local path = TMPDIR .. "/empty.json"
    write_file(path, "")
    local s = dialog_prefs.load(path)
    assert(type(s) == "table" and next(s) == nil,
        "empty file must return empty table")
end

-- 3. Valid JSON round-trips.
do
    local path = TMPDIR .. "/valid.json"
    dialog_prefs.save(path, { foo = "bar", n = 42, list = { 1, 2, 3 } })
    local s = dialog_prefs.load(path)
    assert(s.foo == "bar", "foo round-trip")
    assert(s.n == 42, "n round-trip")
    assert(#s.list == 3 and s.list[2] == 2, "list round-trip")
end

-- 4. Corrupt JSON must assert (NOT silently reset like the old `or {}`).
do
    local path = TMPDIR .. "/corrupt.json"
    write_file(path, "{not valid json")
    local ok, err = pcall(dialog_prefs.load, path)
    assert(not ok, "corrupt JSON must assert, not silently return {}")
    assert(err:match("failed to parse"),
        "assert message must say 'failed to parse', got: " .. tostring(err))
end

-- 5. JSON that decodes to a non-table (e.g. a bare string) must assert.
do
    local path = TMPDIR .. "/scalar.json"
    write_file(path, '"just a string"')
    local ok, err = pcall(dialog_prefs.load, path)
    assert(not ok, "scalar JSON must assert (settings must be a table)")
    assert(err:match("failed to parse"),
        "scalar-json assert must mention parse failure, got: " .. tostring(err))
end

-- 6. save() requires a table; passing nil/scalar asserts.
do
    local path = TMPDIR .. "/whatever.json"
    local ok = pcall(dialog_prefs.save, path, nil)
    assert(not ok, "save(nil) must assert")
    local ok2 = pcall(dialog_prefs.save, path, "not a table")
    assert(not ok2, "save(string) must assert")
end

-- 7. path_for builds under ~/.jve.
do
    local p = dialog_prefs.path_for("test_dialog_settings.json")
    assert(p:match("/%.jve/test_dialog_settings%.json$"),
        "path_for must return ~/.jve/<filename>, got: " .. p)
end

print("✅ test_dialog_prefs.lua passed")
