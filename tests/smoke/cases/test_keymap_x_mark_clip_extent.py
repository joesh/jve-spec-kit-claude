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
        self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            "if ts.get_displayed_tab_kind() ~= 'record' then "
            "  local active = ts.get_active_sequence_id(); "
            "  if active then ts.switch_to_record_tab(active) end "
            "end")

    def test_x_sets_marks_to_spanning_clip_boundaries(self) -> None:
        info = self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            "local Track = require('models.track'); "
            "local rec_seq = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(rec_seq, 'record engine has no loaded sequence'); "
            "local armed = {}; "
            "for _, t in ipairs(Track.find_by_sequence(rec_seq)) do "
            "  if t.track_type == 'VIDEO' and t.autoselect and not t.locked then "
            "    armed[t.id] = true "
            "  end "
            "end; "
            "local picked; "
            "for _, c in ipairs(ts.get_clips()) do "
            "  if armed[c.track_id] and not c.is_gap "
            "     and type(c.duration) == 'number' and c.duration > 48 then "
            "    picked = c; break "
            "  end "
            "end; "
            "assert(picked, 'fixture has no armed video clip with body'); "
            "return string.format('%s|%d|%d|%s', "
            "  picked.id, picked.sequence_start, picked.duration, rec_seq)")
        clip_id, seq_start_s, duration_s, rec_seq = info.strip('"').split("|", 3)
        seq_start = int(seq_start_s)
        duration = int(duration_s)

        # Park playhead well inside this clip.
        self.eval(
            "require('core.command_manager').execute('SetPlayhead', "
            f"{{ sequence_id='{rec_seq}', "
            f"playhead_position={seq_start + SEED_OFFSET_INTO_CLIP} }})")

        # Clear marks beforehand so the press is observably setting
        # them, not happening to match prior state.
        self.eval(
            "require('core.command_manager').execute('ClearMarks', "
            f"{{ sequence_id='{rec_seq}' }})")
        self.assertEqual(-1, self.eval_int(
            f"return (require('models.sequence').load('{rec_seq}').mark_in) or -1"),
            "seed: ClearMarks must leave mark_in nil")

        self.focus_panel("timeline")
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
