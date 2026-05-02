--- Batch: waveform/peak integration tests (single JVEEditor process).
-- test_waveform_end_to_end must run before test_peak_drift_regression
-- (generates peak files used by later tests).
local runner = require("integration.batch_runner")
local dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$")

local _, failed = runner.run("waveform", runner.resolve_paths(dir, {
    "test_waveform_end_to_end.lua",
    "test_waveform_alignment.lua",
    "test_peak_drift_regression.lua",
    "test_relink_invalidates_peaks.lua",
}))

assert(failed == 0, string.format("batch_waveform: %d test(s) failed", failed))
