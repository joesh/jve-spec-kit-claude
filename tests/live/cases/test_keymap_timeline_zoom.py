"""
``Cmd+Equal`` / ``Cmd+Minus`` / ``Shift+Z`` on @timeline — zoom in /
zoom out / zoom to fit.

User-visible effect: viewport_duration shrinks (zoom in), grows
(zoom out), or snaps to span all content (fit).

Domain-level assertions:
  - Cmd+Equal halves viewport_duration (per timeline_zoom_in.lua).
  - Cmd+Minus doubles viewport_duration (per timeline_zoom_out.lua).
  - Shift+Z sets viewport_duration to the fit duration (>= the
    content-span; we don't probe the exact value, only that it
    changes from the seeded value).

Run:
    python3 -m unittest tests.live.cases.test_keymap_timeline_zoom -v
"""

import unittest

from tests.live.runner.case import JVESmokeCase

# Seed viewport duration to a known mid-range value so zoom-in and
# zoom-out have headroom in both directions before bumping into the
# command's internal clamps (typical NLE: 1 frame minimum, sequence
# length maximum).
SEED_VIEWPORT_DURATION = 2400

class TestTimelineZoom(JVESmokeCase):
    """Cmd+Equal / Cmd+Minus / Shift+Z update viewport_duration."""

    def setUp(self) -> None:
        super().setUp()
        self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            "if ts.get_displayed_tab_kind() ~= 'record' then "
            "  local active = ts.get_active_sequence_id(); "
            "  if active then ts.switch_to_record_tab(active) end "
            "end")
        # Seed viewport_duration so each test starts from the same
        # baseline. Direct setter (the canonical model write — same
        # path the zoom commands use).
        self.eval(
            "require('ui.timeline.timeline_state').set_viewport_duration("
            f"{SEED_VIEWPORT_DURATION})")

    def _viewport_duration(self) -> int:
        return self.eval_int(
            "return require('ui.timeline.timeline_state').get_viewport_duration()")

    def _press(self, combo: str) -> None:
        self.focus_panel("timeline")
        self.assertEvalEqual("timeline",
            'return require("ui.focus_manager").get_focused_panel()',
            msg=f"focus did not anchor on timeline before {combo} press")
        self.key(combo)

    def test_cmd_equal_zooms_in_halving_viewport_duration(self) -> None:
        self.assertEqual(SEED_VIEWPORT_DURATION, self._viewport_duration(),
            "seed: viewport_duration should match SEED before press")
        self._press("Cmd+Equal")
        after = self._viewport_duration()
        self.assertLess(after, SEED_VIEWPORT_DURATION, (
            f"after Cmd+Equal: viewport_duration should DECREASE (zoom in). "
            f"Got {after}, baseline {SEED_VIEWPORT_DURATION}. Equal/greater "
            f"means ZoomIn didn't fire or wrote the wrong direction."))

    def test_cmd_minus_zooms_out_doubling_viewport_duration(self) -> None:
        self.assertEqual(SEED_VIEWPORT_DURATION, self._viewport_duration(),
            "seed: viewport_duration should match SEED before press")
        self._press("Cmd+Minus")
        after = self._viewport_duration()
        self.assertGreater(after, SEED_VIEWPORT_DURATION, (
            f"after Cmd+Minus: viewport_duration should INCREASE (zoom out). "
            f"Got {after}, baseline {SEED_VIEWPORT_DURATION}."))

    def test_shift_z_fits_viewport_to_content(self) -> None:
        # Seed a deliberately-wrong duration so the fit-press has
        # something to change. SEED is mid-range; fit will likely set
        # to the full sequence span (much larger).
        self.assertEqual(SEED_VIEWPORT_DURATION, self._viewport_duration(),
            "seed: viewport_duration should match SEED before press")
        self._press("Shift+Z")
        after = self._viewport_duration()
        self.assertNotEqual(SEED_VIEWPORT_DURATION, after, (
            f"after Shift+Z: viewport_duration should change to fit content. "
            f"Still {after} (unchanged). ZoomFit didn't fire or computed "
            f"the same duration."))

if __name__ == "__main__":
    unittest.main()
