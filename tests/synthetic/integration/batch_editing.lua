--- Batch: editing operation integration tests (single JVEEditor process).
-- Runs sequentially — each test manages its own DB lifecycle.
local runner = require("synthetic.integration.batch_runner")
local dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$")

-- test_editor_operations must run first — it opens a fresh DB copy.
-- test_tmb_mute_exclusion creates its own DB but may leave module state.
local _, failed = runner.run("editing", runner.resolve_paths(dir, {
    "test_editor_operations.lua",
    "test_tmb_mute_exclusion.lua",
}))

assert(failed == 0, string.format("batch_editing: %d test(s) failed", failed))
