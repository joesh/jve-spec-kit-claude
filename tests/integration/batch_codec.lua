--- Batch: codec/media integration tests (single JVEEditor process).
local runner = require("integration.batch_runner")
local dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$")

local _, failed = runner.run("codec", runner.resolve_paths(dir, {
    "test_braw_decode.lua",
    "test_tmb_qtrle_stride.lua",
    "test_tmb_qtrle_prefetch.lua",
    "test_tmb_sw_scaling.lua",
}))

assert(failed == 0, string.format("batch_codec: %d test(s) failed", failed))
