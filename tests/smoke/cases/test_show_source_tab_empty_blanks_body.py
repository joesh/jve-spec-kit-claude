"""
ToggleSourceRecordTab with an empty source viewer must blank the
timeline body — never auto-seed a random project master from the DB.
(TSO 2026-05-17 retired the "fabricated user intent" auto-seed path.)

Pins the same domain behavior as the originating Lua integration test
``tests/integration/test_show_source_tab_empty_blanks_body.lua``:
when no master is loaded in the source viewer and the user asks to
display the source tab (Grave key → ToggleSourceRecordTab), the
record clips disappear, the displayed tab goes nil, and the source
monitor remains unloaded — no random master from the project DB gets
silently adopted.

NOTE: The Lua test also exercises a direct ``ShowSourceTab`` command
path. ShowSourceTab has no keybinding in keymaps/default.jvekeys, so
only the keyboard-reachable ToggleSourceRecordTab variant is covered
here — driving ShowSourceTab from a smoke would require a menu pick
that doesn't currently exist. The empty-source branch of both
commands is the same code path in the executor.

Run:
    python3 -m unittest tests.smoke.cases.test_show_source_tab_empty_blanks_body -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestEmptySourceTabBlanksBody(JVESmokeCase):
    """Grave with no source loaded blanks the body, doesn't auto-seed."""

    def setUp(self) -> None:
        # Pristine fixture: prior smokes in the suite may have loaded a
        # master into the source viewer (Shift+F variants). The whole
        # premise here is "source viewer is EMPTY" — reset to guarantee.
        super().setUp()
        self._reset_to_template()

    def test_grave_with_empty_source_blanks_body_and_does_not_auto_seed(self) -> None:
        # ---- Preconditions: record tab displayed, source viewer empty ----
        self.ensure_record_tab()
        self.assertEvalEqual(
            "record",
            'return require("core.debug_helpers").displayed_tab_kind()',
            msg="fixture: record tab must be displayed before Grave press")

        # Source monitor empty — the whole point of the test.
        src_seq = self.eval(
            'return tostring(require("core.debug_helpers")'
            '.source_viewer_sequence_id())')
        self.assertEqual(
            src_seq.strip('"'), "nil",
            "fixture: source viewer must start empty (no master loaded). "
            "A prior test left a master loaded — reset_to_template should "
            "have cleared it.")

        # Record tab must actually have clips, otherwise the "blanked"
        # assertion below is vacuous.
        clips_before = self.eval_int(
            'return require("core.debug_helpers").displayed_clips_count()')
        self.assertGreater(
            clips_before, 0,
            "fixture: record tab must show clips pre-command; otherwise "
            "the post-Grave blank-body assertion proves nothing")

        # Bait: the project DB must contain at least one master sequence
        # that an auto-seed regression could grab. Anamnesis template has
        # many masters, so this is normally trivially true — assert
        # anyway so the regression-detection power is explicit.
        seq_count = self.eval_int(
            'return require("core.debug_helpers").sequence_count()')
        self.assertGreater(
            seq_count, 1,
            "fixture: project must have >1 sequence (a record + at least "
            "one master) so an auto-seed bug would have bait to grab")

        # ---- Real OS keypress: Grave from @timeline scope ----
        self.focus_panel("timeline")
        self.key("Grave")

        # ---- Post: body blanked, displayed tab nil, source still empty ----
        displayed_kind = self.eval(
            'return tostring(require("core.debug_helpers")'
            '.displayed_tab_kind())')
        self.assertEqual(
            displayed_kind.strip('"'), "nil",
            "ToggleSourceRecordTab on empty source: displayed_tab_kind "
            "must be nil (no tab shown), got " + displayed_kind)

        clips_after = self.eval_int(
            'return require("core.debug_helpers").displayed_clips_count()')
        self.assertEqual(
            clips_after, 0,
            "ToggleSourceRecordTab on empty source: timeline body must "
            f"be blank, got {clips_after} clips")

        # Auto-seed regression: source monitor must STILL be empty. If
        # this is non-nil, the command silently grabbed a random master
        # from the DB and seeded the source viewer with it — that's the
        # exact behavior TSO 2026-05-17 retired.
        src_seq_after = self.eval(
            'return tostring(require("core.debug_helpers")'
            '.source_viewer_sequence_id())')
        self.assertEqual(
            src_seq_after.strip('"'), "nil",
            "AUTO-SEED REGRESSION: ToggleSourceRecordTab with empty "
            "source must NOT load a random master into source_viewer; "
            f"got sequence_id={src_seq_after}")


if __name__ == "__main__":
    unittest.main()
