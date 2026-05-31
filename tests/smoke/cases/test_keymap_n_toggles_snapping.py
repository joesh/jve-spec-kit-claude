"""
``N`` on @timeline (ToggleSnapping) — pressing N flips the timeline's
baseline magnetic-snapping preference.

User-visible effect: when snapping is ON, drag operations snap to
nearby edits / playhead / mark positions. When OFF, drags move
freely. The N key toggles the preference (Avid/Premiere convention).

Per `core/commands/toggle_snapping.lua`, N's behavior is
context-aware: during an active drag it temporarily inverts snapping
for that drag only. With no active drag (this test), it toggles the
baseline. We exercise the no-drag baseline path.

Domain-level assertion: ``snapping_state.is_enabled()`` flips after
each N press. The test reads the current value, presses, asserts
flipped; presses again, asserts back. Symmetric toggle.

Run:
    python3 -m unittest tests.smoke.cases.test_keymap_n_toggles_snapping -v
"""

import unittest

from tests.smoke.runner.case import JVESmokeCase

class TestNTogglesSnapping(JVESmokeCase):
    """N on @timeline flips the baseline snapping preference."""

    def _snap_enabled(self) -> bool:
        return self.eval_bool(
            "return require('ui.timeline.state.snapping_state').is_enabled()")

    def test_n_flips_snapping_baseline_symmetrically(self) -> None:
        self.focus_panel("timeline")
        self.assertEvalEqual("timeline",
            'return require("ui.focus_manager").get_focused_panel()',
            msg="focus did not anchor on timeline before N press")

        before = self._snap_enabled()
        self.key("N")
        after_one = self._snap_enabled()
        self.assertNotEqual(before, after_one, (
            f"after N press, snapping baseline should have flipped. "
            f"before={before}, after={after_one}. If unchanged, the "
            f"keypress didn't reach ToggleSnapping or toggle_baseline "
            f"didn't fire."))

        self.key("N")
        after_two = self._snap_enabled()
        self.assertEqual(before, after_two, (
            f"after second N press, snapping baseline should return to "
            f"original. before={before}, after={after_two}. Asymmetric "
            f"toggle means the command is reading from the wrong state "
            f"on the second press."))

if __name__ == "__main__":
    unittest.main()
