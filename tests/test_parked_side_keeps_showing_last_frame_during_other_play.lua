#!/usr/bin/env luajit
-- T028 / FR-016 case (b): a view bound to a parked engine continues
-- displaying its last cached frame when its engine is rebound away
-- (e.g. user clicks a tab whose engine just unloaded).
-- Structural: the view's _cached_last_frame survives rebind.

require("test_env")
print("=== test_parked_side_keeps_showing_last_frame_during_other_play.lua ===")

local setup = require("helpers.test_017_setup")
setup.install_qt_stub()
setup.fresh_project_db("test_017_t028.db")

local SequenceMonitor = require("ui.sequence_monitor")
local view = SequenceMonitor.new({ view_id = "timeline_monitor", role = "record", headless = true })

local frame_handle = { id = "frame#1" }
view:_accept_frame(frame_handle, { offline = false, rotation = 0, par_num = 1, par_den = 1 }, "rec")

assert(view:cached_frame_for("rec") == frame_handle, string.format(
    "FR-016 (b): view must cache the last frame for its bound sequence; got %s",
    tostring(view:cached_frame_for("rec"))))

-- Engine rebinds to another sequence — cached frame for 'rec' survives.
view:_on_engine_rebind("rec2")
assert(view:cached_frame_for("rec") == frame_handle,
    "FR-016 (b): cached frame for old sequence must survive engine rebind")

print("✅ test_parked_side_keeps_showing_last_frame_during_other_play.lua passed")
