"""
Phase A Tier 1 — ``I`` key on @timeline scope dispatches to SetMark.

Spec 020 phase1-test-overhaul.md. ``I`` has its own broken-dispatch
history in the source-monitor scope (the 019 live-bound trim wire-up
shipped silently broken; see ``feedback_smoke_tests_real_keypress_only``).
Each Tier 1 binding gets its own per-scope test so a break in one
combo+scope can't hide behind another's coverage.

Domain-level black-box assertion: after a real ``I`` keypress with the
timeline panel focused, the displayed sequence's ``mark_in`` column
equals the playhead at the moment of the press. The "playhead at moment
of press" is the engine's reported position — SetMark's executor
(``set_marks.lua:370-376``) reads ``args.playhead`` which
``command_manager`` auto-injects from
``transport.engine_for_target():get_position()``.

The other ``I`` binding (``@source_monitor`` → SetMarkAndTrimIfClip)
has its own test alongside this one; the two are physically the same
key on disjoint scopes.

Run:
    python3 -m unittest tests.smoke.cases.test_keymap_i_sets_mark_in -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


# Offset from the sequence's start_timecode_frame at which to seed the
# playhead. 100 frames is well past the boundary clamp (mirrors timeline
# viewport_state.set_playhead_position) and well inside any Anamnesis-class
# fixture's content (the fixtures are hours long).
SEED_OFFSET_FROM_START = 100


class TestIKeySetsMarkIn(JVESmokeCase):
    """`I` on @timeline must mutate the displayed sequence's mark_in."""

    def _displayed_sequence_id(self) -> str:
        # The record engine is the authority on "which sequence the
        # I-key would mark" in the @timeline scope: command_manager
        # auto-injects sequence_id for movement-class commands from
        # transport.engine_for_target().loaded_sequence_id
        # (command_manager.lua:1410-1416). timeline_state.active_sequence_id
        # can be nil on cold open even when the engine is bound, so we
        # source from the engine rather than that module.
        return self.eval_str(
            "local sid = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(type(sid) == 'string' and sid ~= '', "
            "       'record engine has no loaded sequence — fixture broken'); "
            "return sid")

    def test_i_keypress_writes_engine_playhead_to_mark_in(self) -> None:
        seq_id = self._displayed_sequence_id()

        # Seed the playhead. start_timecode_frame is the sequence's TC
        # origin (Anamnesis carries a real BWF TC, so start is non-zero);
        # +offset lands deterministically inside content regardless of
        # which fixture or rate the template was built from.
        start = self.eval_int(
            "return require('models.sequence').load('"
            + seq_id + "').start_timecode_frame")
        target = start + SEED_OFFSET_FROM_START

        # SetPlayhead writes the model + emits playhead_changed; the
        # listener in sequence_monitor (sequence_monitor.lua:188-193)
        # seeks the engine for matching sequences. After this returns,
        # the engine MUST report the seeded frame.
        self.eval(
            "require('core.command_manager').execute('SetPlayhead', "
            f"{{ sequence_id='{seq_id}', playhead_position={target} }})")

        engine_pos = self.eval_int(
            "return require('core.playback.transport')"
            ".engine_for_target():get_position()")
        self.assertEqual(target, engine_pos, (
            f"seed precondition failed: SetPlayhead(playhead_position={target}) "
            f"left engine at {engine_pos}. The playhead_changed listener "
            f"in sequence_monitor is not reaching the displayed-side engine, "
            f"so the rest of this test would assert against an unseeded state. "
            f"Fix that regression first, then re-run."))

        # @timeline scope is one of the two I-key bindings (the other
        # is @source_monitor → SetMarkAndTrimIfClip). Test pins this
        # scope specifically.
        self.focus_panel("timeline")
        self.assertEvalEqual("timeline",
            'return require("ui.focus_manager").get_focused_panel()',
            msg="setUp: focus did not anchor on timeline")

        # Real OS keypress.
        self.key("I")

        # Domain assertion. -1 sentinel surfaces the no-op case (mark_in
        # still nil) without raising at int() parse time, so the failure
        # message can name the dispatch chain instead of failing with a
        # ValueError.
        mark_in = self.eval_int(
            "return (require('models.sequence').load('"
            + seq_id + "').mark_in) or -1")
        self.assertEqual(target, mark_in, (
            f"after I keypress on @timeline, sequence {seq_id} mark_in "
            f"expected {target} (the engine's reported playhead at press time), "
            f"got {mark_in}. -1 means the mark was never set (no-op press); "
            f"any other value means SetMark fired against a different sequence "
            f"or read a different playhead source. Dispatch chain (keymap → "
            f"QShortcut → @timeline scope cascade → command_manager auto-inject "
            f"→ SetMark executor) is broken upstream of the executor."))


if __name__ == "__main__":
    unittest.main()
