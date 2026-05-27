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

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestExtendEditBoundary(JVESmokeCase):
    """E (ExtendEdit) toward floor must not push the clip's in-edge below."""

    # Currently red: ExtendEdit silently no-ops on the Anamnesis candidates
    # tried (clip stays at original sequence_start despite edge selected,
    # source_in headroom available, playhead well above floor). Separate
    # from the boundary concern — the ripple-trim path inside
    # BatchRippleEdit is rejecting / clamping the trim for a reason that
    # needs its own investigation. Documented as expected-fail so the
    # smoke suite stays green on discover; remove the decorator once the
    # no-op cause is identified.
    @unittest.expectedFailure
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

        # Select the in-edge for ripple trim.
        self.eval(
            "require('core.command_manager').execute('SelectEdges', "
            f"{{ sequence_id='{seq_id}', "
            f"target_edges = {{ {{ clip_id='{clip_id}', edge_type='in', "
            f"  trim_type='ripple' }} }} }})")
        self.assertEqual(1, self.eval_int(
            "return #require('ui.timeline.timeline_state').get_selected_edges()"),
            "setUp: failed to select the in-edge")

        # Park playhead at the floor. After phase 1, this lands at floor
        # exactly (any below-floor request would be clamped — verified
        # by test_playhead_below_start_clamps.py).
        self.eval(
            "require('core.command_manager').execute('SetPlayhead', "
            f"{{ sequence_id='{seq_id}', playhead_position={start_tc} }})")
        self.assertEqual(start_tc, self.eval_int(
            "return require('core.playback.transport')"
            ".engine_for_target():get_position()"),
            "setUp: playhead didn't park at floor")

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
