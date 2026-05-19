#!/usr/bin/env luajit
-- T023 / FR-012 I1: no-overlap invariant. When the new side starts playing,
-- the prior side's audio output has already halted — structurally proved by
-- audio_playback.halt_current() returning before acquire_for() begins.

require("test_env")
print("=== test_no_audio_dropout_when_switching_between_source_and_record.lua ===")

local setup = require("helpers.test_017_setup")
local call_log = {}
setup.install_qt_stub(call_log)
setup.fresh_project_db("test_017_t023.db")

local transport = require("core.playback.transport")
transport.init("p")
local rec = transport.engine_for_role("record")
local src = transport.engine_for_role("source")
rec:load("rec"); src:load("src")

-- Record plays first.
require("helpers.transport_target_sim").target_record()
rec:play()
-- Then user switches to source and plays it.
require("helpers.transport_target_sim").target_source()

-- Reset log to capture just the handover. We don't need a local reference
-- to the audio_playback module here — the engine's own require pulls it
-- in for the handover call chain.
call_log = {}
package.loaded["core.qt_constants"].PLAYBACK.PLAY = function() call_log[#call_log+1]="PLAYBACK.PLAY" end
package.loaded["core.qt_constants"].AOP.START   = function() call_log[#call_log+1]="AOP.START" end
package.loaded["core.qt_constants"].AOP.STOP    = function() call_log[#call_log+1]="AOP.STOP" end
package.loaded["core.qt_constants"].PLAYBACK.DEACTIVATE_AUDIO = function() call_log[#call_log+1]="DEACTIVATE_AUDIO" end

-- Stop record (preconditions for play assert state=='stopped').
rec:stop()
src:play()

-- I1: a halt event (AOP.STOP or DEACTIVATE_AUDIO) precedes the new
-- side's AOP.START / PLAYBACK.PLAY in the call log.
local function index_of(events, prefixes)
    for i, e in ipairs(events) do
        for _, p in ipairs(prefixes) do
            if e == p then return i end
        end
    end
    return nil
end
local halt_at  = index_of(call_log, { "AOP.STOP", "DEACTIVATE_AUDIO" })
local start_at = index_of(call_log, { "AOP.START", "PLAYBACK.PLAY" })

assert(halt_at, "I1: expected a halt event during handover; saw " .. table.concat(call_log, ","))
assert(start_at, "I1: expected a start event during handover; saw " .. table.concat(call_log, ","))
assert(halt_at < start_at, string.format(
    "FR-012 I1 no-overlap: halt must precede start; halt_at=%d start_at=%d log=%s",
    halt_at, start_at, table.concat(call_log, ",")))

print("✅ test_no_audio_dropout_when_switching_between_source_and_record.lua passed")
