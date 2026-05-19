#!/usr/bin/env luajit
--- transport.lua is the resource orchestrator (017 module-responsibility
--- rule): UI/model signals → transport → engine. This test pins
--- transport's two cross-domain subscriptions to engine teardown:
---
---   project_changed       → walk {source, record}; per engine call
---                            PlaybackEngine.teardown_engine(engine);
---                            then PlaybackEngine.shutdown_audio_session()
---   displayed_tab_cleared → stop the role-bound engine holding the
---                            cleared sequence (via engine:stop())
---
--- The engine module no longer subscribes to UI signals itself
--- (anti-pattern #2 in specs/017/spec.md). If a future change moves
--- these subscriptions back into playback_engine.lua this test goes
--- red.

require("test_env")

print("=== test_transport_subscribes_to_signals.lua ===")

-- Stub qt_constants so transport.init can construct PlaybackEngine
-- without a real Qt environment.
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

-- Stub the engine module BEFORE requiring transport so the
-- module-load-time Signals.connect calls in transport bind to our
-- observable stubs. Stubs count invocations so we can assert that the
-- subscriptions actually call into the engine module.
local teardown_engine_calls = {}    -- ordered list of {engine, ...}
local audio_shutdown_calls = 0
local stop_calls_by_engine = {}

local function make_stub_engine(role)
    return {
        role = role,
        sequence = nil,
        loaded_sequence_id = nil,
        playing = false,
        is_playing = function(self) return self.playing end,
        stop = function(self)
            self.playing = false
            stop_calls_by_engine[self.role] = (stop_calls_by_engine[self.role] or 0) + 1
        end,
    }
end
local stub_source_engine = make_stub_engine("source")
local stub_record_engine = make_stub_engine("record")

package.loaded["core.playback.playback_engine"] = {
    new = function(role)
        if role == "source" then return stub_source_engine end
        if role == "record" then return stub_record_engine end
        error("stub: unexpected role " .. tostring(role))
    end,
    teardown_engine = function(engine)
        table.insert(teardown_engine_calls, engine)
    end,
    shutdown_audio_session = function()
        audio_shutdown_calls = audio_shutdown_calls + 1
    end,
}

local Signals = require("core.signals")
local transport = require("core.playback.transport")

-- Reset any prior state.
if transport.is_bootstrapped() then transport.shutdown() end

-- ── Case 1: displayed_tab_cleared without a bootstrapped transport ──
-- transport.lua's listener no-ops when transport hasn't been initialized
-- (no engines exist to stop). Emitting the signal must not raise.
local ok = pcall(Signals.emit, "displayed_tab_cleared", "any_seq")
assert(ok, "displayed_tab_cleared pre-bootstrap must not raise")
assert(stop_calls_by_engine.source == nil and stop_calls_by_engine.record == nil,
    "no engine stops when transport not bootstrapped")
print("  ✓ displayed_tab_cleared pre-bootstrap is a no-op")

-- Bootstrap transport for the remaining cases.
local database = require("core.database")
local DB = "/tmp/jve/test_transport_subscribes_to_signals.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj_t','P','resample',%d,%d);
]], os.time(), os.time()))
transport.init("proj_t")

-- ── Case 2: displayed_tab_cleared("seq_X") — only the engine holding
-- seq_X is stopped, by role-walk (not active_engines iteration). ──
stub_source_engine.sequence = { id = "seq_X" }
stub_record_engine.sequence = { id = "seq_Y" }
stop_calls_by_engine = {}

Signals.emit("displayed_tab_cleared", "seq_X")
assert(stop_calls_by_engine.source == 1, string.format(
    "source engine (holding seq_X) must be stopped exactly once; got %s",
    tostring(stop_calls_by_engine.source)))
assert(stop_calls_by_engine.record == nil, string.format(
    "record engine (holding different seq_Y) must NOT be stopped; "
    .. "got %s stop calls", tostring(stop_calls_by_engine.record)))
print("  ✓ displayed_tab_cleared stops only the role whose engine holds the cleared seq")

-- ── Case 3: displayed_tab_cleared with neither role holding the seq ──
stop_calls_by_engine = {}
Signals.emit("displayed_tab_cleared", "seq_Z")  -- nobody holds Z
assert(stop_calls_by_engine.source == nil and stop_calls_by_engine.record == nil,
    "no engine stops when no role-bound engine holds the cleared seq")
print("  ✓ displayed_tab_cleared with no matching role is a no-op")

-- ── Case 4a: displayed_tab_changed parks both engines mid-play. ──
-- Spec scenario (017 spec.md line 56): "He presses Space — the master plays
-- with audio in both windows in lock-step. He clicks a Record tab — master
-- stops, audio falls silent." Tab swap = stop any playing engine. transport
-- owns the cross-domain coordination (UI signal → engine action) per
-- module-responsibility rule.
stop_calls_by_engine = {}
stub_source_engine.playing = true
stub_record_engine.playing = true
Signals.emit("displayed_tab_changed", "seq_new", "seq_prev")
assert(stop_calls_by_engine.source == 1, string.format(
    "displayed_tab_changed must stop the source engine when it is playing; "
    .. "got %s stop calls", tostring(stop_calls_by_engine.source)))
assert(stop_calls_by_engine.record == 1, string.format(
    "displayed_tab_changed must stop the record engine when it is playing; "
    .. "got %s stop calls", tostring(stop_calls_by_engine.record)))
print("  ✓ displayed_tab_changed stops both engines when playing")

-- ── Case 4b: displayed_tab_changed is a no-op for parked engines. ──
-- is_playing() guard avoids spurious stop()/audio-release on engines that
-- aren't transporting. Idempotent semantics.
stop_calls_by_engine = {}
stub_source_engine.playing = false
stub_record_engine.playing = false
Signals.emit("displayed_tab_changed", "seq_new", "seq_prev")
assert(stop_calls_by_engine.source == nil and stop_calls_by_engine.record == nil,
    "displayed_tab_changed must NOT call stop() on already-parked engines")
print("  ✓ displayed_tab_changed is a no-op for parked engines")

-- ── Case 5: project_changed → walk roles + per-engine teardown + audio shutdown ──
teardown_engine_calls = {}
local audio_before = audio_shutdown_calls
Signals.emit("project_changed", "new_proj_id")
assert(#teardown_engine_calls == 2, string.format(
    "project_changed must call PlaybackEngine.teardown_engine once per "
    .. "role-bound engine (source + record); got %d calls",
    #teardown_engine_calls))
-- Both role engines must be torn down, in some order. Set membership check.
local saw = {}
for _, e in ipairs(teardown_engine_calls) do saw[e] = true end
assert(saw[stub_source_engine] and saw[stub_record_engine], string.format(
    "teardown_engine must be called for BOTH role-bound engines; "
    .. "saw source=%s record=%s",
    tostring(saw[stub_source_engine]), tostring(saw[stub_record_engine])))
assert(audio_shutdown_calls == audio_before + 1, string.format(
    "project_changed must also call PlaybackEngine.shutdown_audio_session "
    .. "exactly once; before=%d after=%d", audio_before, audio_shutdown_calls))
print("  ✓ project_changed → both role engines torn down + audio session shut down")

print("\n✅ test_transport_subscribes_to_signals.lua passed")
