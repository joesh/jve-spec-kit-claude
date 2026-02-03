require("test_env")

-- Stub logger before requiring project_open
package.loaded["core.logger"] = {
    info = function() end,
    debug = function() end,
    warn = function() end,
    error = function() end,
}
-- Stub time_utils (required by project_open but unused in our paths)
package.loaded["core.time_utils"] = {}

local project_open = require("core.project_open")

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

print("\n=== Project Open Tests (T20) ===")

-- ============================================================
-- Validation — missing db_module
-- ============================================================
print("\n--- validation ---")
do
    expect_error("nil db_module", function()
        project_open.open_project_database_or_prompt_cleanup(nil, nil, "/tmp/test.jvp", nil)
    end, "db_module.set_path is required")

    expect_error("db_module without set_path", function()
        project_open.open_project_database_or_prompt_cleanup({}, nil, "/tmp/test.jvp", nil)
    end, "db_module.set_path is required")

    expect_error("nil project_path", function()
        project_open.open_project_database_or_prompt_cleanup({set_path = function() end}, nil, nil, nil)
    end, "project_path is required")

    expect_error("empty project_path", function()
        project_open.open_project_database_or_prompt_cleanup({set_path = function() end}, nil, "", nil)
    end, "project_path is required")
end

-- ============================================================
-- Successful open — db_module.set_path returns true
-- ============================================================
print("\n--- successful open ---")
do
    local set_path_called_with = nil
    local mock_db = {
        set_path = function(path)
            set_path_called_with = path
            return true
        end
    }

    -- Use a path where no SHM file exists
    local test_path = "/tmp/jve/test_project_open_" .. os.time() .. ".jvp"
    local result = project_open.open_project_database_or_prompt_cleanup(mock_db, nil, test_path, nil)

    check("returns true on success", result == true)
    check("set_path called with correct path", set_path_called_with == test_path)
end

-- ============================================================
-- Failed open — db_module.set_path returns false/nil
-- ============================================================
print("\n--- failed open ---")
do
    local mock_db = {
        set_path = function(path)
            return false
        end
    }

    local result = project_open.open_project_database_or_prompt_cleanup(mock_db, nil, "/tmp/jve/fake.jvp", nil)
    check("returns false on failure", result == false)
end

do
    local mock_db = {
        set_path = function(path)
            return nil
        end
    }

    local result = project_open.open_project_database_or_prompt_cleanup(mock_db, nil, "/tmp/jve/fake2.jvp", nil)
    check("returns false on nil", result == false)
end

-- ============================================================
-- SHM cleanup — stale SHM file removed before open
-- ============================================================
print("\n--- stale SHM cleanup ---")
do
    local test_path = "/tmp/jve/test_project_open_shm.jvp"
    local shm_path = test_path .. "-shm"

    -- Create a fake SHM file (no process holds it → stale)
    local f = io.open(shm_path, "w")
    if f then
        f:write("stale shm data")
        f:close()

        local set_path_called = false
        local mock_db = {
            set_path = function(path)
                set_path_called = true
                -- By the time set_path is called, SHM should be removed
                local shm_still_exists = io.open(shm_path, "rb")
                if shm_still_exists then
                    shm_still_exists:close()
                    return "shm_not_removed"
                end
                return true
            end
        }

        local result = project_open.open_project_database_or_prompt_cleanup(mock_db, nil, test_path, nil)
        check("stale SHM: set_path called", set_path_called)
        check("stale SHM: returns true", result == true)
        -- SHM file should be gone
        local shm_check = io.open(shm_path, "rb")
        check("stale SHM: file removed", shm_check == nil)
        if shm_check then shm_check:close() end

        -- Cleanup
        os.remove(test_path)
    else
        print("SKIP: Could not create SHM test file")
    end
end

-- ============================================================
-- No SHM file — opens normally
-- ============================================================
print("\n--- no SHM file ---")
do
    local test_path = "/tmp/jve/test_project_open_no_shm_" .. os.time() .. ".jvp"
    -- Ensure no SHM exists
    os.remove(test_path .. "-shm")

    local mock_db = { set_path = function() return true end }
    local result = project_open.open_project_database_or_prompt_cleanup(mock_db, nil, test_path, nil)
    check("no SHM: opens normally", result == true)
end

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n=== Project Open: %d passed, %d failed ===", pass_count, fail_count))
if fail_count > 0 then
    os.exit(1)
end
print("✅ test_project_open.lua passed")
