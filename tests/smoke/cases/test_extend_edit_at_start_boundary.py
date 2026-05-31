"""
Boundary correctness: ExtendEdit (E) extending in-edge toward the playhead
must respect the sequence's lower bound.

After phase 1 (core.playhead.set clamps playhead to start_timecode_frame),
ExtendEdit — whose delta is derived from ``playhead - edge_position`` —
inherits the protection: the worst-case extend-left lands the in-edge AT
start_timecode_frame (no clip below the floor). This test pins that
contract so a future regression to either the playhead primitive OR
ExtendEdit's delta computation would surface immediately.

Setup: select an interior clip's in-edge (clip with sequence_start just
past floor + plenty of source_in headroom so the source isn't the
binding constraint). Park playhead at start_timecode_frame (the floor).
Press E. Assert the clip's sequence_start lands at start_timecode_frame
(not below).

Run:
    python3 -m unittest tests.smoke.cases.test_extend_edit_at_start_boundary -v
"""

import unittest

from tests.smoke.runner.case import JVESmokeCase

class TestExtendEditBoundary(JVESmokeCase):
    """E (ExtendEdit) toward floor must not push the clip's in-edge below."""

    # Skip pending phase 1 (core.playhead.set clamp) AND a separate
    # ExtendEdit no-op investigation that was previously @expectedFailure.
    # The edge-selection blocker is RESOLVED by click_clip_edge (2026-05-30);
    # the body below uses it and is policy-clean, so when phase 1 lands +
    # the ExtendEdit bug is fixed, this is a one-line skip removal.
    @unittest.skip("pending phase 1 playhead clamp + separate ExtendEdit no-op investigation")
    def test_extend_in_edge_to_floor_lands_at_floor(self) -> None:
        seq_id = self.eval_str(
            "local sid = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(type(sid) == 'string' and sid ~= '', "
            "       'record engine has no loaded sequence — fixture broken'); "
            "return sid")
        start_tc = self.eval_int(
            "return require('models.sequence').load('"
            + seq_id + "').start_timecode_frame")

        # Find an interior clip near the start with source_in headroom
        # (so source-floor isn't the binding constraint — we want to
        # verify the SEQUENCE-floor is enforced).
        info = self.eval(
            "local clips = require('ui.timeline.timeline_state').get_tab_strip():displayed_clips(); "
            f"for _, c in ipairs(clips) do "
            f"  if c.sequence_start > {start_tc} "
            f"     and c.sequence_start < {start_tc} + 500 "
            f"     and c.source_in > 1000 then "
            "    return string.format('%s|%d', c.id, c.sequence_start) "
            "  end "
            "end; "
            "error('no candidate clip with source headroom near boundary')")
        clip_id, clip_start_str = info.strip('"').split('|', 1)
        clip_start_before = int(clip_start_str)

        # Select the in-edge for ripple trim via real click on the edge
        # handle (post-asserts the selection landed).
        self.click_clip_edge(clip_id, "in", "ripple")

        # Park playhead at the floor via the timecode-entry UI.
        # After phase 1, this lands at floor exactly (any below-floor
        # request would be clamped — verified by
        # test_playhead_below_start_clamps.py).
        self.move_playhead_to(start_tc)

        self.focus_panel("timeline")
        self.key("E")

        clip_start_after = self.eval_int(
            f"return require('models.clip').load('{clip_id}').sequence_start")
        self.assertEqual(start_tc, clip_start_after, (
            f"ExtendEdit (E) toward playhead={start_tc} on clip "
            f"{clip_id} (was at sequence_start={clip_start_before}) "
            f"expected to land in-edge AT floor ({start_tc}); got "
            f"{clip_start_after}. Below {start_tc} means the boundary "
            f"invariant clip.sequence_start >= sequence.start_timecode_frame "
            f"was violated. Above {start_tc} means the extend didn't "
            f"reach the playhead — separate bug."))

if __name__ == "__main__":
    unittest.main()
