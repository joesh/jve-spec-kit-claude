-- Integration: SequenceMonitor constructed pre-transport must NOT spin up
-- a local fallback PlaybackEngine (017 anti-pattern #5). self.engine stays
-- nil until transport_ready fires; only then does the monitor observe the
-- canonical role-bound engine.
--
-- Why this matters: every local-fallback engine constructed at app launch
-- builds a PlaybackController (CVDisplayLink), allocates audio config, and
-- is silently abandoned a few signals later when transport.init runs and
-- transport_ready emits. Two wasted engines per process launch — exactly
-- what the resource model is supposed to prevent.
--
-- Replaces tests/synthetic/lua/test_sequence_monitor_no_orphan_engine.lua,
-- which stubbed qt_constants (PLAYBACK/EMP) wholesale — so the "engine
-- construction" it observed never built a real PlaybackController, and a
-- regression in the real construction path (e.g. CREATE asserting pre-Qt)
-- would not reproduce. This version runs with real bindings; the only
-- instrumentation is a PASS-THROUGH counter around PlaybackEngine.new
-- (observes calls, delegates to the real constructor — nothing is faked).
--
-- Run via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_sequence_monitor_no_orphan_engine.lua

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_sequence_monitor_no_orphan_engine.lua (integration) ===")

require("test_env")

-- Pass-through observation of PlaybackEngine.new: counts constructions,
-- delegates to the real constructor. ANY construction during
-- SequenceMonitor.new before transport bootstrap is the bug.
local engine_new_calls = 0
local engine_module = require("core.playback.playback_engine")
local original_new = engine_module.new
engine_module.new = function(...)
    engine_new_calls = engine_new_calls + 1
    return original_new(...)
end

local SequenceMonitor = require("ui.sequence_monitor")
local transport = require("core.playback.transport")

-- Pre-condition: transport must be un-bootstrapped (in --test mode the
-- script is the whole app; nothing has called transport.init yet).
assert(not transport.is_bootstrapped(),
    "fixture: transport must be un-bootstrapped pre-test")

-- ── Case 1: construction pre-transport leaves self.engine nil ──
local pre_calls = engine_new_calls
local view = SequenceMonitor.new({
    view_id = "test_no_orphan_view",
    role    = "record",
    headless = true,
})
assert(view ~= nil, "view constructed")
assert(view.engine == nil, string.format(
    "pre-transport SequenceMonitor.new MUST leave self.engine nil "
    .. "(no orphan fallback per 017 anti-pattern #5); got %s",
    tostring(view.engine)))
assert(engine_new_calls == pre_calls, string.format(
    "PlaybackEngine.new MUST NOT be called by SequenceMonitor.new "
    .. "pre-transport. before=%d after=%d (delta=%d)",
    pre_calls, engine_new_calls, engine_new_calls - pre_calls))
print("  ✓ pre-transport: self.engine == nil; PlaybackEngine.new not called")

-- ── Case 2: transport_ready binds the canonical engine ──
-- Bootstrap transport with a real DB-backed project so transport.init
-- constructs its two role-bound engines (real PlaybackControllers) and
-- fires transport_ready. The pre-existing view must rebind.
local database = require("core.database")
local DB = "/tmp/jve/test_no_orphan_engine_integ.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))
local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p_orphan', 'P', 'resample',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d)
]], now, now)))

transport.init("p_orphan")

-- The view's transport_ready listener fires synchronously inside
-- transport.init (Signals.emit is synchronous). After init returns,
-- self.engine must be the canonical record engine — the same object,
-- not an equivalent one.
assert(view.engine ~= nil,
    "post-transport_ready: view.engine must be bound to the canonical engine")
assert(view.engine == transport.engine_for_role("record"), string.format(
    "post-transport_ready: view.engine must == transport.engine_for_role('record'); "
    .. "got %s vs canonical %s",
    tostring(view.engine), tostring(transport.engine_for_role("record"))))
print("  ✓ post-transport_ready: view.engine == canonical role-bound engine")

-- Restore the unwrapped constructor and clean up.
engine_module.new = original_new
view:destroy()
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")

print("\nPASS test_sequence_monitor_no_orphan_engine.lua")
