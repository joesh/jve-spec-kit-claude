"""
Spec 025 FR-002 — timecode-entry key family on @timeline.

Three bindings arm the timeline TC field for typed entry, each with a
different prefix semantics:

    "Plus"   IncrementTimecode  → arms "+"  (signed offset)
    "Minus"  DecrementTimecode  → arms "-"  (signed offset)
    "Equal"  GoToTimecode       → arms "="  (absolute goto)

Pressing the key does NOT move anything on its own — it opens the field
in entry mode (red border, focused, prefix prefilled). The user then
types a value and commits with Return; the commit routes through
apply_timecode_entry_text → compute_action → SetPlayhead (no selection)
or NudgeSelection (with a selection). This test exercises the
no-selection playhead path: arm, type, commit, assert the playhead.

Physical keystrokes: "Plus" is the main-keyboard + key, which the
canonical key model represents as Shift+Equal (Qt demotes shifted
Plus → Equal+Shift at parse AND runtime), so the runner sends
Shift+Equal to fire the "Plus" binding. "Minus"/"Equal" map 1:1.

Run:
    python3 -m unittest tests.live.cases.test_keymap_timecode_entry -v
"""

import unittest

from tests.live.runner.case import JVESmokeCase

# Keymap binding combo (as spelled in keymaps/default.jvekeys) → the
# physical keystroke the runner must deliver to fire it. The keys of
# this dict are the literal combo strings the coverage audit greps for.
ARM_KEYS = {
    "Plus":  "Shift+Equal",   # IncrementTimecode — shifted Equal == main-kbd +
    "Minus": "Minus",         # DecrementTimecode
    "Equal": "Equal",         # GoToTimecode
}

# Two interior frames well past start_timecode so neither an absolute
# goto nor a ±10f offset clamps at the sequence's lower bound.
BASE_FRAME = 100


class TestTimecodeEntryKeys(JVESmokeCase):
    """+/-/= arm the TC field; typed value commits to the playhead."""

    def setUp(self) -> None:
        super().setUp()
        self.ensure_record_tab()
        # No selection → an offset entry moves the playhead (vs nudging a
        # selection). Clear any prior selection from the template state.
        self.key("Cmd+Shift+A")
        selected = self.eval_int(
            "return #require('ui.timeline.timeline_state').get_selected_clips()")
        self.assertEqual(0, selected,
            "setUp: DeselectAll left a non-empty selection — offset entry "
            "would nudge clips instead of moving the playhead")

    def _read_playhead(self) -> int:
        return self.eval_int("return require('core.debug_helpers').playhead()")

    def _arm_type_commit(self, combo: str, typed: str) -> int:
        """Focus the timeline, press the arm key for ``combo``, type
        ``typed`` into the now-armed field, commit with Return, and
        return the resulting playhead frame."""
        self.key("Cmd+3")  # ensure @timeline scope owns the next keypress
        self.key(ARM_KEYS[combo])
        armed = self.eval_bool(
            "return require('ui.timeline.timeline_panel').is_timecode_entry_active()")
        self.assertTrue(armed, (
            f"{combo} ({ARM_KEYS[combo]}) did not arm the TC field — the "
            f"keymap→QShortcut→@timeline→tc_entry_activate path is broken "
            f"upstream of enter_timecode_entry_mode"))
        self.runner.type_text(typed)
        self.key("Return")
        return self._read_playhead()

    def test_equal_absolute_goto(self) -> None:
        # "=" arms absolute goto; "200f" lands the playhead at frame 200
        # regardless of where it started.
        self.move_playhead_to(BASE_FRAME)
        landed = self._arm_type_commit("Equal", "200f")
        self.assertEqual(200, landed, (
            "Equal-armed absolute goto '=200f' should seek the playhead to "
            f"frame 200; got {landed}"))

    def test_plus_offset_no_selection(self) -> None:
        self.move_playhead_to(BASE_FRAME)
        landed = self._arm_type_commit("Plus", "10f")
        self.assertEqual(BASE_FRAME + 10, landed, (
            f"Plus-armed offset '+10f' from frame {BASE_FRAME} should move "
            f"the playhead to {BASE_FRAME + 10}; got {landed}"))

    def test_minus_offset_no_selection(self) -> None:
        self.move_playhead_to(BASE_FRAME)
        landed = self._arm_type_commit("Minus", "10f")
        self.assertEqual(BASE_FRAME - 10, landed, (
            f"Minus-armed offset '-10f' from frame {BASE_FRAME} should move "
            f"the playhead to {BASE_FRAME - 10}; got {landed}"))


if __name__ == "__main__":
    unittest.main()
