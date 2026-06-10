--- Batch: timeline render tests against the real app (no stubs).
-- One JVEEditor process; render_env boots the app + fixture media once,
-- each test isolates itself with a fresh sequence. Discovers
-- timeline_render/test_*.lua siblings dynamically.
local runner = require("synthetic.integration.batch_runner")
local dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") .. "/timeline_render"

local tests = {}
local h = assert(io.popen("ls " .. dir .. "/test_*.lua 2>/dev/null"))
for path in h:lines() do
    local name = path:match("([^/]+)$")
    if name then tests[#tests + 1] = name end
end
h:close()
assert(#tests > 0, "batch_timeline_render: no tests found in " .. dir)

local _, failed = runner.run("timeline_render", runner.resolve_paths(dir, tests))
assert(failed == 0, string.format("batch_timeline_render: %d test(s) failed", failed))
