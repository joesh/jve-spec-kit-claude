#!/usr/bin/env luajit
-- T018 / FR-006/007: engine:load(seq) parks at seq.playhead_position from DB.

require("test_env")
print("=== test_loading_resumes_at_last_stopped_frame.lua ===")

local setup = require("synthetic.helpers.test_017_setup")
setup.install_qt_stub()
local h = setup.fresh_project_db("test_017_t018.db")

-- Pre-set the master's playhead to 12345.
h.database.get_connection():exec(
    "UPDATE sequences SET playhead_frame=12345 WHERE id='src';")

local transport = require("core.playback.transport")
transport.init("p")
local src = transport.engine_for_role("source")
src:load("src")

assert(src.loaded_sequence_id == "src")
assert(src:get_position() == 12345, string.format(
    "FR-006: engine must park at saved playhead 12345, got %s",
    tostring(src:get_position())))

print("✅ test_loading_resumes_at_last_stopped_frame.lua passed")
