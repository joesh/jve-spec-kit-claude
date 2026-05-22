"""
Boundary correctness: a ROLL edit point at the sequence floor must not
drive the dragged clip's sequence_start below
sequence.start_timecode_frame.

When the first media clip on a track has a leading gap, roll-selecting
the in-edge of that clip auto-pairs with the gap's out-edge (the always-
present neighbor edge — even at 0-length). That forms a "roll edit
point": two roll edges on the same track at the same position.

Inside BatchRippleEdit, ``compute_roll_constraint`` SKIPS the
``prev_end_frames`` clamp when the previous neighbor is itself in the
edit selection (``edited_lookup[neighbors.prev_id]``) — the assumption
being that the edit point owns its own boundary. That hand-off is what
exposes the floor: nothing else in the constraint engine knew about
``sequence.start_timecode_frame``, so a leftward roll on a clip already
at the floor would happily push it below.

This test exercises that case directly (invokes BatchRippleEdit with
both edges of the edit point selected, delta_frames negative). It pins
the contract that ``clip.sequence_start >= sequence.start_timecode_frame``
holds across a roll-edit-point trim, regardless of which constraint
inside BRE catches it.

Run:
    python3 -m unittest tests.smoke.cases.test_roll_in_edge_at_start_boundary_clamps -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestRollInEdgeBoundaryClamp(JVESmokeCase):
    """Roll edit point at floor must not drive sequence_start below it."""

    def test_roll_edit_point_at_floor_does_not_violate_lower_bound(self) -> None:
        seq_id = self.eval_str(
            "local sid = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(type(sid) == 'string' and sid ~= '', "
            "       'record engine has no loaded sequence — fixture broken'); "
            "return sid")
        start_tc = self.eval_int(
            "return require('models.sequence').load('"
            + seq_id + "').start_timecode_frame")

        # Find a leftmost media clip at the floor and its leading gap on
        # the same track. The roll edit point sits at the gap's OUT and
        # the clip's IN — same frame.
        info = self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            f"local boundary = {start_tc}; "
            "local target = nil; "
            "for _, c in ipairs(ts.get_clips()) do "
            "  if c.sequence_start == boundary and not c.is_gap "
            "     and (c.duration or 0) > 1 then "
            "    target = c; break "
            "  end "
            "end; "
            "if not target then error('no boundary-aligned media clip in fixture') end; "
            "local gap = nil; "
            "for _, c in ipairs(ts.get_clips()) do "
            "  if c.track_id == target.track_id and c.is_gap "
            "     and c.sequence_start + (c.duration or 0) == target.sequence_start then "
            "    gap = c; break "
            "  end "
            "end; "
            "if not gap then error('no leading gap adjacent to boundary clip') end; "
            "return string.format('%s|%s|%d', target.id, gap.id, target.sequence_start)")
        target_id, gap_id, before_start_str = info.strip('"').split('|', 2)
        before_sequence_start = int(before_start_str)

        # Invoke BatchRippleEdit with both edges of the roll edit point.
        # UI roll-select auto-pairs these; this is the same shape the
        # nudge keys produce after edge_decoration.decorate runs.
        result_summary = self.eval_str(
            "local cm = require('core.command_manager'); "
            f"local r = cm.execute('BatchRippleEdit', {{ "
            f"sequence_id='{seq_id}', "
            "edge_infos = { "
            f"  {{ clip_id='{gap_id}', edge_type='out', trim_type='roll' }}, "
            f"  {{ clip_id='{target_id}', edge_type='in', trim_type='roll' }} "
            "}, delta_frames = -5 }); "
            "return tostring(r.success) .. ':' .. tostring(r.error_message or 'ok')")
        self.assertTrue(result_summary.startswith('true:'),
            f"BatchRippleEdit failed unexpectedly: {result_summary}")

        after_sequence_start = self.eval_int(
            f"return require('models.clip').load('{target_id}').sequence_start")
        self.assertEqual(before_sequence_start, after_sequence_start, (
            f"Roll edit point at floor ({start_tc}) with delta_frames=-5 "
            f"on clip {target_id} (was at sequence_start={before_sequence_start}) "
            f"expected to leave sequence_start unchanged; got "
            f"{after_sequence_start}. Below {start_tc} violates "
            f"clip.sequence_start >= sequence.start_timecode_frame. The "
            f"BRE roll-constraint path skips its own prev_end_frames check "
            f"when the prev edge is in the edit selection — "
            f"apply_sequence_floor_limits must cover this case."))


if __name__ == "__main__":
    unittest.main()
