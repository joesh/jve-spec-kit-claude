#!/usr/bin/env luajit
-- T016 / FR-001/002/003: source and record engines hold independent
-- positions; loading on one does not alter the other.

require("test_env")
print("=== test_source_and_record_each_remember_their_own_playhead.lua ===")

local setup = require("helpers.test_017_setup")
setup.install_qt_stub()
setup.fresh_project_db("test_017_t016.db")

local transport = require("core.playback.transport")
transport.init("p")

local src = transport.engine_for_role("source")
local rec = transport.engine_for_role("record")
assert(src ~= rec, "engines must be distinct objects")

-- Park source at a frame; park record at a different frame; verify they
-- don't bleed.
src:load("src"); src:seek(17)
rec:load("rec"); rec:seek(42)

assert(src:get_position() == 17, string.format(
    "FR-001: source-engine position must be 17, got %s", tostring(src:get_position())))
assert(rec:get_position() == 42, string.format(
    "FR-002: record-engine position must be 42, got %s", tostring(rec:get_position())))
assert(src.loaded_sequence_id == "src")
assert(rec.loaded_sequence_id == "rec")

print("✅ test_source_and_record_each_remember_their_own_playhead.lua passed")
