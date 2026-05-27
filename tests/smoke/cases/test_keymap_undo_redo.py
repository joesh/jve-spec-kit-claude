"""
``Cmd+Z`` (Undo) and ``Cmd+Shift+Z`` (Redo).

User-visible effect: Cmd+Z reverts the last user action; Cmd+Shift+Z
re-applies what was just undone. The pair forms a deterministic
A→B→A→B navigation on the action history.

Test strategy: perform a small, observable, undoable edit via a real
keypress (``D``, ToggleClipEnabled, which we already have an L3 for)
so the undo/redo machinery has a known entry on the stack. Then
press Cmd+Z, assert reverted; Cmd+Shift+Z, assert reapplied.

Domain-level assertion: the clip's ``enabled`` field traces
true → false (after D) → true (after Cmd+Z) → false (after Cmd+Shift+Z).

Run:
    python3 -m unittest tests.smoke.cases.test_keymap_undo_redo -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestUndoRedo(JVESmokeCase):
    """Cmd+Z reverts, Cmd+Shift+Z reapplies the last action."""

    def setUp(self) -> None:
        super().setUp()
        self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            "if ts.get_displayed_tab_kind() ~= 'record' then "
            "  local active = ts.get_active_sequence_id(); "
            "  if active then ts.switch_to_record_tab(active) end "
            "end")

    def _pick_clip(self) -> tuple[str, str]:
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

    def _enabled(self, clip_id: str) -> bool:
        return self.eval_bool(
            f"return require('models.clip').load('{clip_id}').enabled")

    def test_cmd_z_reverts_and_cmd_shift_z_reapplies_an_edit(self) -> None:
        clip_id, rec_seq = self._pick_clip()
        proj = self.eval_str(
            "return require('core.command_manager').get_active_project_id()")
        self.eval(
            "require('core.command_manager').execute('SelectClips', "
            f"{{ project_id='{proj}', sequence_id='{rec_seq}', "
            f"target_clip_ids={{'{clip_id}'}} }})")

        self.assertTrue(self._enabled(clip_id),
            "fixture precondition: clip starts enabled")

        self.focus_panel("timeline")
        self.assertEvalEqual("timeline",
            'return require("ui.focus_manager").get_focused_panel()',
            msg="focus did not anchor on timeline before D press")

        # Apply: D → enabled=false
        self.key("D")
        self.assertFalse(self._enabled(clip_id),
            "D press did not flip enabled — undo/redo coverage depends "
            "on the D path; fix D first")

        # Undo: Cmd+Z → enabled=true (back to original)
        self.key("Cmd+Z")
        self.assertTrue(self._enabled(clip_id), (
            f"after Cmd+Z, clip {clip_id} should be back to enabled=true. "
            f"Still false means Undo dispatched but didn't run the "
            f"ToggleClipEnabled undoer, or the undoer didn't restore "
            f"enabled_before."))

        # Redo: Cmd+Shift+Z → enabled=false (re-applied)
        self.key("Cmd+Shift+Z")
        self.assertFalse(self._enabled(clip_id), (
            f"after Cmd+Shift+Z, clip {clip_id} should be back to "
            f"enabled=false (re-applied). Still true means Redo "
            f"dispatched but didn't re-run the executor."))


if __name__ == "__main__":
    unittest.main()
