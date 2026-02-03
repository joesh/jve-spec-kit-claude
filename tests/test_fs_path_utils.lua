require("test_env")

local fs_utils = require("core.fs_utils")
local path_utils = require("core.path_utils")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

local function expect_error(label, fn, pattern)
    local ok, err = pcall(fn)
    if not ok then
        if pattern and not tostring(err):match(pattern) then
            fail_count = fail_count + 1
            print("FAIL (wrong error): " .. label .. " got: " .. tostring(err))
        else
            pass_count = pass_count + 1
        end
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
    end
end

print("\n=== FS Utils + Path Utils Tests (T22) ===")

-- ============================================================
-- fs_utils.file_exists
-- ============================================================
print("\n--- fs_utils.file_exists ---")
do
    -- Existing file (this test file itself)
    local this_test = debug.getinfo(1, "S").source:sub(2)  -- strip leading @
    check("existing file", fs_utils.file_exists(this_test) == true)

    -- Nonexistent file
    check("nonexistent file", fs_utils.file_exists("/tmp/jve/no_such_file_ever_12345.txt") == false)

    -- nil → false
    check("nil path", fs_utils.file_exists(nil) == false)

    -- Empty string → false
    check("empty path", fs_utils.file_exists("") == false)

    -- Directory path (io.open on dirs may vary by OS, but on macOS/Linux it opens)
    -- We just verify it doesn't crash
    local dir_result = fs_utils.file_exists("/tmp")
    check("directory no crash", dir_result == true or dir_result == false)

    -- Custom mode parameter
    -- Create a temp file to test with "r" mode
    local tmp = "/tmp/jve/test_fs_utils_temp.txt"
    local f = io.open(tmp, "w")
    if f then
        f:write("test")
        f:close()
        check("custom mode r", fs_utils.file_exists(tmp, "r") == true)
        os.remove(tmp)
    else
        check("custom mode r", true)  -- skip if can't create
    end

    -- File removed → false
    check("removed file", fs_utils.file_exists(tmp) == false)
end

-- ============================================================
-- path_utils.resolve_repo_root
-- ============================================================
print("\n--- path_utils.resolve_repo_root ---")
do
    local root = path_utils.resolve_repo_root()
    check("root is string", type(root) == "string")
    check("root is non-empty", root ~= "")
    -- Root should end without trailing slash
    check("root no trailing slash", root:sub(-1) ~= "/")
    -- Root should contain the project (we know core.database exists)
    local db_path = root .. "/src/lua/core/database.lua"
    check("root points to project", fs_utils.file_exists(db_path))
end

-- ============================================================
-- path_utils.resolve_repo_path — absolute paths
-- ============================================================
print("\n--- path_utils.resolve_repo_path absolute ---")
do
    -- Absolute Unix path → pass through
    check("absolute unix", path_utils.resolve_repo_path("/usr/bin/lua") == "/usr/bin/lua")

    -- Absolute Windows path → pass through
    check("absolute windows", path_utils.resolve_repo_path("C:/Users/test") == "C:/Users/test")
    check("absolute windows backslash", path_utils.resolve_repo_path("C:\\Users\\test") == "C:\\Users\\test")
end

-- ============================================================
-- path_utils.resolve_repo_path — relative paths
-- ============================================================
print("\n--- path_utils.resolve_repo_path relative ---")
do
    local root = path_utils.resolve_repo_root()

    -- Simple relative path
    local resolved = path_utils.resolve_repo_path("src/lua/core/pipe.lua")
    check("relative simple", resolved == root .. "/src/lua/core/pipe.lua")

    -- Relative with leading slash stripped
    local resolved2 = path_utils.resolve_repo_path("/src/lua/core/pipe.lua")
    -- This is absolute (starts with /), so it passes through
    check("leading slash is absolute", resolved2 == "/src/lua/core/pipe.lua")

    -- Relative without leading slash
    local resolved3 = path_utils.resolve_repo_path("README.md")
    check("relative file", resolved3 == root .. "/README.md")
end

-- ============================================================
-- path_utils.resolve_repo_path — edge cases
-- ============================================================
print("\n--- path_utils.resolve_repo_path edge cases ---")
do
    -- nil → nil
    check("nil path", path_utils.resolve_repo_path(nil) == nil)

    -- Empty string → empty string
    check("empty path", path_utils.resolve_repo_path("") == "")
end

-- ============================================================
-- is_absolute_path (tested indirectly via resolve_repo_path)
-- ============================================================
print("\n--- is_absolute_path coverage ---")
do
    local root = path_utils.resolve_repo_root()

    -- Not absolute → gets repo root prepended
    local rel = path_utils.resolve_repo_path("foo/bar.lua")
    check("relative detected", rel == root .. "/foo/bar.lua")

    -- Drive letter variations
    check("D: drive", path_utils.resolve_repo_path("D:/path") == "D:/path")
    check("d: lowercase", path_utils.resolve_repo_path("d:\\path") == "d:\\path")
end

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n=== FS+Path Utils: %d passed, %d failed ===", pass_count, fail_count))
if fail_count > 0 then
    os.exit(1)
end
print("✅ test_fs_path_utils.lua passed")
