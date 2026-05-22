"""
Phase A Tier 1 — ``Shift+O`` dispatches to GoToMark out.

Sister to Shift+I. GoToMark "out" parks the playhead at ``mark_out - 1``
(canonical NLE convention: mark_out is stored as the first EXCLUDED frame,
so the "last included frame" — what the user sees as the out point —
is mark_out - 1).

Domain assertion: after pre-staging a known mark_out and pressing
``Shift+O`` with the timeline focused, the engine parks at
``stored_mark_out - 1``.

Run:
    python3 -m unittest tests.smoke.cases.test_keymap_shift_o_goto_mark_out -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


MARK_OUT_INCLUSIVE_OFFSET = 300  # the user-facing out-frame
START_PLAYHEAD_OFFSET = 50       # somewhere ELSE


class TestShiftOGoesToMarkOut(JVESmokeCase):
    """`Shift+O` on @timeline must park the playhead at mark_out - 1."""

    def _displayed_sequence_id(self) -> str:
        return self.eval_str(
            "local sid = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(type(sid) == 'string' and sid ~= '', "
            "       'record engine has no loaded sequence — fixture broken'); "
            "return sid")

    def test_shift_o_keypress_seeks_to_mark_out_minus_one(self) -> None:
        seq_id = self._displayed_sequence_id()
        start = self.eval_int(
            "return require('models.sequence').load('"
            + seq_id + "').start_timecode_frame")
        # SetMarkOut takes the inclusive frame; stores frame + 1 (exclusive)
        mark_out_inclusive = start + MARK_OUT_INCLUSIVE_OFFSET
        expected_seek_target = mark_out_inclusive  # GoToMark out lands here
        playhead_before = start + START_PLAYHEAD_OFFSET

        self.eval(
            "require('core.command_manager').execute('SetMarkOut', "
            f"{{ sequence_id='{seq_id}', frame={mark_out_inclusive} }})")
        self.eval(
            "require('core.command_manager').execute('SetPlayhead', "
            f"{{ sequence_id='{seq_id}', playhead_position={playhead_before} }})")

        # Sanity stage.
        stored_mark_out = self.eval_int(
            "return require('models.sequence').load('" + seq_id + "').mark_out")
        self.assertEqual(mark_out_inclusive + 1, stored_mark_out,
            "stage: SetMarkOut should store inclusive + 1 (exclusive boundary)")
        self.assertEqual(playhead_before, self.eval_int(
            "return require('core.playback.transport')"
            ".engine_for_target():get_position()"),
            "stage: SetPlayhead didn't reach engine")

        self.focus_panel("timeline")

        self.key("Shift+O")

        # Engine parks at the inclusive out-frame (mark_out_inclusive,
        # not mark_out_stored which is one past).
        self.assertEqual(expected_seek_target, self.eval_int(
            "return require('core.playback.transport')"
            ".engine_for_target():get_position()"), (
            f"after Shift+O, engine expected to park at "
            f"{expected_seek_target} (mark_out_stored - 1 = the last "
            f"included frame); was at {playhead_before} before press. "
            f"Dispatch chain (keymap → QShortcut → @timeline → "
            f"GoToMark out executor → park_at → transport listener) is "
            f"broken upstream."))


if __name__ == "__main__":
    unittest.main()
