#!/usr/bin/env luajit
-- Regression (2026-05-16, Joe-reported): pressing Space while the source
-- viewer or source tab is displayed still played the record sequence
-- because the source-side surfaces did not route transport target to
-- "source". This test pins the contract:
--   switch_to_source_tab(seq)        → transport.get_target() == "source"
--   source_viewer.load_master_clip   → transport.get_target() == "source"
-- and verifies the source engine carries the loaded master afterwards
-- so TogglePlay drives the source side, not record.

require("test_env")
local setup = require("helpers.test_017_setup")
setup.install_qt_stub()
setup.fresh_project_db("test_017_bug_source_target.db")

print("=== test_source_tab_and_viewer_set_transport_target.lua ===")

local transport = require("core.playback.transport")
transport.init("p")
local src_engine = transport.engine_for_role("source")
local rec_engine = transport.engine_for_role("record")

-- No source signal yet → derives to record (FR-008a default fallthrough).
assert(transport.get_target() == "record")

-- ── source-tab click ────────────────────────────────────────────────────
-- Real switch_to_source_tab mutates the timeline tab strip; transport
-- derivation reads the displayed-tab kind and resolves to "source".
local timeline_state = require("ui.timeline.timeline_state")
timeline_state.switch_to_source_tab("src")
assert(transport.get_target() == "source", string.format(
    "switch_to_source_tab → displayed_tab_kind=source → derived target 'source'; got '%s'",
    transport.get_target()))

-- Flip back to record so we can re-prove via source_viewer. The record
-- tab needs to exist before we can switch to it — open one.
timeline_state.switch_to_record_tab("rec")
assert(transport.get_target() == "record")

-- ── source viewer load ─────────────────────────────────────────────────
-- Stub panel_manager so source_viewer can find a "source_monitor".
-- Stub source monitor mirrors real SequenceMonitor:load_sequence — after
-- load it stores the loaded Sequence model on `.sequence`, which
-- source_viewer reads to publish a selection_hub item carrying the
-- sequence's project_id.
local stub_source_monitor = {
    sequence = nil,
    load_sequence = function(self, seq_id)
        local Sequence = require("models.sequence")
        self.sequence = Sequence.load(seq_id)
    end,
    unload = function(self) self.sequence = nil end,
    get_loaded_master_seq_id = function(self)
        return self.sequence and self.sequence.id or nil
    end,
}
package.loaded["ui.panel_manager"] = {
    get_sequence_monitor = function(view_id)
        if view_id == "source_monitor" then return stub_source_monitor end
    end,
}
-- 017 derived target: source_viewer.load_master_clip calls
-- focus_manager.focus_panel("source_monitor"); the stub must reflect
-- that state so transport.get_target() derives "source".
local _focused = nil
package.loaded["ui.focus_manager"] = {
    focus_panel = function(id) _focused = id end,
    get_focused_panel = function() return _focused end,
    on_focus_change = function() end,
}

local source_viewer = require("ui.source_viewer")
-- Real call (no skip_focus): focus moves to source_monitor → derived target
-- resolves to "source". skip_focus=true would leave focus untouched, in
-- which case derivation would correctly stay on the previously-focused side.
source_viewer.load_master_clip("src")

assert(transport.get_target() == "source", string.format(
    "source_viewer.load_master_clip must focus source_monitor → derived target 'source'; got '%s'",
    transport.get_target()))

-- The source engine must be loaded with the master so subsequent
-- TogglePlay drives the source side.
assert(src_engine.loaded_sequence_id == "src", string.format(
    "source-engine must be loaded with 'src' after load_master_clip; got '%s'",
    tostring(src_engine.loaded_sequence_id)))
assert(rec_engine.loaded_sequence_id ~= "src",
    "record-engine must NOT be loaded with the master")

print("✅ test_source_tab_and_viewer_set_transport_target.lua passed")
