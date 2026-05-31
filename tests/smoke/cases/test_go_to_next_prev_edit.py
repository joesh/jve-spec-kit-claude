"""
GoToNextEdit / GoToPrevEdit (bound to Down / Up) walk the playhead
across timeline edit points: each press lands on the next/previous
clip boundary; pressing past the end (or before the sequence's
start_timecode_frame floor) clamps. From inside a gap, Next finds
the surrounding clip's start; Prev finds the prior clip's end.
A round-trip Next then Prev from inside a clip lands at the prior
edit point, not back at the starting frame.

Pins the domain behavior of `tests/integration/test_go_to_next_prev_edit.lua`
through real Up/Down keypresses against the anamnesis fixture's
displayed record sequence.

Run:
    python3 -m unittest tests.smoke.cases.test_go_to_next_prev_edit -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestGoToNextPrevEdit(JVESmokeCase):
    """Up/Down navigation across edit points on the displayed sequence."""

    # ── fixture probes ────────────────────────────────────────────────

    def _displayed_seq_id(self) -> str:
        seq = self.eval_str(
            "return require('core.debug_helpers').displayed_sequence_id()")
        self.assertTrue(seq and seq != "nil",
            "fixture: no displayed sequence — anamnesis template should "
            "open a record sequence on launch.")
        return seq

    def _playhead(self) -> int:
        return self.eval_int(
            "return require('core.debug_helpers').playhead()")

    def _sequence_start_tc(self, seq_id: str) -> int:
        return self.eval_int(
            f"return require('core.debug_helpers').sequence_start_tc('{seq_id}')")

    def _edit_points(self) -> list:
        """Distinct clip start/end frames on the displayed sequence,
        sorted ascending — these are the edit points GoTo* walks.

        Uses the chunked producer/pager primitive (spec phase1-test-
        overhaul.md §"State queries beyond the cap") so this works on
        anamnesis (~hundreds of clips → thousands of chars of CSV)."""
        return self.fetch_int_array(
            "return require('core.debug_helpers')"
            ".compute_edit_points_on_displayed_sequence()",
            "_smoke_edit_points")

    def _park_via_ruler(self, frame: int) -> None:
        """Click the ruler at `frame` and confirm the playhead landed
        there; if the ruler-click resolution can't hit the exact frame,
        the test should still proceed with whatever frame did land —
        the navigation semantics don't require pixel-exact parking."""
        self.move_playhead_to(frame)

    # ── tests ─────────────────────────────────────────────────────────

    def test_01_down_walks_forward_through_edit_points(self) -> None:
        """Down from inside a clip lands at the next edit point;
        repeated Down walks through subsequent points in order."""
        seq = self._displayed_seq_id()
        points = self._edit_points()
        self.assertGreaterEqual(len(points), 3, (
            "fixture: need at least 3 distinct edit points on the "
            "displayed sequence to exercise forward navigation; "
            f"got {points}"))

        # Park strictly inside the first clip (between points[0] and points[1]).
        start_frame = points[0] + max(1, (points[1] - points[0]) // 2)
        self._park_via_ruler(start_frame)
        landed = self._playhead()
        self.assertGreater(landed, points[0], (
            f"setUp: ruler-click was supposed to park inside the first "
            f"clip (between {points[0]} and {points[1]}); landed at "
            f"{landed} which is at-or-before the first edit point."))
        self.assertLess(landed, points[1], (
            f"setUp: ruler-click parked at {landed}, past the first "
            f"clip's end ({points[1]}). Cannot test 'Down from inside "
            f"first clip'."))

        self.focus_panel("timeline")
        self.key("Down")
        after_one = self._playhead()
        self.assertEqual(points[1], after_one, (
            f"Down from {landed} (inside first clip) must land on the "
            f"next edit point {points[1]}; got {after_one}. The dispatch "
            f"chain (Down → GoToNextEdit → executor) is broken, or the "
            f"edit-point resolver missed a clip boundary."))

        self.key("Down")
        after_two = self._playhead()
        self.assertEqual(points[2], after_two, (
            f"Second Down from {after_one} must land on edit point "
            f"{points[2]}; got {after_two}. Edit-point traversal isn't "
            f"monotonic."))

    def test_02_down_at_last_edit_point_clamps(self) -> None:
        """Down past the final edit point must clamp (no past-end)."""
        points = self._edit_points()
        last = points[-1]

        # Park exactly at the last edit point. Ruler-click should hit it
        # within a pixel; if it doesn't, fall back to discovered landing.
        self._park_via_ruler(last)
        before = self._playhead()

        self.focus_panel("timeline")
        self.key("Down")
        after = self._playhead()
        self.assertEqual(before, after, (
            f"Down at the last edit point {last} (parked at {before}) "
            f"must clamp (no past-end navigation); playhead moved to "
            f"{after}. GoToNextEdit walked past the final boundary, "
            f"which would trip PlaybackEngine seek asserts."))

    def test_03_up_walks_backward_through_edit_points(self) -> None:
        """Up from inside a clip lands at the previous edit point;
        repeated Up walks backward in order."""
        points = self._edit_points()
        self.assertGreaterEqual(len(points), 3, (
            f"fixture needs ≥3 edit points; got {points}"))

        # Park inside the LAST clip (between points[-2] and points[-1]).
        start_frame = points[-2] + max(1, (points[-1] - points[-2]) // 2)
        self._park_via_ruler(start_frame)
        landed = self._playhead()
        self.assertGreater(landed, points[-2], (
            f"setUp: failed to park inside last clip; landed at {landed}"))
        self.assertLess(landed, points[-1], (
            f"setUp: parked at {landed}, past last clip end {points[-1]}"))

        self.focus_panel("timeline")
        self.key("Up")
        after_one = self._playhead()
        self.assertEqual(points[-2], after_one, (
            f"Up from {landed} (inside last clip) must land on the "
            f"previous edit point {points[-2]}; got {after_one}. "
            f"Backward traversal is broken."))

        self.key("Up")
        after_two = self._playhead()
        self.assertEqual(points[-3], after_two, (
            f"Second Up from {after_one} must land on edit point "
            f"{points[-3]}; got {after_two}."))

    def test_04_up_at_sequence_start_floor_clamps(self) -> None:
        """Up at the sequence's start_timecode_frame must clamp — never
        walk below the TC floor (which would trip PlaybackEngine.seek's
        below-start_frame assert). Regression: GoToPrevEdit used to
        seed its edit-point list with `{0}`, which floored at 0 instead
        of the sequence's TC origin."""
        seq = self._displayed_seq_id()
        start_tc = self._sequence_start_tc(seq)
        points = self._edit_points()

        # The first edit point should be at-or-after start_tc.
        floor = min(points[0], start_tc)

        self._park_via_ruler(floor)
        before = self._playhead()

        self.focus_panel("timeline")
        self.key("Up")
        after = self._playhead()
        self.assertGreaterEqual(after, start_tc, (
            f"Up at sequence floor (parked at {before}, start_tc="
            f"{start_tc}) must NOT walk below start_timecode_frame; "
            f"playhead landed at {after} which is below the TC floor. "
            f"This trips PlaybackEngine.seek's below-start_frame assert "
            f"in every listener — a handler-failure storm, not a "
            f"recoverable miss."))
        self.assertLessEqual(after, before, (
            f"Up at sequence floor must move backward or clamp; "
            f"playhead moved forward from {before} to {after}."))

    def test_05_round_trip_down_then_up_lands_at_prior_edit_not_start(self) -> None:
        """Down then Up from inside a clip lands on the PREVIOUS edit
        point, not back at the start frame. Prev jumps to the previous
        edit, not back to where Next started from."""
        points = self._edit_points()
        # Park inside first clip.
        start_frame = points[0] + max(1, (points[1] - points[0]) // 2)
        self._park_via_ruler(start_frame)
        landed = self._playhead()
        self.assertGreater(landed, points[0])
        self.assertLess(landed, points[1])

        self.focus_panel("timeline")
        self.key("Down")
        after_down = self._playhead()
        self.assertEqual(points[1], after_down,
            f"setUp: Down should land at {points[1]}; got {after_down}")

        self.key("Up")
        after_up = self._playhead()
        self.assertEqual(points[0], after_up, (
            f"Round-trip Down→Up from {landed} (inside first clip) must "
            f"land on the previous edit point {points[0]}, not back at "
            f"the starting frame {landed}. Got {after_up}. Up is "
            f"incorrectly remembering the pre-Down position instead of "
            f"walking to the prior edit."))


if __name__ == "__main__":
    unittest.main()
