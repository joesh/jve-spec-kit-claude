"""
Phase A Tier 1 — NudgeSelection key family on @timeline.

Four bindings, one command (NudgeSelection) with different
(direction, magnitude) parameter pairs:

    Comma        direction=-1 magnitude=1
    Period       direction=+1 magnitude=1
    Shift+Comma  direction=-1 magnitude=5
    Shift+Period direction=+1 magnitude=5

All bound to @timeline scope. NudgeSelection routes internally to the
``Nudge`` command when clips are selected (vs. BatchRippleEdit for
edges); this test exercises the clip-nudge path.

Domain assertion: after pressing the key with one interior clip
selected, the clip's ``sequence_start`` changes by ``direction *
magnitude`` frames.

We pick an interior clip (well past the sequence's start_timecode
boundary, with adjacent gap on both sides) so the nudge isn't
clamped or rejected for collision.

Run:
    python3 -m unittest tests.smoke.cases.test_keymap_nudge_selection -v
"""

import unittest

from tests.smoke.runner.case import JVESmokeCase

# Anamnesis fixture has 3000+ clips; the 5th in display order sits well
# inside content (~424 frames past start) with a huge duration, so neither
# direction nudge hits a boundary or a near-collision.
INTERIOR_CLIP_INDEX = 5

class TestNudgeSelectionKeys(JVESmokeCase):
    """Comma / Period / Shift+(Comma|Period) all nudge the selection."""

    def setUp(self) -> None:
        super().setUp()
        seq_id = self.eval_str(
            "local sid = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(type(sid) == 'string' and sid ~= '', "
            "       'record engine has no loaded sequence — fixture broken'); "
            "return sid")
        # Identify the interior clip + capture its starting position.
        # Storing in self for the test methods to compare against.
        self._seq_id = seq_id
        self._clip_id = self.eval_str(
            f"local c = require('ui.timeline.timeline_state').get_tab_strip():displayed_clips()[{INTERIOR_CLIP_INDEX}]; "
            "assert(c, 'fixture has fewer than INTERIOR_CLIP_INDEX clips'); "
            "return c.id")
        self._start_before = self.eval_int(
            f"return require('models.clip').load('{self._clip_id}').sequence_start")

        # Deselect any prior state then select just this clip. Plain click
        # on an already-selected clip in a multi-selection is a no-op
        # (real-NLE behavior, verified vs Resolve 2026-05-30) so we MUST
        # start from an empty selection for the click to produce {clip}.
        self.key("Cmd+Shift+A")
        self.click_clip(self._clip_id)
        selected_count = self.eval_int(
            "return #require('ui.timeline.timeline_state').get_selected_clips()")
        self.assertEqual(1, selected_count,
            "setUp: clicking clip after DeselectAll did not produce a "
            "single-clip selection")

        # @timeline scope is where the nudge keys are bound.
        self.focus_panel("timeline")

    def _assert_nudged_by(self, combo: str, expected_delta: int) -> None:
        self.key(combo)
        start_after = self.eval_int(
            f"return require('models.clip').load('{self._clip_id}').sequence_start")
        self.assertEqual(self._start_before + expected_delta, start_after, (
            f"after {combo} keypress with clip {self._clip_id} selected, "
            f"sequence_start expected {self._start_before + expected_delta} "
            f"(was {self._start_before}, delta {expected_delta:+d}); "
            f"got {start_after}. NudgeSelection dispatch (keymap → "
            f"QShortcut → @timeline → NudgeSelection executor → Nudge) "
            f"is broken upstream of the model write."))

    def test_comma_nudges_one_frame_left(self) -> None:
        self._assert_nudged_by("Comma", -1)

    def test_period_nudges_one_frame_right(self) -> None:
        self._assert_nudged_by("Period", +1)

    def test_shift_comma_nudges_five_frames_left(self) -> None:
        self._assert_nudged_by("Shift+Comma", -5)

    def test_shift_period_nudges_five_frames_right(self) -> None:
        self._assert_nudged_by("Shift+Period", +5)

if __name__ == "__main__":
    unittest.main()
