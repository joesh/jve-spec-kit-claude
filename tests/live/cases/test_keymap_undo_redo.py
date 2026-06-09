"""
``Cmd+Z`` (Undo) and ``Cmd+Shift+Z`` (Redo).

User-visible effect: Cmd+Z reverts the last user action; Cmd+Shift+Z
re-applies what was just undone. The pair forms a deterministic
A→B→A→B navigation on the action history.

Test strategy: perform a small, observable, undoable edit via a real
keypress (``D``, ToggleClipEnabled, which we already have an L3 for)
so the undo/redo machinery has a known entry on the stack. Then
press Cmd+Z, assert reverted; Cmd+Shift+Z, assert reapplied.

Domain-level assertion: the clip's ``enabled`` field traces
true → false (after D) → true (after Cmd+Z) → false (after Cmd+Shift+Z).

Run:
    python3 -m unittest tests.live.cases.test_keymap_undo_redo -v
"""

import unittest

from tests.live.runner.case import JVESmokeCase

class TestUndoRedo(JVESmokeCase):
    """Cmd+Z reverts, Cmd+Shift+Z reapplies the last action."""

    def setUp(self) -> None:
        super().setUp()
        self.ensure_record_tab()

    def _pick_clip(self) -> str:
        return self.first_armed_video_clip().id

    def _enabled(self, clip_id: str) -> bool:
        return self.eval_bool(
            f"return require('core.debug_helpers').clip_enabled('{clip_id}')")

    def test_cmd_z_reverts_and_cmd_shift_z_reapplies_an_edit(self) -> None:
        clip_id = self._pick_clip()

        # Select via real click on the clip's visual center.
        self.click_clip(clip_id)

        self.assertTrue(self._enabled(clip_id),
            "fixture precondition: clip starts enabled")

        self.focus_panel("timeline")
        self.assertEvalEqual("timeline",
            'return require("ui.focus_manager").get_focused_panel()',
            msg="focus did not anchor on timeline before D press")

        # Apply: D → enabled=false
        self.key("D")
        self.assertFalse(self._enabled(clip_id),
            "D press did not flip enabled — undo/redo coverage depends "
            "on the D path; fix D first")

        # Undo: Cmd+Z → enabled=true (back to original)
        self.key("Cmd+Z")
        self.assertTrue(self._enabled(clip_id), (
            f"after Cmd+Z, clip {clip_id} should be back to enabled=true. "
            f"Still false means Undo dispatched but didn't run the "
            f"ToggleClipEnabled undoer, or the undoer didn't restore "
            f"enabled_before."))

        # Redo: Cmd+Shift+Z → enabled=false (re-applied)
        self.key("Cmd+Shift+Z")
        self.assertFalse(self._enabled(clip_id), (
            f"after Cmd+Shift+Z, clip {clip_id} should be back to "
            f"enabled=false (re-applied). Still true means Redo "
            f"dispatched but didn't re-run the executor."))

if __name__ == "__main__":
    unittest.main()
