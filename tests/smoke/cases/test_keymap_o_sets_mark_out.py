"""
Phase A Tier 1 — ``O`` key on @timeline scope dispatches to SetMark.

Sister to test_keymap_i_sets_mark_in.py. ``O`` writes mark_out (with
the industry-standard exclusive-boundary convention: stored value =
inclusive_frame + 1). Same dispatch chain as I; per-scope per-key
coverage keeps a future regression in O from hiding behind I's test.

Domain assertion: after a real ``O`` keypress with the timeline panel
focused, the displayed sequence's mark_out column equals the playhead
at press time + 1 (exclusive convention). Reads only model state.

Run:
    python3 -m unittest tests.smoke.cases.test_keymap_o_sets_mark_out -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


SEED_OFFSET_FROM_START = 100


class TestOKeySetsMarkOut(JVESmokeCase):
    """`O` on @timeline must mutate the displayed sequence's mark_out."""

    def _displayed_sequence_id(self) -> str:
        return self.eval_str(
            "local sid = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(type(sid) == 'string' and sid ~= '', "
            "       'record engine has no loaded sequence — fixture broken'); "
            "return sid")

    def test_o_keypress_writes_playhead_plus_one_to_mark_out(self) -> None:
        seq_id = self._displayed_sequence_id()

        start = self.eval_int(
            "return require('models.sequence').load('"
            + seq_id + "').start_timecode_frame")
        target = start + SEED_OFFSET_FROM_START

        self.move_playhead_to(target)

        engine_pos = self.eval_int(
            "return require('core.playback.transport')"
            ".engine_for_target():get_position()")
        self.assertEqual(target, engine_pos, (
            f"seed precondition failed: SetPlayhead({target}) left engine "
            f"at {engine_pos}. Fix the engine-sync regression before "
            f"blaming this test."))

        self.focus_panel("timeline")
        self.assertEvalEqual("timeline",
            'return require("ui.focus_manager").get_focused_panel()',
            msg="setUp: focus did not anchor on timeline")

        self.key("O")

        # Industry-standard exclusive boundary: SetMarkOut stores
        # frame + 1 so durations compute as (mark_out - mark_in)
        # without an off-by-one. SetMark "out" routes through the
        # same SetMark executor which applies the +1.
        mark_out = self.eval_int(
            "return (require('models.sequence').load('"
            + seq_id + "').mark_out) or -1")
        self.assertEqual(target + 1, mark_out, (
            f"after O keypress on @timeline, sequence {seq_id} mark_out "
            f"expected {target + 1} (playhead + 1, exclusive boundary), "
            f"got {mark_out}. -1 means the mark was never set (no-op "
            f"press); any other value means SetMark fired against a "
            f"different sequence or read a different playhead source. "
            f"Dispatch chain (keymap → QShortcut → @timeline scope → "
            f"command_manager auto-inject → SetMark executor) is broken "
            f"upstream of the executor."))


if __name__ == "__main__":
    unittest.main()
