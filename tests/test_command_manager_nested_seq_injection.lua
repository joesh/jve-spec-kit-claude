#!/usr/bin/env luajit

-- 015 F2: execute_interactive injects source_sequence_id from
-- effective_source ONLY for commands whose SPEC declares that arg.
-- Without spec gating, every command call would receive the param and
-- command_schema would reject it as "unknown param" — surfaced as a UI
-- error on first browser click (regression reported 2026-05-12).
--
-- Domain behavior under test:
--   T1: dispatch a command whose SPEC does NOT declare source_sequence_id
--       (SelectBrowserItems). Must succeed even when effective_source has
--       a value — no injection should happen, so no schema rejection.
--   T2: dispatch a command whose SPEC declares source_sequence_id but
--       caller omits it (a hypothetical Insert path). Verified indirectly
--       by the existing F10/Overwrite test plumbing — this test focuses
--       on the negative case that broke browser clicks.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local Signals         = require("core.signals")
-- Require effective_source eagerly so its source_loaded_changed
-- subscription is registered BEFORE the test emits that signal.
local effective       = require("core.effective_source")

_G.qt_create_single_shot_timer = function(_d, cb) cb(); return nil end

print("=== test_command_manager_nested_seq_injection.lua ===")

local DB = "/tmp/jve/test_command_manager_nested_seq_injection.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', %d, %d)
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('seq', 'proj', 'S', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))

command_manager.init("seq", "proj")

-- Prime effective_source with a non-nil value so the bug would trip if
-- injection were unconditional.
Signals.emit("source_loaded_changed", "some-master-seq", nil)
assert(effective.get() == "some-master-seq",
    "fixture: effective_source must be primed for this regression test")

-- T1: SelectBrowserItems must dispatch cleanly. Its SPEC does NOT declare
-- source_sequence_id, so the injection must be skipped for this command.
print("\n-- T1: dispatch a command without source_sequence_id in SPEC")
local r = command_manager.execute_interactive("SelectBrowserItems", {
    project_id = "proj",
    items      = {},  -- empty selection is a valid argument
    context    = { project_id = "proj" },
    modifiers  = {},
})
assert(r and r.success, string.format(
    "T1: SelectBrowserItems must succeed; got %s",
    tostring(r and r.error_message)))
print("  ok — SelectBrowserItems dispatched without 'unknown param' error")

print("\n✅ test_command_manager_nested_seq_injection.lua passed")
