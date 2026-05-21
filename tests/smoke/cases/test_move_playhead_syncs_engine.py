"""
Regression net for MovePlayhead's engine-sync contract.

MovePlayhead currently does the engine sync two ways: it emits
``playhead_changed`` (which ``sequence_monitor.lua:188-193`` listens to
and uses to seek the bound engine) AND it explicitly calls
``transport.seek_target_if_loaded`` itself. The explicit call is
redundant with the listener path — the I-key smoke test proves the
listener path reaches the engine end-to-end (SetPlayhead emits the
same signal and the engine follows). This test pins the contract
("after MovePlayhead the engine reports the new frame") so the
explicit call can be safely removed without losing the guarantee.

Domain assertion: after MovePlayhead by +N frames, the displayed-side
engine reports start + N (where ``start`` is the seeded baseline,
not necessarily the sequence's TC origin). Pure behavioural — the
test doesn't peek at which code path did the seek, just that the
engine arrives at the expected frame.

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
            "local sid = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(type(sid) == 'string' and sid ~= '', "
            "       'record engine has no loaded sequence — fixture broken'); "
            "return sid")

        # Seed the engine to a known absolute frame.
        start = self.eval_int(
            "return require('models.sequence').load('"
            + seq_id + "').start_timecode_frame")
        self.eval(
            "require('core.command_manager').execute('SetPlayhead', "
            f"{{ sequence_id='{seq_id}', playhead_position={start} }})")
        seeded = self.eval_int(
            "return require('core.playback.transport')"
            ".engine_for_target():get_position()")
        self.assertEqual(start, seeded,
            f"seed precondition: SetPlayhead({start}) left engine at {seeded}")

        # Step by DELTA_FRAMES via MovePlayhead's positional delta literal.
        self.eval(
            "require('core.command_manager').execute('MovePlayhead', "
            f"{{ _positional = {{ '{DELTA_FRAMES}f' }} }})")

        # Engine MUST be at start + delta. If the explicit
        # transport.seek_target_if_loaded is removed and only the
        # playhead_changed listener path remains, this assertion
        # is what catches a regression that would otherwise leave
        # the engine stale.
        engine_pos = self.eval_int(
            "return require('core.playback.transport')"
            ".engine_for_target():get_position()")
        self.assertEqual(start + DELTA_FRAMES, engine_pos, (
            f"MovePlayhead({DELTA_FRAMES}f) left engine at {engine_pos}; "
            f"expected {start + DELTA_FRAMES}. The engine-sync path "
            f"(playhead_changed → sequence_monitor listener → engine.seek) "
            f"is not reaching the displayed-side engine."))

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
