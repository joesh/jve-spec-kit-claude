--- Batch: ALL binding tests in a single long-lived JVEEditor process.
-- Mirrors tests/synthetic/integration/batch_runner usage in batch_playback.lua etc.
-- Discovers test_*.lua siblings dynamically (no manual list to drift).
-- Skips SLOW_TEST-tagged tests unless RUN_SLOW_TESTS=1, matching the old
-- per-test runner's behavior.

local runner = require("synthetic.integration.batch_runner")
local dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$")

local run_slow = os.getenv("RUN_SLOW_TESTS") == "1"

local function is_slow(path)
    local h = io.open(path, "r")
    if not h then return false end
    for _ = 1, 3 do
        local line = h:read("*l")
        if not line then break end
        if line:find("SLOW_TEST", 1, true) then h:close(); return true end
    end
    h:close()
    return false
end

local tests = {}
local h = assert(io.popen("ls " .. dir .. "/test_*.lua 2>/dev/null"))
for path in h:lines() do
    local name = path:match("([^/]+)$")
    if name and not name:match("^batch_") then
        if run_slow or not is_slow(path) then
            tests[#tests + 1] = name
        end
    end
end
h:close()
table.sort(tests)

assert(#tests > 0, "batch_binding: no test_*.lua siblings found in " .. dir)

local _, failed = runner.run("binding", runner.resolve_paths(dir, tests))
assert(failed == 0,
    string.format("batch_binding: %d test(s) failed", failed))
