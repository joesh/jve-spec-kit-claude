"""
GoToNextEdit / GoToPrevEdit (Down / Up) must SURFACE the playhead — when
the destination edit point lies outside the current viewport, the
viewport scrolls so the new playhead is on-screen. Regression for an
earlier bug where these commands wrote only the playhead state and
bypassed the surface_playhead step (unlike GoToStart/GoToEnd), so
pressing Down/Up onto an off-screen clip moved the playhead invisibly.

Pins the domain behavior of
``tests/integration/test_go_to_edit_surfaces_playhead.lua`` against the
anamnesis fixture's displayed record sequence: pick two well-separated
edit points, narrow the viewport to exclude the far one, press Down/Up,
assert the viewport now contains the new playhead.

Run:
    python3 -m unittest tests.smoke.cases.test_go_to_edit_surfaces_playhead -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestGoToEditSurfacesPlayhead(JVESmokeCase):
    """Down/Up onto an off-screen edit point scrolls the viewport."""

    # ── fixture probes ────────────────────────────────────────────────

    def _playhead(self) -> int:
        return self.eval_int(
            "return require('core.debug_helpers').playhead()")

    def _viewport(self) -> tuple[int, int]:
        """Return (start_frame, duration_frames) of the current viewport."""
        raw = self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            "local s = ts.get_viewport_start_time(); "
            "local d = ts.get_viewport_duration(); "
            "assert(type(s) == 'number' and type(d) == 'number', "
            "       'viewport not initialized'); "
            "return string.format('%d,%d', s, d)")
        s, d = raw.strip('"').split(",", 1)
        return int(s), int(d)

    def _edit_points(self) -> list:
        """Distinct clip start/end frames on the displayed sequence,
        sorted ascending — these are the edit points Down/Up walks.

        Uses the chunked producer/pager primitive (spec phase1-test-
        overhaul.md §"State queries beyond the cap") so this works on
        anamnesis (~hundreds of clips → thousands of chars of CSV)."""
        return self.fetch_int_array(
            "return require('core.debug_helpers')"
            ".compute_edit_points_on_displayed_sequence()",
            "_smoke_edit_points")

    def _set_viewport(self, start_frame: int, duration: int) -> None:
        """Narrow the viewport — view-layer setup, not model mutation."""
        self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            f"ts.set_viewport_duration({duration}); "
            f"ts.set_viewport_start_time({start_frame})")

    def _park_via_ruler(self, frame: int) -> None:
        self.move_playhead_to(frame)

    # ── tests ─────────────────────────────────────────────────────────

    def test_01_down_to_off_screen_edit_scrolls_viewport(self) -> None:
        """Park at an early edit point, narrow the viewport to exclude
        the next edit point, press Down: playhead lands on the next edit
        AND the viewport scrolls to contain it."""
        points = self._edit_points()
        self.assertGreaterEqual(len(points), 2, (
            f"fixture needs >=2 edit points on the displayed sequence to "
            f"exercise off-screen Down navigation; got {points}"))

        # Find an adjacent pair (a, b) with a large gap between them so
        # we can fit a viewport around `a` that excludes `b`.
        pair = None
        for i in range(len(points) - 1):
            if points[i + 1] - points[i] >= 200:
                pair = (points[i], points[i + 1])
                break
        self.assertIsNotNone(pair, (
            f"fixture: no adjacent edit points >=200 frames apart on the "
            f"displayed sequence; cannot construct an off-screen target. "
            f"Edit points: {points}"))
        a, b = pair  # type: ignore[misc]

        self._park_via_ruler(a)
        landed = self._playhead()

        # Viewport: 100 frames wide, centered roughly on `a`. Excludes `b`.
        vp_start = max(0, a - 50)
        vp_dur = 100
        self._set_viewport(vp_start, vp_dur)
        vp_s, vp_d = self._viewport()
        self.assertLess(vp_s + vp_d, b, (
            f"setUp: narrowed viewport [{vp_s}, {vp_s + vp_d}) still "
            f"contains next edit point {b}; cannot exercise off-screen "
            f"surface. Pick a wider edit-point gap."))

        self.focus_panel("timeline")
        self.key("Down")

        after = self._playhead()
        self.assertEqual(b, after, (
            f"Down from {landed} must land on next edit point {b}; got "
            f"{after}. Either dispatch broke or edit-point traversal "
            f"missed a boundary."))

        new_s, new_d = self._viewport()
        self.assertTrue(new_s <= b <= new_s + new_d, (
            f"viewport [{new_s}, {new_s + new_d}) must contain playhead "
            f"{b} — surface_playhead should have scrolled to bring the "
            f"off-screen target on-screen. Pre-press viewport was "
            f"[{vp_s}, {vp_s + vp_d}). Regression: GoToNextEdit wrote the "
            f"playhead without surfacing it, leaving the user looking at "
            f"a viewport that no longer contains the playhead."))

    def test_02_up_to_off_screen_edit_scrolls_viewport(self) -> None:
        """Park at a later edit point, narrow the viewport to exclude
        the previous edit point, press Up: playhead lands on the prev
        edit AND the viewport scrolls to contain it."""
        points = self._edit_points()
        self.assertGreaterEqual(len(points), 2,
            f"fixture needs >=2 edit points; got {points}")

        pair = None
        for i in range(len(points) - 1):
            if points[i + 1] - points[i] >= 200:
                pair = (points[i], points[i + 1])
                break
        self.assertIsNotNone(pair, (
            f"fixture: no adjacent edit points >=200 frames apart. "
            f"Edit points: {points}"))
        a, b = pair  # type: ignore[misc]

        self._park_via_ruler(b)
        landed = self._playhead()

        # Viewport: 100 frames wide around `b`. Excludes `a`.
        vp_start = max(0, b - 50)
        vp_dur = 100
        self._set_viewport(vp_start, vp_dur)
        vp_s, vp_d = self._viewport()
        self.assertGreater(vp_s, a, (
            f"setUp: narrowed viewport [{vp_s}, {vp_s + vp_d}) still "
            f"contains previous edit point {a}; cannot exercise "
            f"off-screen surface for Up."))

        self.focus_panel("timeline")
        self.key("Up")

        after = self._playhead()
        self.assertEqual(a, after, (
            f"Up from {landed} must land on previous edit point {a}; "
            f"got {after}."))

        new_s, new_d = self._viewport()
        self.assertTrue(new_s <= a <= new_s + new_d, (
            f"viewport [{new_s}, {new_s + new_d}) must contain playhead "
            f"{a} after Up — surface_playhead should have scrolled. "
            f"Pre-press viewport was [{vp_s}, {vp_s + vp_d}). Regression: "
            f"GoToPrevEdit wrote the playhead without surfacing it."))


if __name__ == "__main__":
    unittest.main()
