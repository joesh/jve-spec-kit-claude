#!/usr/bin/env luajit
-- T010 / FR-008a: on first project open, transport_target defaults to "record".

require("test_env")

print("=== test_first_open_project_defaults_to_record_side.lua ===")

package.loaded["core.qt_constants"] = {
    PLAYBACK = { CREATE = function() return "stub" end, CLOSE=function() end,
        SET_LOG_TAG=function() end, SET_TMB=function() end, SET_BOUNDS=function() end,
        SET_SURFACE=function() end, SET_CLIP_PROVIDER=function() end,
        SET_POSITION_CALLBACK=function() end, SET_CLIP_TRANSITION_CALLBACK=function() end,
        STOP=function() end, HAS_AUDIO=function() return false end },
    EMP = { TMB_CREATE=function() return "tmb" end, TMB_CLOSE=function() end,
        TMB_PARK_READERS=function() end, TMB_SET_SEQUENCE_RATE=function() end,
        TMB_SET_AUDIO_FORMAT=function() end },
    AOP={}, SSE={},
}

local database = require("core.database")
local DB = "/tmp/jve/test_017_t010.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p','P','resample',%d,%d);
]], now, now))

local transport = require("core.playback.transport")
transport.init("p")

assert(transport.get_target() == "record",
    "FR-008a: fresh project (no transport_target in settings) must default to 'record'")

transport.shutdown()
database.shutdown()
print("✅ test_first_open_project_defaults_to_record_side.lua passed")
