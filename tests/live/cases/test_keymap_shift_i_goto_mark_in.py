"""
Phase A Tier 1 — ``Shift+I`` dispatches to GoToMark in.

Sister to the I/O SetMark smoke tests. GoToMark "in" is non-undoable
playback navigation: it parks the playhead at the sequence's stored
mark_in. If mark_in is nil the command is a no-op.

Domain assertion: after pre-staging a known mark_in and pressing
``Shift+I`` with the timeline focused, sequence.playhead_position
equals that mark_in.

Pre-staging uses SetMarkIn directly (NOT via the I keypress) so a
break in the I-key dispatch chain can't mask a break in Shift+I's.

Run:
    python3 -m unittest tests.live.cases.test_keymap_shift_i_goto_mark_in -v
"""

import unittest

from tests.live.runner.case import JVESmokeCase

MARK_IN_OFFSET = 200
START_PLAYHEAD_OFFSET = 50  # somewhere ELSE so the seek is observable

class TestShiftIGoesToMarkIn(JVESmokeCase):
    """`Shift+I` on @timeline must park the playhead at mark_in."""

    def _displayed_sequence_id(self) -> str:
        return self.eval_str(
            "local sid = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(type(sid) == 'string' and sid ~= '', "
            "       'record engine has no loaded sequence — fixture broken'); "
            "return sid")

    def test_shift_i_keypress_seeks_to_mark_in(self) -> None:
        seq_id = self._displayed_sequence_id()
        start = self.eval_int(
            "return require('models.sequence').load('"
            + seq_id + "').start_timecode_frame")
        mark_in_frame = start + MARK_IN_OFFSET
        playhead_before = start + START_PLAYHEAD_OFFSET

        # Stage: mark_in at one frame; playhead parked somewhere else
        # so the post-Shift+I seek is unambiguously the GoToMark, not
        # a no-op coincidence.
        self.focus_panel("timeline")
        self.move_playhead_to(mark_in_frame)
        self.key("I")
        self.move_playhead_to(playhead_before)

        # Sanity: stage landed where expected.
        self.assertEqual(mark_in_frame, self.eval_int(
            "return require('models.sequence').load('" + seq_id + "').mark_in"),
            "stage: SetMarkIn didn't persist")
        self.assertEqual(playhead_before, self.eval_int(
            "return require('core.playback.transport')"
            ".engine_for_target():get_position()"),
            "stage: SetPlayhead didn't reach engine")

        self.focus_panel("timeline")
        self.assertEvalEqual("timeline",
            'return require("ui.focus_manager").get_focused_panel()',
            msg="setUp: focus did not anchor on timeline")

        self.key("Shift+I")

        # Engine seeks to mark_in via GoToMark → park_at → playhead_changed
        # → transport listener.
        engine_after = self.eval_int(
            "return require('core.playback.transport')"
            ".engine_for_target():get_position()")
        self.assertEqual(mark_in_frame, engine_after, (
            f"after Shift+I on @timeline, engine expected to park at "
            f"mark_in={mark_in_frame} (was {playhead_before}); got "
            f"{engine_after}. Dispatch chain (keymap → QShortcut → "
            f"@timeline scope → GoToMark executor → park_at → "
            f"playhead_changed → transport listener) is broken upstream "
            f"of the executor."))

        # Model row also reflects the new playhead (park_at writes it).
        self.assertEqual(mark_in_frame, self.eval_int(
            "return require('models.sequence').load('"
            + seq_id + "').playhead_position"),
            "sequences.playhead_position did not follow the seek")

if __name__ == "__main__":
    unittest.main()
