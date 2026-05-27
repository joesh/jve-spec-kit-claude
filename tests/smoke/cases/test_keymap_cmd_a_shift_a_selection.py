"""
``Cmd+A`` (SelectAll) and ``Cmd+Shift+A`` (DeselectAll) on @timeline.

Cmd+A: replace timeline selection with every non-gap clip on the
displayed sequence. (Per ``select_all.lua``, gaps are filtered — they
are derived state, not selectable clips.)

Cmd+Shift+A: clear selection.

Domain-level assertions:
  - Cmd+A: selection size equals the count of non-gap clips on the
    displayed sequence.
  - Cmd+Shift+A: selection is empty.

Run:
    python3 -m unittest tests.smoke.cases.test_keymap_cmd_a_shift_a_selection -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestCmdASelectAllAndDeselectAll(JVESmokeCase):

    def setUp(self) -> None:
        super().setUp()
        self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            "if ts.get_displayed_tab_kind() ~= 'record' then "
            "  local active = ts.get_active_sequence_id(); "
            "  if active then ts.switch_to_record_tab(active) end "
            "end")

    def _selection_count(self) -> int:
        return self.eval_int(
            "return #require('ui.timeline.timeline_state').get_selected_clips()")

    def _non_gap_clip_count(self) -> int:
        return self.eval_int(
            "local n = 0; "
            "for _, c in ipairs(require('ui.timeline.timeline_state').get_tab_strip():displayed_clips()) do "
            "  if not c.is_gap then n = n + 1 end "
            "end; return n")

    def test_cmd_a_selects_every_non_gap_clip(self) -> None:
        self.focus_panel("timeline")
        self.assertEvalEqual("timeline",
            'return require("ui.focus_manager").get_focused_panel()',
            msg="focus did not anchor on timeline before Cmd+A press")

        total_non_gap = self._non_gap_clip_count()
        self.assertGreater(total_non_gap, 0,
            "fixture precondition: displayed sequence must have at least "
            "one non-gap clip for SelectAll to be observable")

        self.key("Cmd+A")
        self.assertEqual(total_non_gap, self._selection_count(), (
            f"after Cmd+A, expected selection to hold every non-gap clip "
            f"({total_non_gap}). Got {self._selection_count()}. SelectAll "
            f"either didn't fire, filtered the wrong clips, or wrote to "
            f"the wrong state cache."))

    def test_cmd_shift_a_clears_selection(self) -> None:
        self.focus_panel("timeline")
        # Seed the selection via Cmd+A so DeselectAll has something to
        # clear. Reusing the same dispatch path keeps the test agnostic
        # to selection-internals.
        self.key("Cmd+A")
        self.assertGreater(self._selection_count(), 0,
            "seed: Cmd+A should have populated selection before "
            "testing Cmd+Shift+A")

        self.key("Cmd+Shift+A")
        self.assertEqual(0, self._selection_count(), (
            f"after Cmd+Shift+A, selection should be empty. Got "
            f"{self._selection_count()} clip(s) still selected. "
            f"DeselectAll either didn't fire or only cleared part of the "
            f"selection."))


if __name__ == "__main__":
    unittest.main()
