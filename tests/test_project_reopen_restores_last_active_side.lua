#!/usr/bin/env luajit
-- T011 / FR-008a: closing then reopening a project restores the user's
-- last transport side.
--
-- Under the derived-target redesign, "transport target" is a pure
-- projection of UI state — it is no longer a persisted pointer. The
-- mechanism that satisfies FR-008a is now:
--   1. Project save persists the active sequence (data.state.sequence_id)
--      and the displayed tab id (timeline_state).
--   2. Project load restores both, recreating the same tab strip state.
--   3. transport.get_target() reads displayed_tab_kind on the next call
--      and resolves to the role it had at save time.
--
-- This test pins the unit-level invariant: at init time, if UI state
-- has been restored such that the displayed tab is a source tab, then
-- transport.get_target() must derive 'source'. The full
-- save→close→open→restore loop is covered by integration tests that
-- exercise the project loader and timeline tab strip together.

require("test_env")
print("=== test_project_reopen_restores_last_active_side.lua ===")

local setup = require("helpers.test_017_setup")
setup.install_qt_stub()
setup.fresh_project_db("test_017_t011.db")

local transport = require("core.playback.transport")
local sim = require("helpers.transport_target_sim")

-- Simulate UI state as it would be after restoring a project that last
-- had the source side selected.
sim.target_source()
transport.init("p")
assert(transport.get_target() == "source", string.format(
    "FR-008a: at init, derived target must reflect restored UI state ('source'); got '%s'",
    transport.get_target()))
transport.shutdown()

-- Same for record.
sim.target_record()
transport.init("p")
assert(transport.get_target() == "record",
    "FR-008a: at init, derived target must reflect restored UI state ('record')")
transport.shutdown()

require("core.database").shutdown()
print("✅ test_project_reopen_restores_last_active_side.lua passed")
