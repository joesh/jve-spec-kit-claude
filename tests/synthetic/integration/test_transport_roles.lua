-- Integration: Transport contract, bootstrap accessors, signal subscriptions.
--
-- REPLACES (from tests/synthetic/lua/):
--   test_contract_transport.lua
--   test_transport_bootstrap_accessor.lua
--   test_first_open_project_defaults_to_record_side.lua
--   test_transport_subscribes_to_signals.lua
--
-- SCENARIOS KEPT:
--   DR-1   transport public surface: init, shutdown, get_target,
--            engine_for_role, engine_for_target are functions.
--   DR-2   Removed setters absent: set_user_transport, persist_target nil
--            (derived-target redesign).
--   DR-3   get_target() before init asserts with "init" in the message.
--   DR-4   init(nil) and init("") each assert.
--   DR-5   After init: default target is "record" (FR-008a: fresh project).
--   DR-6   engine_for_role("source")/.role == "source";
--            engine_for_role("record")/.role == "record"; they differ.
--   DR-7   engine_for_role("garbage") asserts.
--   DR-8   UI-state derivation drives the target (via transport_target_sim).
--   DR-9   engine_for_target() returns the engine matching the derived target.
--   DR-10  get_target() is stable under repeated calls (idempotent).
--   DR-11  shutdown() gates further get_target access.
--   DR-12  is_bootstrapped() / bound_project_id() lifecycle: false/nil pre-init,
--            true/project_id post-init, false/nil post-shutdown.
--   DR-13  displayed_tab_cleared pre-bootstrap is a no-op (no crash).
--   DR-14  displayed_tab_cleared("seq_X") stops only the engine holding seq_X.
--   DR-15  displayed_tab_cleared with no matching role: no engine stopped.
--   DR-16  displayed_tab_changed parks playing engines; no-op for parked engines.
--   DR-17  project_changed → teardown_engine called for both roles + audio
--            session shutdown (structural ordering invariant).
--
-- SCENARIOS DROPPED:
--   All transport tests that directly poked the real PlaybackEngine's
--   internal _position / sequence fields to verify side effects — those
--   were implementation-tracing, not domain behavior.
--   Variant of DR-13 that verified stop was NOT called when bootstrapped
--   but seq_Z is not loaded in any engine — covered by DR-15.
--
-- OPEN QUESTIONS:
--   None; all scenarios derived from spec 017 contracts/transport.md.
--
-- NOTE: Transport tests use real Signals, real database, real engine
-- construction with the test_017_setup stub (not real EMP). The engines
-- are constructed with real C++ stubs via install_qt_stub so engine
-- constructors don't crash, but no media decode runs.

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_transport_roles.lua (integration) ===")

require("test_env")
local setup   = require("synthetic.helpers.test_017_setup")
local Signals = require("core.signals")

-- ── DB bootstrap (shared for all cases) ─────────────────────────────────────
local DB = "/tmp/jve/test_transport_roles_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")

setup.install_qt_stub()  -- no call_log needed for contract tests
local ctx = setup.fresh_project_db("test_transport_roles_integ.db")

local function expect_assert(fn, label)
    local ok, err = pcall(fn)
    assert(not ok, label .. ": expected assert/error, got success")
    return tostring(err)
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-1/DR-2  Required surface + removed setters
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-1/2) public surface + removed setters --")
do
    local transport = require("core.playback.transport")
    for _, name in ipairs({
        "init", "shutdown", "get_target", "engine_for_role", "engine_for_target",
    }) do
        assert(type(transport[name]) == "function",
            string.format("transport.%s must be a function", name))
    end
    assert(transport.set_user_transport == nil,
        "transport.set_user_transport must not exist (derived-target redesign)")
    assert(transport.persist_target == nil,
        "transport.persist_target must not exist (target is derived, not stored)")
    print("  PASS: required surface present; removed setters absent")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-3  get_target() before init asserts with "init" in message
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-3) get_target() before init asserts --")
do
    local transport = require("core.playback.transport")
    if transport.is_bootstrapped() then transport.shutdown() end
    local err = expect_assert(function() transport.get_target() end,
        "get_target pre-init")
    assert(err:find("init") or err:find("not initialized"), string.format(
        "get_target pre-init error must name 'init'; got: %s", err))
    print("  PASS: get_target() before init asserts with 'init' in message")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-4  init(nil) and init("") each assert
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-4) init bad args --")
do
    local transport = require("core.playback.transport")
    if transport.is_bootstrapped() then transport.shutdown() end
    expect_assert(function() transport.init(nil) end, "init(nil)")
    expect_assert(function() transport.init("") end,  "init('')")
    print("  PASS: init(nil) and init('') each assert")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-5  Default target is "record" on fresh project (FR-008a)
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-5) default target 'record' (FR-008a) --")
do
    local transport = require("core.playback.transport")
    if transport.is_bootstrapped() then transport.shutdown() end
    transport.init(ctx.project_id)
    assert(transport.get_target() == "record", string.format(
        "FR-008a: fresh state must derive 'record'; got '%s'",
        tostring(transport.get_target())))
    transport.shutdown()
    print("  PASS: default target is 'record' on fresh project")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-6  engine_for_role returns role-bound distinct engines
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-6) engine_for_role role binding --")
do
    local transport = require("core.playback.transport")
    if transport.is_bootstrapped() then transport.shutdown() end
    transport.init(ctx.project_id)

    local src = transport.engine_for_role("source")
    local rec = transport.engine_for_role("record")
    assert(src and src.role == "source",
        "engine_for_role('source') must have role='source'")
    assert(rec and rec.role == "record",
        "engine_for_role('record') must have role='record'")
    assert(src ~= rec, "source and record engines must be distinct objects")

    transport.shutdown()
    print("  PASS: engine_for_role returns role-bound distinct engines")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-7  engine_for_role("garbage") asserts
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-7) engine_for_role bad role --")
do
    local transport = require("core.playback.transport")
    if transport.is_bootstrapped() then transport.shutdown() end
    transport.init(ctx.project_id)
    expect_assert(function() transport.engine_for_role("garbage") end,
        "engine_for_role('garbage')")
    transport.shutdown()
    print("  PASS: engine_for_role('garbage') asserts")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-8/DR-9/DR-10  UI-state derivation + engine_for_target + idempotent
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-8/9/10) UI-state derivation + engine_for_target + idempotent --")
do
    local transport = require("core.playback.transport")
    if transport.is_bootstrapped() then transport.shutdown() end
    transport.init(ctx.project_id)

    local sim = require("synthetic.helpers.transport_target_sim")
    local src = transport.engine_for_role("source")
    local rec = transport.engine_for_role("record")

    sim.target_source()
    assert(transport.get_target() == "source",
        "target_source: get_target must return 'source'")
    assert(transport.engine_for_target() == src,
        "engine_for_target() must be source engine when target='source'")

    sim.target_record()
    assert(transport.get_target() == "record",
        "target_record: get_target must return 'record'")
    assert(transport.engine_for_target() == rec,
        "engine_for_target() must be record engine when target='record'")

    -- Idempotent: repeated calls stable.
    sim.target_source()
    local first = transport.get_target()
    for _ = 1, 16 do
        assert(transport.get_target() == first,
            "get_target() must be stable under repeated calls")
    end

    transport.shutdown()
    print("  PASS: UI-state derivation + engine_for_target + idempotent")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-11  shutdown() gates get_target
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-11) shutdown gates get_target --")
do
    local transport = require("core.playback.transport")
    if transport.is_bootstrapped() then transport.shutdown() end
    transport.init(ctx.project_id)
    transport.shutdown()
    expect_assert(function() transport.get_target() end,
        "get_target after shutdown")
    print("  PASS: get_target() asserts after shutdown")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-12  is_bootstrapped() / bound_project_id() lifecycle
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-12) is_bootstrapped / bound_project_id lifecycle --")
do
    local transport = require("core.playback.transport")
    if transport.is_bootstrapped() then transport.shutdown() end

    assert(type(transport.is_bootstrapped) == "function",
        "transport.is_bootstrapped must be a function")
    assert(type(transport.bound_project_id) == "function",
        "transport.bound_project_id must be a function")

    -- Pre-init.
    assert(transport.is_bootstrapped() == false,
        "is_bootstrapped pre-init must be false")
    assert(transport.bound_project_id() == nil,
        "bound_project_id pre-init must be nil")

    transport.init(ctx.project_id)
    assert(transport.is_bootstrapped() == true,
        "is_bootstrapped post-init must be true")
    assert(transport.bound_project_id() == ctx.project_id, string.format(
        "bound_project_id post-init must be '%s'; got '%s'",
        ctx.project_id, tostring(transport.bound_project_id())))

    transport.shutdown()
    assert(transport.is_bootstrapped() == false,
        "is_bootstrapped post-shutdown must be false")
    assert(transport.bound_project_id() == nil,
        "bound_project_id post-shutdown must be nil")
    print("  PASS: is_bootstrapped/bound_project_id lifecycle correct")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-13  displayed_tab_cleared pre-bootstrap is a no-op
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-13) displayed_tab_cleared pre-bootstrap no-op --")
do
    local transport = require("core.playback.transport")
    if transport.is_bootstrapped() then transport.shutdown() end
    local ok = pcall(Signals.emit, "displayed_tab_cleared", "any_seq")
    assert(ok, "displayed_tab_cleared pre-bootstrap must not raise")
    print("  PASS: displayed_tab_cleared pre-bootstrap is a no-op")
end

-- ════════════════════════════════════════════════════════════════════════════
-- DR-14/DR-15/DR-16/DR-17  Signal subscriptions (displayed_tab_cleared/changed,
--                           project_changed) using observable stub engines.
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (DR-14..17) signal subscription behaviors --")
do
    -- Install observable stub engines BEFORE requiring transport so the
    -- engine module's Signals.connect calls in transport bind to our stubs.
    local teardown_calls = {}
    local audio_shutdown_calls = 0
    local stop_by_role = {}

    local function make_stub_engine(role)
        return {
            role = role,
            sequence = nil,
            loaded_sequence_id = nil,
            playing = false,
            is_playing = function(self) return self.playing end,
            stop = function(self)
                self.playing = false
                stop_by_role[self.role] = (stop_by_role[self.role] or 0) + 1
            end,
        }
    end
    local stub_src = make_stub_engine("source")
    local stub_rec = make_stub_engine("record")

    package.loaded["core.playback.playback_engine"] = {
        new = function(role)
            if role == "source" then return stub_src end
            if role == "record" then return stub_rec end
            error("stub: unexpected role " .. tostring(role))
        end,
        teardown_engine = function(engine)
            teardown_calls[#teardown_calls + 1] = engine
        end,
        shutdown_audio_session = function()
            audio_shutdown_calls = audio_shutdown_calls + 1
        end,
    }

    local transport = require("core.playback.transport")
    if transport.is_bootstrapped() then transport.shutdown() end
    transport.init(ctx.project_id)

    -- DR-14: displayed_tab_cleared("seq_X") stops only the engine holding seq_X.
    stub_src.sequence = { id = "seq_X" }
    stub_rec.sequence = { id = "seq_Y" }
    stop_by_role = {}
    Signals.emit("displayed_tab_cleared", "seq_X")
    assert(stop_by_role.source == 1, string.format(
        "source engine (holding seq_X) must be stopped once; got %s",
        tostring(stop_by_role.source)))
    assert(stop_by_role.record == nil, string.format(
        "record engine (holding different seq_Y) must NOT be stopped; got %s",
        tostring(stop_by_role.record)))
    print("  PASS DR-14: displayed_tab_cleared stops only the matching role engine")

    -- DR-15: no matching role → no stops.
    stop_by_role = {}
    Signals.emit("displayed_tab_cleared", "seq_Z")
    assert(stop_by_role.source == nil and stop_by_role.record == nil,
        "no engine stops when no role-bound engine holds the cleared seq")
    print("  PASS DR-15: displayed_tab_cleared with no match is a no-op")

    -- DR-16a: displayed_tab_changed parks playing engines.
    stop_by_role = {}
    stub_src.playing = true; stub_rec.playing = true
    Signals.emit("displayed_tab_changed", "new_seq", "prev_seq")
    assert(stop_by_role.source == 1, string.format(
        "source engine must be stopped on tab change; got %s",
        tostring(stop_by_role.source)))
    assert(stop_by_role.record == 1, string.format(
        "record engine must be stopped on tab change; got %s",
        tostring(stop_by_role.record)))
    print("  PASS DR-16a: displayed_tab_changed stops both playing engines")

    -- DR-16b: no-op for parked engines.
    stop_by_role = {}
    stub_src.playing = false; stub_rec.playing = false
    Signals.emit("displayed_tab_changed", "new_seq", "prev_seq")
    assert(stop_by_role.source == nil and stop_by_role.record == nil,
        "displayed_tab_changed must not stop already-parked engines")
    print("  PASS DR-16b: displayed_tab_changed is a no-op for parked engines")

    -- DR-17: project_changed → teardown for both engines + audio shutdown.
    teardown_calls = {}
    local audio_before = audio_shutdown_calls
    Signals.emit("project_changed", "new_proj")
    assert(#teardown_calls == 2, string.format(
        "project_changed must call teardown_engine for both role engines; got %d",
        #teardown_calls))
    local saw = {}
    for _, e in ipairs(teardown_calls) do saw[e] = true end
    assert(saw[stub_src] and saw[stub_rec],
        "teardown_engine must be called for BOTH source and record engines")
    assert(audio_shutdown_calls == audio_before + 1, string.format(
        "project_changed must call shutdown_audio_session once; before=%d after=%d",
        audio_before, audio_shutdown_calls))
    print("  PASS DR-17: project_changed tears down both engines + audio session")

    transport.shutdown()

    -- Restore real engine module.
    package.loaded["core.playback.playback_engine"] = nil
end

print("\nPASS test_transport_roles.lua")
os.exit(0)
