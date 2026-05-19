#!/usr/bin/env luajit
-- T029 / FR-016 case (c): a freshly-loaded sequence that has never been
-- played (no cached frame for it on this view) renders an empty placeholder
-- rather than holding the previous sequence's frame.

require("test_env")
print("=== test_new_sequence_shows_empty_placeholder_until_played_once.lua ===")

local setup = require("helpers.test_017_setup")
setup.install_qt_stub()
setup.fresh_project_db("test_017_t029.db")

local SequenceMonitor = require("ui.sequence_monitor")
local view = SequenceMonitor.new({ view_id = "timeline_monitor", role = "record", headless = true })

-- View has no cached frames yet.
assert(view:cached_frame_for("rec") == nil,
    "view must have no cached frame before any frame_delivered")
assert(view:should_show_placeholder("rec") == true, string.format(
    "FR-016 (c): brand-new sequence with no cached frame must request placeholder; got %s",
    tostring(view:should_show_placeholder("rec"))))

-- After accepting a frame for 'rec', placeholder no longer required.
view:_accept_frame({ id = "f1" }, { offline = false, rotation = 0, par_num = 1, par_den = 1 }, "rec")
assert(view:should_show_placeholder("rec") == false,
    "after a frame is cached, placeholder no longer requested")

print("✅ test_new_sequence_shows_empty_placeholder_until_played_once.lua passed")
