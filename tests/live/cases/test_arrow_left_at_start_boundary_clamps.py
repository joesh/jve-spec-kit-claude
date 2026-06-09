"""
Boundary correctness: Left arrow at the sequence start must clamp silently.

Pressing Left arrow with the playhead already at the sequence's
``start_timecode_frame`` (the timeline's lower bound) must NOT push the
playhead below that bound. Domain invariant:

    sequence.playhead_position >= sequence.start_timecode_frame

Behavior: silent clamp (option A — same family as Nudge boundary).
The playhead stops at the boundary; no error surfaced. Per the
architectural call (2026-05-21), this lives in the playhead primitive,
not in any per-command clamp.

Run:
    python3 -m unittest tests.live.cases.test_arrow_left_at_start_boundary_clamps -v
"""

import unittest

from tests.live.runner.case import JVESmokeCase

class TestArrowLeftBoundaryClamp(JVESmokeCase):
    """Left arrow with playhead at start must not violate the lower bound."""

    def test_left_arrow_at_start_does_not_go_below_start_timecode_frame(self) -> None:
        seq_id = self.eval_str(
            "local sid = require('core.debug_helpers').record_engine_sequence_id(); "
            "assert(type(sid) == 'string' and sid ~= '', "
            "       'record engine has no loaded sequence — fixture broken'); "
            "return sid")
        start_tc = self.eval_int(
            "return require('core.debug_helpers').sequence_start_tc('"
            + seq_id + "')")

        # Park the playhead exactly at the lower bound via the ruler.
        self.ensure_record_tab()
        self.move_playhead_to(start_tc)
        self.assertEqual(start_tc, self.eval_int(
            "return require('core.debug_helpers').playhead()"),
            "stage: failed to park playhead at start_timecode_frame")

        self.focus_panel("timeline")
        self.key("Left")

        playhead_after = self.eval_int(
            "return require('core.debug_helpers').playhead()")
        self.assertEqual(start_tc, playhead_after, (
            f"after Left arrow with playhead at start_timecode_frame "
            f"({start_tc}), playhead expected to stay there (silent clamp). "
            f"Got {playhead_after}. Below {start_tc} means MovePlayhead or "
            f"its delegates wrote a value violating the domain invariant "
            f"sequence.playhead_position >= sequence.start_timecode_frame."))

        # Model row must also respect the floor.
        model_after = self.eval_int(
            "return require('core.debug_helpers').playhead_of('"
            + seq_id + "')")
        self.assertEqual(start_tc, model_after,
            f"sequences.playhead_position drifted below start "
            f"({start_tc}); got {model_after}")

if __name__ == "__main__":
    unittest.main()
