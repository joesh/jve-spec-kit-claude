"""
``Alt+I`` / ``Alt+O`` / ``Alt+X`` — clear in-mark / out-mark / both.

Per keymap:
    Alt+I = ClearMark in
    Alt+O = ClearMark out
    Alt+X = ClearMarks

Domain-level assertions: with both marks seeded on the displayed
sequence, each Alt-clear clears its target and leaves the other
intact (Alt+I clears in, keeps out; Alt+O clears out, keeps in;
Alt+X clears both).

The 019 FR-016c gate — ClearMark{In,Out,All} are disabled when the
source viewer is live-bound to a clip — is not in play here because
we test the @timeline scope on the record tab (no source-live binding).

Run:
    python3 -m unittest tests.smoke.cases.test_keymap_alt_i_o_x_clear_marks -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


# Two arbitrary in-content frames distinct enough that "in" vs "out"
# can't be confused. Both above Anamnesis start_frame (89750).
MARK_IN_OFFSET = 100
MARK_OUT_OFFSET = 500


class TestAltIOXClearMarks(JVESmokeCase):
    """Alt+I/O/X clear the corresponding mark(s) on the displayed sequence."""

    def setUp(self) -> None:
        super().setUp()
        # Anchor on the record tab so the displayed sequence is the
        # record sequence and the ClearMark dispatch lands there.
        self.ensure_record_tab()
        self._rec_seq = self.eval_str(
            "local sid = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(sid, 'record engine has no loaded sequence'); "
            "return sid")
        self._start = self.eval_int(
            f"return require('models.sequence').load('{self._rec_seq}')"
            ".start_timecode_frame")

    def _seed_both_marks(self) -> tuple[int, int]:
        """Seeds mark_in and mark_out via real I/O keypresses at distinct
        playhead positions. Returns (expected_mark_in_in_db,
        expected_mark_out_in_db). SetMarkOut stores frame+1
        (inclusive→exclusive convention per set_marks.lua header). The
        expected DB values reflect that."""
        in_inclusive = self._start + MARK_IN_OFFSET
        out_inclusive = self._start + MARK_OUT_OFFSET

        # Seed mark_in: position playhead, focus timeline, press I.
        self.move_playhead_to(in_inclusive)
        self.focus_panel("timeline")
        self.key("I")

        # Seed mark_out: position playhead, focus timeline, press O.
        self.move_playhead_to(out_inclusive)
        self.focus_panel("timeline")
        self.key("O")

        return in_inclusive, out_inclusive + 1

    def _marks(self) -> tuple[object, object]:
        # Returns (mark_in, mark_out); each is int or None ("nil" → -1
        # sentinel → mapped to None). Reads display marks via
        # debug_helpers — displayed tab is the record tab (anchored in
        # setUp), so display marks == record sequence marks.
        raw_in = self.eval_int(
            "return (require('core.debug_helpers').mark_in()) or -1")
        raw_out = self.eval_int(
            "return (require('core.debug_helpers').mark_out()) or -1")
        return (None if raw_in == -1 else raw_in,
                None if raw_out == -1 else raw_out)

    def _press(self, combo: str) -> None:
        self.focus_panel("timeline")
        self.assertEvalEqual("timeline",
            'return require("ui.focus_manager").get_focused_panel()',
            msg=f"focus did not anchor on timeline before {combo} press")
        self.key(combo)

    def test_alt_i_clears_mark_in_keeps_mark_out(self) -> None:
        m_in, m_out = self._seed_both_marks()
        self.assertEqual((m_in, m_out), self._marks(),
            "seed: both marks must be set before press")
        self._press("Alt+I")
        self.assertEqual((None, m_out), self._marks(), (
            f"after Alt+I: mark_in should be nil, mark_out should still be "
            f"{m_out}. Got {self._marks()}. Either Alt+I cleared the wrong "
            f"mark, cleared neither, or cleared both."))

    def test_alt_o_clears_mark_out_keeps_mark_in(self) -> None:
        m_in, m_out = self._seed_both_marks()
        self.assertEqual((m_in, m_out), self._marks(),
            "seed: both marks must be set before press")
        self._press("Alt+O")
        self.assertEqual((m_in, None), self._marks(), (
            f"after Alt+O: mark_out should be nil, mark_in should still be "
            f"{m_in}. Got {self._marks()}. Either Alt+O cleared the wrong "
            f"mark, cleared neither, or cleared both."))

    def test_alt_x_clears_both_marks(self) -> None:
        m_in, m_out = self._seed_both_marks()
        self.assertEqual((m_in, m_out), self._marks(),
            "seed: both marks must be set before press")
        self._press("Alt+X")
        self.assertEqual((None, None), self._marks(), (
            f"after Alt+X: both marks should be nil. Got {self._marks()}. "
            f"Alt+X dispatched but didn't clear both marks."))


if __name__ == "__main__":
    unittest.main()
