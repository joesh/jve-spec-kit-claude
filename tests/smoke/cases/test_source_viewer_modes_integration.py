"""
019 source-viewer modes end-to-end — pins the full live-bound journey:
neutral → staged_sequence (master loaded) → live_bound_clip (Shift+F on
a timeline clip) → trim-mode toggle (overwrite ↔ ripple) → I-key
SetMarkAndTrimIfClip shrinks the live clip from the head → effective
source override reflects the post-trim range → unload returns to
neutral.

Origin: tests/binding/test_019_source_viewer_integration.lua
(Group B in tests/smoke/MIGRATION_ANALYSIS.md). The Lua original
dispatches via command_manager.execute_interactive; this smoke is the
real-OS-input version called out by the migration plan.

# TODO: needs the following primitives — see MIGRATION_ANALYSIS.md
#   - a keybinding (or menu pick) that invokes
#     `source_viewer.load_master_clip(master_seq_id)` — staged-sequence
#     entry point. No "@source_monitor master-load" key exists in
#     keymaps/default.jvekeys today; the only adjacent binding is
#     Alt+F (FindMasterClipInBrowser).
#   - a keybinding for ToggleTrimMode (flips edit_mode.get_trim_mode()
#     between "overwrite" and "ripple"). Not bound today.
#   - a keybinding (or menu pick) for source_viewer.unload — neutral
#     restore. Not bound today.
#   - debug_helpers.effective_source_in() / effective_source_out() —
#     needed to assert the post-trim override range without reaching
#     into core.effective_source from the test body. Adjacent helpers
#     (source_viewer_mode, source_viewer_clip_id) exist; the trio
#     should be completed alongside this smoke.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestSourceViewerModesIntegration(JVESmokeCase):
    """Full mode-transition journey for the 019 source-viewer feature."""

    @unittest.skip(
        "needs primitives: ToggleTrimMode key, load_master_clip key, "
        "unload key, debug_helpers.effective_source_in/out — see file "
        "docstring + MIGRATION_ANALYSIS.md")
    def test_source_viewer_modes_neutral_staged_live_trim_unload(self) -> None:
        # ---- 1. neutral at boot ----
        self.assertEvalEqual(
            "neutral",
            'return require("core.debug_helpers").source_viewer_mode()',
            msg="source viewer should boot in neutral mode")

        # ---- 2. staged_sequence: load a master into the source tab ----
        # PRIMITIVE MISSING: no keybinding loads a master sequence into
        # source viewer. Real flow would be: click a master clip in the
        # project browser, press <load-master> key.
        master_seq_id = self.eval_str(
            "local Sequence = require('models.sequence'); "
            "for _, s in ipairs(Sequence.list_all() or {}) do "
            "  if s.kind == 'master' then return s.id end "
            "end; error('fixture has no master sequence')")
        # self.<load_master_clip_primitive>(master_seq_id)
        self.assertEvalEqual(
            "staged_sequence",
            'return require("core.debug_helpers").source_viewer_mode()',
            msg="after loading a master, source viewer should be in "
                "staged_sequence mode")
        self.assertEvalEqual(
            master_seq_id,
            'return require("core.debug_helpers").source_viewer_sequence_id()',
            msg="source monitor should be bound to the master sequence")

        # ---- 3. live_bound_clip: Shift+F on a timeline clip ----
        info = self.eval(
            "local clips = require('ui.timeline.timeline_state')"
            ".get_tab_strip():displayed_clips(); "
            "for _, c in ipairs(clips) do "
            "  if not c.is_gap "
            "     and type(c.source_in) == 'number' "
            "     and type(c.source_out) == 'number' "
            "     and c.source_out > c.source_in + 30 then "
            "    return string.format('%s|%d|%d', c.id, "
            "      c.source_in, c.source_out) "
            "  end "
            "end; error('no media clip with usable source range')")
        clip_id, src_in_str, src_out_str = info.strip('"').split('|', 2)
        original_src_in = int(src_in_str)
        original_src_out = int(src_out_str)

        # Select the clip on the timeline first, then move playhead so
        # Shift+F has an unambiguous target.
        self.click_clip(clip_id)
        self.focus_panel("timeline")
        self.key("Shift+F")  # OpenClipInSourceMonitor → live_bound_clip

        self.assertEvalEqual(
            "live_bound_clip",
            'return require("core.debug_helpers").source_viewer_mode()',
            msg="Shift+F on a selected timeline clip should enter "
                "live_bound_clip mode")
        self.assertEvalEqual(
            clip_id,
            'return require("core.debug_helpers").source_viewer_clip_id()',
            msg="source viewer should be live-bound to the clicked clip")

        # effective_source in live-bound mode returns the clip's range.
        # PRIMITIVE MISSING: needs debug_helpers.effective_source_in/out.

        # ---- 4. trim-mode toggle: overwrite → ripple → overwrite ----
        # PRIMITIVE MISSING: no ToggleTrimMode keybinding.
        # Expected: edit_mode.get_trim_mode() flips overwrite ↔ ripple,
        # non-undoable.

        # ---- 5. I-key in @source_monitor — SetMarkAndTrimIfClip ----
        # In live-bound mode with playhead parked +30 frames past the
        # clip's source_in, pressing I shrinks the clip head by 30:
        # source_in advances, source_out unchanged, duration shrinks.
        trim_delta = 30
        park_at = original_src_in + trim_delta
        self.focus_panel("source_monitor")
        # Park the source-monitor playhead at park_at — needs source
        # monitor ruler clicks; today move_playhead_to targets the
        # displayed (record) ruler. For now express the intent:
        self.eval(
            "local pm = require('ui.panel_manager'); "
            f"pm.get_sequence_monitor('source_monitor').engine:seek({park_at})")
        self.key("I")  # SetMarkAndTrimIfClip in @source_monitor

        self.assertEvalEqual(
            park_at,
            f"return require('core.debug_helpers').clip_field('{clip_id}', "
            f"'source_in_frame')",
            msg=f"clip.source_in should advance from {original_src_in} "
                f"to {park_at} (delta=+{trim_delta}) after I-key trim "
                "in live-bound mode")
        self.assertEvalEqual(
            original_src_out,
            f"return require('core.debug_helpers').clip_field('{clip_id}', "
            f"'source_out')",
            msg="clip.source_out should be unchanged by a head trim")
        expected_dur = original_src_out - park_at
        self.assertEvalEqual(
            expected_dur,
            f"return require('core.debug_helpers').clip_field('{clip_id}', "
            f"'duration')",
            msg=f"clip.duration should shrink to {expected_dur} "
                "(source_out - new source_in)")

        # ---- 6. effective_source override reflects post-trim range ----
        # PRIMITIVE MISSING: debug_helpers.effective_source_in/out.

        # ---- 7. unload → neutral ----
        # PRIMITIVE MISSING: no source_viewer.unload keybinding.
        self.assertEvalEqual(
            "neutral",
            'return require("core.debug_helpers").source_viewer_mode()',
            msg="after unload, source viewer should be back in neutral")


if __name__ == "__main__":
    unittest.main()
