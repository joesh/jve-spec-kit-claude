"""
Boundary correctness: setting the playhead below start_timecode_frame
must clamp to the boundary.

ANY playhead-write surface (SetPlayhead, MovePlayhead, GoToMark*,
GoToStart, ruler click, scrub) must respect:

    sequence.playhead_position >= sequence.start_timecode_frame

Currently SetPlayhead is unclamped: a request for start_tc - N writes
that exact value to the sequence row, while the engine (which has its
own lower-bound assert) refuses to seek. Result: split-state — model
row corrupted, engine valid. The model row wins on next read, so the
UI ends up displaying a playhead below the timeline start.

Architectural fix (Joe's call): clamp in the playhead PRIMITIVE, not
per-command. One source of truth for the invariant; SetPlayhead /
MovePlayhead / GoToStart / GoToEnd / GoToMark / park_at all delegate.
This test pins SetPlayhead-below-start; the primitive will close the
rest of the surface.

Run:
    python3 -m unittest tests.smoke.cases.test_playhead_below_start_clamps -v
"""

import unittest

from tests.smoke.runner.case import JVESmokeCase

class TestSetPlayheadBelowStartClamps(JVESmokeCase):
    """SetPlayhead with frame < start_timecode_frame must clamp silently."""

    def test_set_playhead_below_start_does_not_corrupt_model(self) -> None:
        seq_id = self.eval_str(
            "local sid = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(type(sid) == 'string' and sid ~= '', "
            "       'record engine has no loaded sequence — fixture broken'); "
            "return sid")
        start_tc = self.eval_int(
            "return require('models.sequence').load('"
            + seq_id + "').start_timecode_frame")
        below = start_tc - 50

        # Request a frame 50 below the lower bound via the lower-level
        # TC-entry primitive (move_playhead_to post-asserts playhead ==
        # requested frame, which is the exact assumption this test is
        # designed to break).
        self.type_in_tc_field(f"{below}f")

        # Both the model row AND the engine MUST land at start_tc
        # (silent clamp). Today the model corrupts; the engine refuses.
        model_after = self.eval_int(
            "return require('models.sequence').load('"
            + seq_id + "').playhead_position")
        engine_after = self.eval_int(
            "return require('core.playback.transport')"
            ".engine_for_target():get_position()")

        self.assertEqual(start_tc, model_after, (
            f"SetPlayhead({below}) wrote {model_after} to sequence row, "
            f"below start_timecode_frame={start_tc}. Domain invariant "
            f"sequence.playhead_position >= sequence.start_timecode_frame "
            f"violated. Primitive-level clamp missing."))
        self.assertEqual(start_tc, engine_after, (
            f"engine reports {engine_after} after SetPlayhead({below}); "
            f"expected start_tc={start_tc} (silent clamp)."))

if __name__ == "__main__":
    unittest.main()
