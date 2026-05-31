"""
Phase A Tier 1 — ``Grave`` key delivers to ToggleSourceRecordTab.

Spec 020 phase1-test-overhaul.md FR / Axis 2. Single-key smoke that
verifies the full dispatch chain works end-to-end through real OS
keypresses delivered to a foregrounded JVE:

    keymap parse → QShortcut registration → modifier normalization
                 → focus-scope check → handler dispatch
                 → command_manager.execute → executor side effects

Regression target: 2026-05-20 silent-dead-key class
(``E``/``Comma``/``Period``/``Grave`` and friends dispatched cleanly
in unit tests while doing nothing in the running app).

Domain-level black-box assertion: ToggleSourceRecordTab's executor
ends with ``focus_manager.focus_panel("timeline")``. If the keypress
reaches the command, focus shifts to the timeline panel; if anything
upstream (QShortcut registration, scope cascade, focus filter) drops
the press, focus stays where it was.

Run:
    python3 -m unittest tests.smoke.cases.test_keymap_grave_toggles_tab -v
"""

import unittest

from tests.smoke.runner.case import JVESmokeCase

class TestGraveToggleSourceRecordTab(JVESmokeCase):
    """Grave on @source_monitor must hand focus to the timeline."""

    def test_grave_from_source_monitor_focuses_timeline(self) -> None:
        # Anchor focus on the source monitor — that's one of the three
        # scopes Grave is bound to in keymaps/default.jvekeys, and it is
        # NOT the panel the executor moves focus to, so the post-press
        # observation is unambiguous.
        self.focus_panel("source_monitor")
        self.assertEvalEqual(
            "source_monitor",
            'return require("ui.focus_manager").get_focused_panel()',
            msg="setUp: focus did not anchor on source_monitor")

        # Real OS keypress through System Events.
        self.key("Grave")

        # Executor's last action is focus_panel("timeline"). Real
        # dispatch chain → focus follows. Broken dispatch → unchanged.
        self.assertEvalEqual(
            "timeline",
            'return require("ui.focus_manager").get_focused_panel()',
            msg=("Grave keypress did not reach ToggleSourceRecordTab — "
                 "focus stayed on source_monitor. The dispatch chain "
                 "(keymap → QShortcut → scope cascade → executor) is "
                 "broken somewhere upstream of the executor."))

if __name__ == "__main__":
    unittest.main()
