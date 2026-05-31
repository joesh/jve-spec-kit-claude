"""
``X`` on @timeline (MarkClipExtent) — set the in/out marks to span
the clip strictly under the playhead.

User-visible effect: marks snap to clip boundaries — mark_in at the
clip's left edge, mark_out at the clip's right edge — so the next
edit or playback range matches exactly that clip.

Per ``mark_clip_extent.lua``, the marks are set in a single undo
group via SetMarkIn + SetMarkOut. SetMarkOut applies the inclusive→
exclusive +1 storage convention, so the stored mark_out is
``sequence_start + duration`` (i.e., the frame after the last frame
of the clip).

Domain-level assertion: post-X, displayed sequence's mark_in equals
the spanning clip's sequence_start, mark_out equals
sequence_start + duration.

Run:
    python3 -m unittest tests.smoke.cases.test_keymap_x_mark_clip_extent -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


SEED_OFFSET_INTO_CLIP = 24


class TestXMarksClipExtent(JVESmokeCase):

    def setUp(self) -> None:
        super().setUp()
        self.ensure_record_tab()

    def test_x_sets_marks_to_spanning_clip_boundaries(self) -> None:
        info = self.eval(
            "return require('core.debug_helpers').first_armed_video_clip(49)")
        raw = info.strip('"')
        assert raw, "fixture has no armed video clip with body"
        # first_armed_video_clip returns 6 fields: id|track|start|dur|rec_seq|sequence_id.
        # Split with maxsplit=5 (= 6 parts) so rec_seq doesn't absorb sequence_id.
        clip_id, _track_id, seq_start_s, duration_s, rec_seq, _seq_id = raw.split("|", 5)
        seq_start = int(seq_start_s)
        duration = int(duration_s)

        # Park playhead well inside this clip via real ruler click.
        self.move_playhead_to(seq_start + SEED_OFFSET_INTO_CLIP)

        # Clear marks beforehand so the press is observably setting
        # them, not happening to match prior state.
        self.focus_panel("timeline")
        self.key("Alt+X")
        self.assertEqual(-1, self.eval_int(
            f"return (require('models.sequence').load('{rec_seq}').mark_in) or -1"),
            "seed: Alt+X (ClearMarks) must leave mark_in nil")

        self.assertEvalEqual("timeline",
            'return require("ui.focus_manager").get_focused_panel()',
            msg="focus did not anchor on timeline before X press")

        self.key("X")

        mark_in = self.eval_int(
            f"return require('models.sequence').load('{rec_seq}').mark_in")
        mark_out = self.eval_int(
            f"return require('models.sequence').load('{rec_seq}').mark_out")

        self.assertEqual(seq_start, mark_in, (
            f"after X: mark_in should equal clip {clip_id}'s "
            f"sequence_start ({seq_start}). Got {mark_in}."))
        self.assertEqual(seq_start + duration, mark_out, (
            f"after X: mark_out should equal clip's sequence_start+duration "
            f"({seq_start} + {duration} = {seq_start + duration}, the "
            f"frame-after-last-frame per inclusive→exclusive convention). "
            f"Got {mark_out}."))


if __name__ == "__main__":
    unittest.main()
