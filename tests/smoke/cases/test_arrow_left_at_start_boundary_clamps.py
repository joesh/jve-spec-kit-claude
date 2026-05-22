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
    python3 -m unittest tests.smoke.cases.test_arrow_left_at_start_boundary_clamps -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestArrowLeftBoundaryClamp(JVESmokeCase):
    """Left arrow with playhead at start must not violate the lower bound."""

    def test_left_arrow_at_start_does_not_go_below_start_timecode_frame(self) -> None:
        seq_id = self.eval_str(
            "local sid = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(type(sid) == 'string' and sid ~= '', "
            "       'record engine has no loaded sequence — fixture broken'); "
            "return sid")
        start_tc = self.eval_int(
            "return require('models.sequence').load('"
            + seq_id + "').start_timecode_frame")

        # Park the engine exactly at the lower bound.
        self.eval(
            "require('core.command_manager').execute('SetPlayhead', "
            f"{{ sequence_id='{seq_id}', playhead_position={start_tc} }})")
        self.assertEqual(start_tc, self.eval_int(
            "return require('core.playback.transport')"
            ".engine_for_target():get_position()"),
            "stage: failed to park engine at start_timecode_frame")

        self.focus_panel("timeline")
        self.key("Left")

        engine_after = self.eval_int(
            "return require('core.playback.transport')"
            ".engine_for_target():get_position()")
        self.assertEqual(start_tc, engine_after, (
            f"after Left arrow with playhead at start_timecode_frame "
            f"({start_tc}), engine expected to stay there (silent clamp). "
            f"Got {engine_after}. Below {start_tc} means MovePlayhead or "
            f"its delegates wrote a value violating the domain invariant "
            f"sequence.playhead_position >= sequence.start_timecode_frame."))

        # Model row must also respect the floor.
        model_after = self.eval_int(
            "return require('models.sequence').load('"
            + seq_id + "').playhead_position")
        self.assertEqual(start_tc, model_after,
            f"sequences.playhead_position drifted below start "
            f"({start_tc}); got {model_after}")


if __name__ == "__main__":
    unittest.main()
