"""
``Delete`` / ``Backspace`` (DeleteSelection, lift mode) on @timeline —
remove the selected clip(s) from the timeline without rippling
downstream content. The removed region becomes a gap.

Aliases: Backspace is an alias of Delete (both wired to
``DeleteSelection`` with no ripple flag).

User-visible effect: the selected clip vanishes; its former range on
the timeline is now empty (a gap). Subsequent clips on the same
track stay at their original positions (no ripple).

Domain-level assertion: after the press, the clip with the selected
id no longer loads from the model. (Whether a gap shows up in the
view is a derived state; the model boundary is "the row is gone.")

History note: this binding was L2-exempt until the
`PlaybackEngine:on_model_changed` controller guard landed
2026-05-22; before that, the cascading content_changed → seek error
storm broke L2's press-all loop. L3 here exercises the same path
under L3-friendly seeded state.

Run:
    python3 -m unittest tests.smoke.cases.test_keymap_delete_lift -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


SEED_OFFSET_INTO_CLIP = 24


class TestDeleteLiftsSelectedClip(JVESmokeCase):

    def setUp(self) -> None:
        super().setUp()
        self.ensure_record_tab()

    def _pick_and_select_clip(self) -> str:
        """Pick an armed video clip, select it, seed playhead inside.
        Returns the clip id."""
        info = self.eval_str(
            "return require('core.debug_helpers').first_armed_video_clip(48)")
        assert info, "fixture has no armed video clip with body"
        clip_id, _track_id, seq_start_s, _duration, _rec_seq, _master = (
            info.split("|", 5))
        self.move_playhead_to(int(seq_start_s) + SEED_OFFSET_INTO_CLIP)
        self.click_clip(clip_id)
        return clip_id

    def _clip_exists(self, clip_id: str) -> bool:
        return self.eval_bool(
            f"return require('core.debug_helpers').clip_exists('{clip_id}')")

    def _press(self, combo: str) -> None:
        self.focus_panel("timeline")
        self.assertEvalEqual("timeline",
            'return require("ui.focus_manager").get_focused_panel()',
            msg=f"focus did not anchor on timeline before {combo} press")
        self.key(combo)

    def test_delete_removes_selected_clip_from_model(self) -> None:
        clip_id = self._pick_and_select_clip()
        self.assertTrue(self._clip_exists(clip_id),
            f"seed: clip {clip_id} must exist before Delete press")
        self._press("Delete")
        self.assertFalse(self._clip_exists(clip_id), (
            f"after Delete: clip {clip_id} should be gone from the "
            f"model (lifted to gap). Still present means DeleteSelection "
            f"didn't fire or didn't reach the DB."))

    def test_backspace_is_alias_of_delete(self) -> None:
        clip_id = self._pick_and_select_clip()
        self.assertTrue(self._clip_exists(clip_id),
            f"seed: clip {clip_id} must exist before Backspace press")
        self._press("Backspace")
        self.assertFalse(self._clip_exists(clip_id), (
            f"after Backspace: clip {clip_id} should be gone (Backspace "
            f"is wired identically to Delete in the keymap). Still "
            f"present means the Backspace binding isn't carrying the "
            f"same args, or has drifted from Delete."))


if __name__ == "__main__":
    unittest.main()
