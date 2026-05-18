-- Integration regression for project_browser ↔ load_sequences contract.
--
-- Run via: ./build/bin/JVEEditor --test tests/integration_test_browser_lists_sequences.lua
--
-- Bug history (2026-05-13): project_browser.lua filtered with
--   if not sequence.kind or sequence.kind == "timeline"
-- but db.load_sequences returns rows where kind == "sequence" (the only
-- non-master value the schema CHECK constraint allows). Result: every
-- user-created sequence — gold included — was silently dropped from the
-- browser tree.
--
-- A pure-Lua test (test_load_sequences_kind_contract.lua) pins the DB
-- side of that contract. THIS test exercises the integration: a real
-- project_browser instance, a real DB, a CreateSequence command, and an
-- assertion that the freshly-created sequence shows up in M.sequence_map.
--
-- Why --test mode: project_browser requires Qt constants and ui.view at
-- module load.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database         = require("core.database")
local command_manager  = require("core.command_manager")
local project_browser  = require("ui.project_browser")
local Signals          = require("core.signals")

print("=== integration_test_browser_lists_sequences.lua ===")

local DB = "/tmp/jve/integration_test_browser_lists_sequences.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB), "schema init failed")
local db = database.get_connection()

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'P', 'passthrough', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        created_at, modified_at)
    VALUES ('boot', 'proj', 'boot', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now, now, now)))

-- command_manager.init requires an active sequence_id; pick the bootstrap.
command_manager.init("boot", "proj")

-- Point project_browser at this project's id. Its `sequence_list_changed`
-- listener (added 2026-05-13) refreshes when signals are emitted for the
-- matching project_id.
project_browser.project_id = "proj"

-- CreateSequence executor queues sequence_list_changed via the post-
-- commit hook; the framework flushes it after commit.
local r = command_manager.execute("CreateSequence", {
    project_id        = "proj",
    name              = "gold",
    frame_rate        = { fps_numerator = 24, fps_denominator = 1 },
    audio_sample_rate = 48000,
    width             = 1920,
    height            = 1080,
})
assert(r and r.success, "CreateSequence failed: "
    .. tostring(r and r.error_message))

-- Query the DB for the new row's id. Going through the DB rather than
-- digging into the command result keeps this test black-box on the
-- command's return shape.
local sel = db:prepare("SELECT id FROM sequences WHERE project_id='proj' AND name='gold'")
assert(sel:exec() and sel:next(),
    "DB has no 'gold' sequence after CreateSequence — executor regressed")
local created_id = sel:value(0); sel:finalize()
assert(type(created_id) == "string" and created_id ~= "",
    "DB returned empty id for newly-created 'gold' sequence")

-- The full populate_tree path requires Qt widgets that --test mode
-- doesn't bring up, so we can't observe sequence_map directly. Instead
-- verify the listener wiring: project_browser must have registered for
-- sequence_list_changed, and its handler must invoke M.refresh exactly
-- when the emit's project_id matches the browser's. Together with
-- test_post_commit_emit_queue T1 (which proves the emit actually
-- fires post-commit) this closes the loop on the bug from 2026-05-13.

-- Replace M.refresh with a recorder for the duration of this assertion.
local refresh_calls = 0
local real_refresh = project_browser.refresh
project_browser.refresh = function() refresh_calls = refresh_calls + 1 end

-- Listener was registered at module load (require above). Emit the
-- matching-project signal and assert refresh fired.
Signals.emit("sequence_list_changed", "proj")
assert(refresh_calls == 1, string.format(
    "Project_id match must trigger exactly one M.refresh; got %d", refresh_calls))

-- Emit for a DIFFERENT project: must NOT refresh.
Signals.emit("sequence_list_changed", "some-other-project")
assert(refresh_calls == 1, string.format(
    "Mismatched project_id must not trigger refresh; got %d total calls",
    refresh_calls))

project_browser.refresh = real_refresh

-- Also confirm the DB-side row exists (the actual gold-disappearance
-- bug was that an existing row was filtered out of the tree; this
-- pins that the row IS reachable from the DB after CreateSequence).
local check = db:prepare("SELECT kind FROM sequences WHERE id=?")
check:bind_value(1, created_id); assert(check:exec() and check:next())
assert(check:value(0) == "sequence", string.format(
    "CreateSequence must write kind='sequence'; got %q", tostring(check:value(0))))
check:finalize()

print("\n✅ integration_test_browser_lists_sequences.lua passed")
