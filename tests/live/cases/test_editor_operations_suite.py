"""
Editor operations suite — pins the roll vs. ripple downstream-shift
discriminator on the anamnesis gold timeline. Origin: the lua
integration test at ``tests/integration/test_editor_operations.lua``
(see ``tests/live/MIGRATION_ANALYSIS.md`` entry for that file).

The source lua suite covered nine things:

    roll on V1, roll on A3, ripple on V1, roll-vs-ripple comparison,
    roll at gap boundary, undo/redo cycle, split clip, toggle enabled,
    nudge clip, large-audio roll

Six of those are already pinned elsewhere in the smoke suite (no need
to re-pin from this origin):

    split    → tests/live/cases/test_keymap_cmd_b_blades_at_playhead.py
    enabled  → tests/live/cases/test_keymap_d_toggles_clip_enabled.py
    nudge    → tests/live/cases/test_keymap_nudge_selection.py
    undo/redo→ tests/live/cases/test_keymap_undo_redo.py
    trim     → tests/live/cases/test_keymap_cmd_shift_bracket_trim_head_tail.py
    boundary → tests/live/cases/test_*_clamps.py

What's left, and the highest-value unique behavior in the origin file,
is the roll-vs-ripple downstream discriminator: with the same edge
extended by the same delta, a ROLL must leave downstream clips at
their original sequence_start while a RIPPLE must shift downstream by
exactly delta. The two scenarios sharing one fixture is what catches
the "one of them silently behaves like the other" bug class.

This requires driving an edge trim by an exact frame delta. The
keymap has no key binding for that today — RollTool (T) / RippleTool
(R) only change the active edit mode; the actual edge-drag happens
via mouse on a clip edge. Smokes need a ``click_edge(clip_id, side)``
+ ``drag_horizontal(frames)`` primitive that does not yet exist.

When that primitive lands, remove the ``@unittest.skip`` decorators
below and the test will fan out into two methods sharing the same
adjacent-pair selection on V1 of the anamnesis timeline.

# TODO: needs click_edge + drag_horizontal primitives — see
#       MIGRATION_ANALYSIS.md (test_editor_operations.lua entry,
#       "click_edge, bracket trim keys" in UI primitives column).

Run:
    python3 -m unittest tests.live.cases.test_editor_operations_suite -v
"""

import unittest

from tests.live.runner.case import JVESmokeCase

class TestRollVsRippleDownstreamDiscriminator(JVESmokeCase):
    """Same edge, same delta — roll holds downstream still, ripple
    shifts it by delta. Asserted on V1 of the anamnesis gold timeline
    (rich enough to always have an adjacent pair plus a downstream
    clip on the same track)."""

    @unittest.skip("needs click_edge + drag_horizontal primitives")
    def test_01_roll_v1_leaves_downstream_clip_unchanged(self) -> None:
        # When the primitive lands:
        #   1. Find first adjacent pair (a, b) on V1 + a downstream clip d.
        #   2. Capture d.sequence_start.
        #   3. click_edge(a, "out"); drag_horizontal(+5)  # roll mode (T)
        #   4. Assert d.sequence_start unchanged — roll MUST NOT ripple
        #      downstream. If d shifted by +5, roll silently behaved as
        #      a ripple (the bug this test is here to catch).
        raise NotImplementedError("scaffolded — awaiting edge-drag primitive")

    @unittest.skip("needs click_edge + drag_horizontal primitives")
    def test_02_ripple_v1_shifts_downstream_clip_by_delta(self) -> None:
        # Inherits the post-undo state from test_01.
        #   1. Same pair (a, b) on V1 + downstream d.
        #   2. Capture d.sequence_start.
        #   3. click_edge(a, "out"); drag_horizontal(+5)  # ripple mode (R)
        #   4. Assert d.sequence_start == captured + 5 — ripple MUST
        #      shift downstream by exactly the trim delta. If d is
        #      unchanged, ripple silently behaved as a roll.
        raise NotImplementedError("scaffolded — awaiting edge-drag primitive")

if __name__ == "__main__":
    unittest.main()
