#!/usr/bin/env luajit
-- T007: contract test for core.playback.transport per contracts/transport.md.
--
-- 017 derived-target redesign: the public surface is the minimal 5
-- functions {init, shutdown, get_target, engine_for_role, engine_for_target}.
-- There is no set_user_transport / persist_target — the target is a pure
-- projection of UI state (focus_manager + timeline_state), derived on
-- every get_target() call.

require("test_env")

print("=== test_contract_transport.lua ===")

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

local transport = require("core.playback.transport")

-- ---------- Case 1: required public surface ----------
for _, name in ipairs({
    "init", "shutdown", "get_target",
    "engine_for_role", "engine_for_target",
}) do
    assert(type(transport[name]) == "function",
        string.format("transport.%s must be a function", name))
end
-- Negative surface: the removed setter/persister must not exist.
assert(transport.set_user_transport == nil,
    "transport.set_user_transport must not exist (derived-target redesign)")
assert(transport.persist_target == nil,
    "transport.persist_target must not exist (target is derived, not stored)")

-- ---------- Case 2: get_target before init asserts ----------
local ok, err = pcall(transport.get_target)
assert(not ok, "transport.get_target() before init must assert")
assert(tostring(err):match("init") or tostring(err):match("not initialized"),
    string.format("get_target pre-init error must name 'init'; got: %s", tostring(err)))

-- ---------- Case 3: init with bad project_id asserts ----------
ok = pcall(transport.init, nil)
assert(not ok, "transport.init(nil) must assert")
ok = pcall(transport.init, "")
assert(not ok, "transport.init('') must assert")

local database = require("core.database")
local DB = "/tmp/jve/test_contract_transport.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('proj','P','resample',%d,%d);
]], now, now))

-- ---------- Case 4: init succeeds; default target is "record" ----------
-- With no source-side UI state simulated, derivation falls through to the
-- record default (FR-008a).
transport.init("proj")
assert(transport.get_target() == "record", string.format(
    "FR-008a: fresh state must derive target to 'record', got '%s'",
    tostring(transport.get_target())))

-- ---------- Case 5: engine_for_role returns role-bound engines ----------
local src = transport.engine_for_role("source")
local rec = transport.engine_for_role("record")
assert(src and src.role == "source",
    "engine_for_role('source') must return engine with role='source'")
assert(rec and rec.role == "record",
    "engine_for_role('record') must return engine with role='record'")
assert(src ~= rec, "source and record engines must be distinct objects")

ok = pcall(transport.engine_for_role, "garbage")
assert(not ok, "engine_for_role('garbage') must assert")

-- ---------- Case 6: UI-state derivation drives the target ----------
local sim = require("synthetic.helpers.transport_target_sim")

sim.target_source()
assert(transport.get_target() == "source",
    "after sim.target_source(), get_target() must derive 'source'")
assert(transport.engine_for_target() == src,
    "engine_for_target() must equal source-engine when target is 'source'")

sim.target_record()
assert(transport.get_target() == "record",
    "after sim.target_record(), get_target() must derive 'record'")
assert(transport.engine_for_target() == rec,
    "engine_for_target() must equal record-engine when target is 'record'")

-- ---------- Case 7: target derivation is idempotent ----------
-- Rapid get_target() calls return consistent values without side effects.
sim.target_source()
local first = transport.get_target()
for _ = 1, 16 do
    assert(transport.get_target() == first,
        "get_target() must be stable under repeated calls with the same UI state")
end

-- ---------- Case 8: shutdown gates further access ----------
transport.shutdown()
ok = pcall(transport.get_target)
assert(not ok, "after shutdown, get_target must assert (not initialized)")

database.shutdown()

print("✅ test_contract_transport.lua passed")
