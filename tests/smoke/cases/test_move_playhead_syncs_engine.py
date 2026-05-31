"""
Regression net for MovePlayhead's engine-sync contract.

After MovePlayhead by +N frames, the displayed-side engine reports
start + N (where ``start`` is the seeded baseline, not necessarily
the sequence's TC origin). Pure behavioural — the test doesn't peek
at which code path did the seek, just that the engine arrives at
the expected frame.

Engine sync today flows through transport's playhead_changed
listener: MovePlayhead writes the model + emits the signal;
transport's listener (registered at init) seeks every engine bound
to the sequence.

Run:
    python3 -m unittest tests.smoke.cases.test_move_playhead_syncs_engine -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


DELTA_FRAMES = 50


class TestMovePlayheadSyncsEngine(JVESmokeCase):
    """MovePlayhead must move the displayed engine, not just the model."""

    def test_move_playhead_advances_engine_by_delta(self) -> None:
        seq_id = self.eval_str(
            "return require('core.debug_helpers').record_engine_sequence_id()")
        assert seq_id, "record engine has no loaded sequence — fixture broken"

        # Seed the engine to a known absolute frame via the ruler.
        start = self.eval_int(
            "return require('core.debug_helpers')"
            f".sequence_start_tc('{seq_id}')")
        self.move_playhead_to(start)
        seeded = self.eval_int(
            "return require('core.playback.transport')"
            ".engine_for_target():get_position()")
        self.assertEqual(start, seeded,
            f"seed precondition: ruler-click at {start} left engine at {seeded}")

        # Step by DELTA_FRAMES via MovePlayhead's positional delta literal.
        # command under test — driven directly because there is no keyboard
        # analogue for an exact N-frame relative jump (arrows move by 1).
        self.eval(
            "require('core.command_manager').execute('MovePlayhead', "
            f"{{ _positional = {{ '{DELTA_FRAMES}f' }} }})")

        engine_pos = self.eval_int(
            "return require('core.playback.transport')"
            ".engine_for_target():get_position()")
        self.assertEqual(start + DELTA_FRAMES, engine_pos, (
            f"MovePlayhead({DELTA_FRAMES}f) left engine at {engine_pos}; "
            f"expected {start + DELTA_FRAMES}. The engine-sync path "
            f"(model write → playhead_changed → transport listener → "
            f"engine.seek) is not reaching the displayed-side engine."))

        # Model row should also reflect the new playhead — MovePlayhead
        # writes sequences.playhead_position before emitting the signal.
        model_playhead = self.eval_int(
            "return require('models.sequence').load('"
            + seq_id + "').playhead_position")
        self.assertEqual(start + DELTA_FRAMES, model_playhead,
            f"sequences.playhead_position after MovePlayhead expected "
            f"{start + DELTA_FRAMES}, got {model_playhead}")


if __name__ == "__main__":
    unittest.main()
