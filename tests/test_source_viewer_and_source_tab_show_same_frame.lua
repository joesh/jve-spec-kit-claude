#!/usr/bin/env luajit
-- T027 / FR-015: the source viewer (top-left widget) and the source tab
-- inside the timeline panel both observe the source-role engine, so they
-- always display the same frame. Structural test: both view records
-- subscribe to the same engine instance.

require("test_env")
print("=== test_source_viewer_and_source_tab_show_same_frame.lua ===")

local setup = require("helpers.test_017_setup")
setup.install_qt_stub()
setup.fresh_project_db("test_017_t027.db")

local transport = require("core.playback.transport")
transport.init("p")
local source_engine = transport.engine_for_role("source")

local SequenceMonitor = require("ui.sequence_monitor")
local source_view = SequenceMonitor.new({ view_id = "source_monitor", role = "source", headless = true })
local source_tab_view = SequenceMonitor.new({ view_id = "source_tab", role = "source", headless = true })

assert(source_view:bound_engine() == source_engine, string.format(
    "FR-015: source_monitor view must bind to source engine; got %s",
    tostring(source_view:bound_engine())))
assert(source_tab_view:bound_engine() == source_engine, string.format(
    "FR-015: source-tab view must bind to the SAME source engine; got %s",
    tostring(source_tab_view:bound_engine())))
assert(source_view:bound_engine() == source_tab_view:bound_engine(),
    "FR-015: both source-side views must share one engine reference")

print("✅ test_source_viewer_and_source_tab_show_same_frame.lua passed")
