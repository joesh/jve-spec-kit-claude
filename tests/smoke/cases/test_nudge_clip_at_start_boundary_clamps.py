"""
Boundary correctness: nudging the leftmost clip left must clamp silently.

When the leftmost clip on a track sits at ``sequence.start_timecode_frame``
(the timeline's lower bound), pressing Comma (nudge -1 frame) must NOT
push the clip's ``sequence_start`` below that bound. Domain invariant:

    clip.sequence_start >= sequence.start_timecode_frame

Behavior (Joe's call): **silent clamp** — the clip stays at the
boundary, no error surfaced. Matches standard NLE feel (FCP/Premiere):
nudge hits the wall, nothing happens.

Setup: find the boundary clip (sequence_start == start_timecode_frame),
select it, press Comma. Assert sequence_start is unchanged.

Sister tests pin the same family for ExtendEdit and live-bound trim-IN.

Run:
    python3 -m unittest tests.smoke.cases.test_nudge_clip_at_start_boundary_clamps -v
"""

import unittest

from tests.smoke.runner.case import JVESmokeCase

class TestNudgeBoundaryClamp(JVESmokeCase):
    """Comma on a boundary-aligned clip must not corrupt the invariant."""

    def test_comma_on_boundary_clip_does_not_violate_lower_bound(self) -> None:
        seq_id = self.eval_str(
            "local sid = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(type(sid) == 'string' and sid ~= '', "
            "       'record engine has no loaded sequence — fixture broken'); "
            "return sid")
        start_tc = self.eval_int(
            "return require('models.sequence').load('"
            + seq_id + "').start_timecode_frame")

        # Find the leftmost clip — the one whose sequence_start equals
        # the timeline's lower bound. If the Anamnesis fixture has none
        # (unlikely; gold-timeline does), the test is moot — surface that.
        boundary_clip_id = self.eval_str(
            "local clips = require('ui.timeline.timeline_state').get_tab_strip():displayed_clips(); "
            f"local boundary = {start_tc}; "
            "for _, c in ipairs(clips) do "
            "  if c.sequence_start == boundary then return c.id end "
            "end; "
            "error('no clip at sequence.start_timecode_frame — fixture cannot "
            "exercise the boundary case')")

        self.click_clip(boundary_clip_id)

        self.focus_panel("timeline")
        self.key("Comma")

        after = self.eval_int(
            f"return require('models.clip').load('{boundary_clip_id}').sequence_start")
        self.assertEqual(start_tc, after, (
            f"after Comma keypress on boundary clip {boundary_clip_id} "
            f"(sequence_start was {start_tc} == start_timecode_frame), "
            f"sequence_start expected to stay at {start_tc} (silent clamp "
            f"per Joe's call: 'A — clip stops at start_timecode_frame, no "
            f"error'). Got {after}. Below {start_tc} means Nudge wrote a "
            f"value violating the domain invariant "
            f"clip.sequence_start >= sequence.start_timecode_frame."))

if __name__ == "__main__":
    unittest.main()
