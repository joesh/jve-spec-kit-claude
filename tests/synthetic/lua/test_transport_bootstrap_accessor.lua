#!/usr/bin/env luajit
--- transport.is_bootstrapped() exposes the "is the transport singleton
--- up?" predicate as a public accessor so external readers don't have to
--- poke transport._project_id directly. Five callers across the codebase
--- (command_manager, sequence_monitor, playback command, toggle command)
--- currently read the underscore-private field; this regression pins the
--- public surface they should switch to.
---
--- transport.bound_project_id() returns the project_id transport is
--- initialized for, or nil pre-init. command_manager uses it to detect
--- project changes (was: `transport._project_id ~= new_project_id`).

require("test_env")

print("=== test_transport_bootstrap_accessor.lua ===")

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

local transport = require("core.playback.transport")

-- Reset any prior state.
if transport.is_bootstrapped and transport.is_bootstrapped() then
    transport.shutdown()
end

assert(type(transport.is_bootstrapped) == "function",
    "transport.is_bootstrapped must be a function")
assert(type(transport.bound_project_id) == "function",
    "transport.bound_project_id must be a function")

-- Pre-init: predicate is false, bound id is nil.
assert(transport.is_bootstrapped() == false,
    "is_bootstrapped pre-init must be false")
assert(transport.bound_project_id() == nil,
    "bound_project_id pre-init must be nil")
print("  ✓ pre-init: is_bootstrapped=false, bound_project_id=nil")

-- Post-init: predicate is true, bound id is the project we initialized for.
local database = require("core.database")
local DB = "/tmp/jve/test_transport_bootstrap_accessor.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj_x','P','resample',%d,%d);
]], os.time(), os.time()))

transport.init("proj_x")
assert(transport.is_bootstrapped() == true,
    "is_bootstrapped post-init must be true")
assert(transport.bound_project_id() == "proj_x", string.format(
    "bound_project_id post-init must return the initializing project_id; got %s",
    tostring(transport.bound_project_id())))
print("  ✓ post-init: is_bootstrapped=true, bound_project_id='proj_x'")

-- Shutdown: predicate flips back, bound id clears.
transport.shutdown()
assert(transport.is_bootstrapped() == false,
    "is_bootstrapped post-shutdown must be false")
assert(transport.bound_project_id() == nil,
    "bound_project_id post-shutdown must be nil")
print("  ✓ post-shutdown: is_bootstrapped=false, bound_project_id=nil")

print("\n✅ test_transport_bootstrap_accessor.lua passed")
