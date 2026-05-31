"""
``D`` on @timeline (ToggleClipEnabled) — pressing D with one or more
clips selected flips the ``enabled`` flag on every selected clip:
an enabled clip becomes disabled, a disabled clip becomes enabled.

User-visible effect: a disabled clip still occupies its timeline
range (it isn't deleted; downstream isn't rippled) but stops
contributing audio/video to the mix at playback. Pressing D again
re-enables.

Domain-level assertion: after a D keypress on a selected clip that
was enabled, ``clip.enabled`` is false in the model. Press D again,
it's true.

Run:
    python3 -m unittest tests.smoke.cases.test_keymap_d_toggles_clip_enabled -v
"""

import unittest

from tests.smoke.runner.case import JVESmokeCase

class TestDTogglesClipEnabled(JVESmokeCase):
    """D on @timeline flips the selected clip's enabled flag."""

    def _pick_clip(self) -> tuple[str, str]:
        """Return ``(clip_id, rec_seq_id)`` for the first non-gap clip
        in the displayed record sequence."""
        info = self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            "local rec_seq = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(rec_seq, 'record engine has no loaded sequence'); "
            "local picked; "
            "for _, c in ipairs(ts.get_tab_strip():displayed_clips()) do "
            "  if not c.is_gap then picked = c; break end "
            "end; "
            "assert(picked, 'fixture has no clip'); "
            "return string.format('%s|%s', picked.id, rec_seq)")
        parts = info.strip('"').split("|", 1)
        return parts[0], parts[1]

    def _clip_enabled(self, clip_id: str) -> bool:
        return self.eval_bool(
            f"return require('models.clip').load('{clip_id}').enabled")

    def test_d_toggles_selected_clip_enabled_flag(self) -> None:
        clip_id, _rec_seq = self._pick_clip()

        # Replace selection with just this clip via real click.
        self.click_clip(clip_id)

        # Anamnesis clips start enabled. Pin the precondition.
        before = self._clip_enabled(clip_id)
        self.assertTrue(before,
            f"fixture precondition: clip {clip_id} should start enabled. "
            f"If this fails, the fixture or a prior test left this clip "
            f"in an unexpected state — investigate the fixture, not D.")

        self.focus_panel("timeline")
        self.assertEvalEqual("timeline",
            'return require("ui.focus_manager").get_focused_panel()',
            msg="focus did not anchor on timeline before D press")

        self.key("D")
        after_one = self._clip_enabled(clip_id)
        self.assertFalse(after_one, (
            f"after D press on enabled clip {clip_id}, enabled should be "
            f"false. Still true means the keypress didn't reach the "
            f"ToggleClipEnabled executor, or the executor failed to "
            f"persist. Check suite.log for LUA CALLBACK ERROR."))

        # Press again — should toggle back.
        self.key("D")
        after_two = self._clip_enabled(clip_id)
        self.assertTrue(after_two, (
            f"after second D press, enabled should be back to true "
            f"(toggle returns to original). Got false. The toggle is "
            f"not symmetric — likely enabled_before isn't being read "
            f"from the current state on each press."))

if __name__ == "__main__":
    unittest.main()
