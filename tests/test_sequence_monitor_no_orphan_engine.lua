#!/usr/bin/env luajit
--- 017 anti-pattern #5 eliminated: SequenceMonitor.new constructed
--- pre-transport must NOT spin up a local fallback PlaybackEngine.
--- self.engine stays nil until transport_ready fires; only then does
--- the monitor observe the canonical role-bound engine.
---
--- Why this matters: every local-fallback engine constructed at app
--- launch builds a PlaybackController (CVDisplayLink), allocates audio
--- config, and is silently abandoned a few signals later when
--- transport.init runs and transport_ready emits. Two wasted engines
--- per process launch — exactly what the resource model is supposed
--- to prevent.

require("test_env")

print("=== test_sequence_monitor_no_orphan_engine.lua ===")

-- Stub qt_constants so any engine construction the system performs is
-- observable (no real Qt machinery).
package.loaded["core.qt_constants"] = {
    PLAYBACK = {
        CREATE = function() return "stub_pc" end,
        CLOSE = function() end,
        SET_LOG_TAG = function() end,
        SET_TMB = function() end,
        SET_BOUNDS = function() end,
        SET_SURFACE = function() end,
        SET_CLIP_PROVIDER = function() end,
        SET_POSITION_CALLBACK = function() end,
        SET_CLIP_TRANSITION_CALLBACK = function() end,
        STOP = function() end,
        HAS_AUDIO = function() return false end,
    },
    EMP = {
        TMB_CREATE = function() return "stub_tmb" end,
        TMB_CLOSE = function() end,
        TMB_PARK_READERS = function() end,
        TMB_SET_SEQUENCE_RATE = function() end,
        TMB_SET_AUDIO_FORMAT = function() end,
    },
    AOP = {}, SSE = {},
}

-- Count PlaybackEngine.new calls. ANY call during SequenceMonitor.new
-- before transport bootstrap is the bug we're eliminating.
local engine_new_calls = 0
local real_engine_module = require("core.playback.playback_engine")
local original_new = real_engine_module.new
real_engine_module.new = function(...)
    engine_new_calls = engine_new_calls + 1
    return original_new(...)
end

local SequenceMonitor = require("ui.sequence_monitor")
local transport = require("core.playback.transport")

-- Belt-and-suspenders: ensure transport is NOT bootstrapped.
if transport.is_bootstrapped() then transport.shutdown() end
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
    .. "(no orphan fallback per anti-pattern #5); got %s",
    tostring(view.engine)))
assert(engine_new_calls == pre_calls, string.format(
    "PlaybackEngine.new MUST NOT be called by SequenceMonitor.new "
    .. "pre-transport. before=%d after=%d (delta=%d)",
    pre_calls, engine_new_calls, engine_new_calls - pre_calls))
print("  ✓ pre-transport: self.engine == nil; PlaybackEngine.new not called")

-- ── Case 2: transport_ready binds the canonical engine ──
-- Bootstrap transport with a real DB-backed project so transport.init
-- can construct its two role-bound engines, then fire transport_ready
-- (transport.init emits it). The pre-existing view must rebind.
local database = require("core.database")
local DB = "/tmp/jve/test_sequence_monitor_no_orphan_engine.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('p_orphan','P','resample',%d,%d);
]], os.time(), os.time()))

transport.init("p_orphan")

-- The view's transport_ready listener fires synchronously inside
-- transport.init (Signals.emit is synchronous). After init returns,
-- self.engine must be the canonical record engine.
assert(view.engine ~= nil,
    "post-transport_ready: view.engine must be bound to the canonical engine")
assert(view.engine == transport.engine_for_role("record"), string.format(
    "post-transport_ready: view.engine must == transport.engine_for_role('record'); "
    .. "got %s vs canonical %s",
    tostring(view.engine), tostring(transport.engine_for_role("record"))))
print("  ✓ post-transport_ready: view.engine == canonical role-bound engine")

print("\n✅ test_sequence_monitor_no_orphan_engine.lua passed")
