#!/usr/bin/env luajit
-- T014 / FR-023: ONE question answers "which side is the user transporting?"
--
-- Under the derived-target redesign, the answer is a pure projection of UI
-- state — there is no stored _target pointer to keep in sync. This test
-- pins both halves of the projection:
--   1. focus_manager.get_focused_panel() == "source_monitor" → "source"
--   2. timeline_state.get_displayed_tab_kind() == "source" → "source"
--   3. otherwise → "record"

require("test_env")
print("=== test_one_question_answers_which_side_is_playing.lua ===")

local setup = require("helpers.test_017_setup")
setup.install_qt_stub()
setup.fresh_project_db("test_017_t014.db")

local transport = require("core.playback.transport")
transport.init("p")

local sim = require("helpers.transport_target_sim")

-- Half 1: source-viewer focus is the source-routing signal.
package.loaded["ui.focus_manager"] = {
    get_focused_panel = function() return "source_monitor" end,
}
package.loaded["ui.timeline.timeline_state"] = {
    get_displayed_tab_kind = function() return "record" end,  -- ignored when focus says source
}
assert(transport.get_target() == "source",
    "FR-023 (focus): focus_manager=source_monitor → get_target() = 'source'")

-- Half 2: displayed source tab is the second source-routing signal.
package.loaded["ui.focus_manager"] = {
    get_focused_panel = function() return "timeline" end,
}
package.loaded["ui.timeline.timeline_state"] = {
    get_displayed_tab_kind = function() return "source" end,
}
assert(transport.get_target() == "source",
    "FR-023 (displayed-tab): displayed_tab_kind=source → get_target() = 'source'")

-- Fallthrough: neither signal says source → record.
sim.target_record()
assert(transport.get_target() == "record",
    "FR-023 (fallthrough): no source signal → get_target() = 'record'")

print("✅ test_one_question_answers_which_side_is_playing.lua passed")
