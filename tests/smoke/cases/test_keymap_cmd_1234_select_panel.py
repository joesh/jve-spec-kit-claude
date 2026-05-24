"""
``Cmd+1`` / ``Cmd+2`` / ``Cmd+3`` / ``Cmd+4`` (SelectPanel) — focus a
named panel.

Per keymap:
    Cmd+1 = SelectPanel source_monitor
    Cmd+2 = SelectPanel inspector
    Cmd+3 = SelectPanel timeline
    Cmd+4 = SelectPanel project_browser

Domain-level assertion: after each press,
``focus_manager.get_focused_panel()`` returns the target panel id.

Run:
    python3 -m unittest tests.smoke.cases.test_keymap_cmd_1234_select_panel -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


# Keymap binding → expected focused panel id, captured here so any
# rebinding in keymaps/default.jvekeys requires updating this table
# in the same commit — the test breaks loudly otherwise.
PANEL_BINDINGS: list[tuple[str, str]] = [
    ("Cmd+1", "source_monitor"),
    ("Cmd+2", "inspector"),
    ("Cmd+3", "timeline"),
    ("Cmd+4", "project_browser"),
]


class TestCmd1234SelectPanel(JVESmokeCase):
    """Each Cmd+N focuses the panel its keymap entry names."""

    def _focused_panel(self) -> str:
        return self.eval_str(
            "return require('ui.focus_manager').get_focused_panel() or ''")

    def test_cmd_1_2_3_4_focus_their_named_panels(self) -> None:
        # Anchor on something OTHER than each target so the focus
        # shift is observable. Cycle from timeline → press → expect
        # target. Between iterations, reset to timeline so the next
        # cmd+n's shift is a real movement.
        for combo, expected in PANEL_BINDINGS:
            self.focus_panel("timeline")
            self.assertEvalEqual("timeline",
                'return require("ui.focus_manager").get_focused_panel()',
                msg=f"setup: failed to anchor on timeline before {combo}")
            if expected == "timeline":
                # Edge case: Cmd+3 → timeline. Anchor elsewhere so the
                # shift is detectable.
                self.focus_panel("source_monitor")
                self.assertEvalEqual("source_monitor",
                    'return require("ui.focus_manager").get_focused_panel()',
                    msg=f"setup: failed to anchor off-target before {combo}")
            self.key(combo)
            actual = self._focused_panel()
            self.assertEqual(expected, actual, (
                f"after {combo} press, focused panel should be "
                f"{expected!r}. Got {actual!r}. SelectPanel either "
                f"dispatched to the wrong panel id (keymap arg mismatch) "
                f"or focus_manager.focus_panel didn't accept the request."))


if __name__ == "__main__":
    unittest.main()
