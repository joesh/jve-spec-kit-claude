"""
017 transport-target routing: the transport target follows the displayed
tab kind. When the source tab is on screen, Space (play) drives the
source engine; when the record tab is on screen, Space drives the record
engine. Regression target: 2026-05-13 bug where pressing Space with the
source tab displayed played the record-bonded engine.

Replaces tests/integration/test_playback_routes_to_displayed_tab.lua —
that test used hand-crafted DB rows + a mock-engine stub; this smoke
drives real tab toggles through Grave and inspects transport_target() /
source_engine_sequence_id() / record_engine_sequence_id() via
debug_helpers.

Run:
    python3 -m unittest tests.smoke.cases.test_playback_routes_to_displayed_tab -v
"""

import unittest

from tests.smoke.runner.case import JVESmokeCase

class TestPlaybackRoutesToDisplayedTab(JVESmokeCase):
    """Transport target tracks the displayed tab kind."""

    def test_01_record_tab_displayed_routes_to_record_engine(self) -> None:
        # Anamnesis opens on the record tab by default. Make that explicit
        # so the test isn't sensitive to template drift.
        self.ensure_record_tab()
        self.assertEvalEqual(
            "record",
            'return require("core.debug_helpers").displayed_tab_kind()',
            msg="fixture: ensure_record_tab() must leave the record tab displayed")

        self.assertEvalEqual(
            "record",
            'return require("core.debug_helpers").transport_target()',
            msg=("record tab displayed -> transport target must be 'record'. "
                 "If this fails, transport.get_target() is no longer derived "
                 "from displayed_tab_kind() — Space would play the wrong "
                 "engine for the on-screen sequence."))

        # The record engine must be bound to the displayed sequence —
        # otherwise pressing Space would play something other than what
        # the user sees.
        displayed = self.eval_str(
            'return require("core.debug_helpers").displayed_sequence_id()')
        rec_loaded = self.eval_str(
            'return require("core.debug_helpers").record_engine_sequence_id()')
        self.assertEqual(displayed, rec_loaded, (
            f"record engine loaded sequence ({rec_loaded}) must match the "
            f"displayed sequence ({displayed}) — Space-on-record would "
            f"otherwise drive an engine bonded to a different sequence."))

    def test_02_source_tab_displayed_routes_to_source_engine(self) -> None:
        # Load a clip into the source viewer to materialize a source tab.
        # Pick the first non-gap clip on the displayed sequence, focus the
        # timeline, click it, then press Shift+F (LoadClipAsSource).
        clip_id = self.eval_str(
            "local ts = require('ui.timeline.timeline_state'); "
            "for _, c in ipairs(ts.get_tab_strip():displayed_clips()) do "
            "  if not c.is_gap then return c.id end "
            "end; "
            "error('fixture: no media clip on displayed sequence')")

        self.focus_panel("timeline")
        self.click_clip(clip_id)
        self.key("Shift+F")

        # Wait for the source tab to come up.
        self.wait_for(
            'return require("core.debug_helpers").displayed_tab_kind() == "source"',
            timeout=5.0)

        self.assertEvalEqual(
            "source",
            'return require("core.debug_helpers").displayed_tab_kind()',
            msg="Shift+F on a selected clip must display the source tab")

        # Domain assertion: with the source tab on screen, transport must
        # route to 'source' so Space plays the master, not the record.
        self.assertEvalEqual(
            "source",
            'return require("core.debug_helpers").transport_target()',
            msg=("source tab displayed -> transport target must be 'source'. "
                 "This is the 2026-05-13 regression: with the source tab "
                 "displayed, Space was playing the record-bonded engine, "
                 "so the user heard/saw something other than what was on "
                 "screen. transport.get_target() must derive from "
                 "displayed_tab_kind()."))

        # And the source engine must actually be bound to a master — not
        # left nil — otherwise 'target=source' is a routing dead end.
        src_loaded = self.eval_str(
            'return require("core.debug_helpers").source_engine_sequence_id()')
        self.assertTrue(src_loaded and src_loaded != "",
            "source engine has no loaded sequence after Shift+F loaded a "
            "clip as source — Space would route to source target but find "
            "no engine to drive.")

    def test_03_grave_back_to_record_re_routes_to_record_engine(self) -> None:
        # Inherits source-tab-displayed state from test_02. Toggle back
        # via Grave and confirm routing follows.
        self.key("Grave")
        self.wait_for(
            'return require("core.debug_helpers").displayed_tab_kind() == "record"',
            timeout=5.0)

        self.assertEvalEqual(
            "record",
            'return require("core.debug_helpers").transport_target()',
            msg=("after Grave toggled back to record tab, transport target "
                 "must be 'record' again — routing must track the displayed "
                 "tab on every change, not just on initial wiring."))

if __name__ == "__main__":
    unittest.main()
