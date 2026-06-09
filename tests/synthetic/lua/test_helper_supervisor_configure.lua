-- helper_supervisor.configure asserts (spec 023, MED #3).
-- Black-box: configure must reject missing/blank/nonexistent paths
-- at app-start so the first menu click doesn't surface a downstream
-- qt_process_start "no such file" error (rule 1.14 fail-fast).

require("test_env")

local supervisor = require("core.resolve_bridge.helper_supervisor")

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== helper_supervisor.configure asserts ===")

-- Blank path rejected.
local ok = pcall(supervisor.configure, "")
check("blank helper_script_path rejected", not ok)

-- Nil path rejected.
ok = pcall(supervisor.configure, nil)
check("nil helper_script_path rejected", not ok)

-- Nonexistent path rejected with a useful message.
local ok2, err = pcall(supervisor.configure,
    "/nonexistent/path/helper.py")
check("nonexistent helper_script_path rejected", not ok2)
check("error message names the bad path",
    err and err:find("/nonexistent/path/helper.py", 1, true) ~= nil)
check("error message hints at canonical locations",
    err and (err:find("tools/resolve-helper", 1, true) ~= nil
        or err:find("Contents/Resources/resolve-helper", 1, true) ~= nil))

-- Existing path accepted. The real helper.py is at
-- tools/resolve-helper/helper.py — but we want this test to be
-- standalone of layout.lua's discovery, so we use a temp file we
-- create here.
local tmp = "/tmp/jve_test_supervisor_configure.py"
local f = assert(io.open(tmp, "w"))
f:write("# placeholder\n")
f:close()
local ok3 = pcall(supervisor.configure, tmp)
check("existing helper_script_path accepted", ok3)
os.remove(tmp)

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_helper_supervisor_configure.lua: failures present")
print("✅ test_helper_supervisor_configure.lua passed")
