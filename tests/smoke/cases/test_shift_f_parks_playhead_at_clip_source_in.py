"""
019 FR-024 v2 (2026-05-22): Shift+F (OpenClipInSourceMonitor) must sync
the source-tab AND source-viewer playhead to the *record-tab playhead*.

Joe's spec call: "since Shift+F, like F, loads src tab and viewer with
the clip under the playhead, there is no 'if the playhead is over the
clip.' so yes, every time Shift+F executes, the src tab and viewer's
playhead should sync to the rec tab's playhead."

Concretely, after dispatch:
  * The master sequence's `playhead_position` (the src tab's ruler reads
    this) equals the record sequence's `playhead_position` at the moment
    of dispatch.
  * The source playback engine's `_position` (the src viewer's render
    pulls this) equals the same frame.

This pins behavior across Joe's manual repro:
  Shift+F, ` (toggle to record tab), move playhead, Shift+F again →
  the second Shift+F must move the src playhead to the *new* rec
  playhead position, not leave it stuck at the first Shift+F's value.

Run:
    python3 -m unittest tests.smoke.cases.test_shift_f_parks_playhead_at_clip_source_in -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestShiftFSyncsSrcPlayheadToRecPlayhead(JVESmokeCase):
    """OpenClipInSourceMonitor must copy rec-tab playhead to src tab + viewer."""

    def _find_media_clip(self) -> tuple[str, str, str]:
        """Return (clip_id, source_sequence_id, record_sequence_id).

        clip.sequence_id is the master sequence the clip lives on (what
        the source tab + source engine bind to in live-bound mode).
        The record engine's loaded sequence is the rec-tab sequence.
        """
        info = self.eval(
            "local clips = require('ui.timeline.timeline_state').get_clips(); "
            "local clip_id, src_seq "
            "for _, c in ipairs(clips) do "
            "  if not c.is_gap "
            "     and type(c.source_in) == 'number' "
            "     and type(c.source_out) == 'number' "
            "     and c.source_out > c.source_in + 1 then "
            "    clip_id, src_seq = c.id, c.sequence_id "
            "    break "
            "  end "
            "end; "
            "assert(clip_id, 'no media clip in fixture'); "
            "local rec_seq = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(rec_seq, 'record engine has no loaded sequence'); "
            "return string.format('%s|%s|%s', clip_id, src_seq, rec_seq)")
        return tuple(info.strip('"').split('|', 2))  # type: ignore[return-value]

    def _set_record_playhead(self, rec_seq_id: str, frame: int) -> None:
        """Write the rec-tab playhead via the canonical SetPlayhead command.

        Uses the command surface (not direct model write) so the test
        exercises the same flow a user keystroke would.
        """
        self.eval(
            "require('core.command_manager').execute('SetPlayhead', "
            f"{{ sequence_id='{rec_seq_id}', "
            "project_id=require('core.command_manager').get_active_project_id(), "
            f"playhead_position={frame} }})")

    def _src_engine_position(self) -> int:
        return self.eval_int(
            "local sm = require('ui.panel_manager')"
            ".get_sequence_monitor('source_monitor'); "
            "assert(sm and sm.engine, 'no source monitor engine'); "
            "return sm.engine:get_position()")

    def _src_tab_playhead(self, src_seq_id: str) -> int:
        """The src-tab ruler reads master.playhead_position."""
        return self.eval_int(
            f"return require('models.sequence').load('{src_seq_id}').playhead_position")

    def _shift_f(self, clip_id: str) -> None:
        self.eval(
            "require('core.command_manager').execute('OpenClipInSourceMonitor', "
            f"{{ clip_id='{clip_id}', "
            "project_id=require('core.command_manager').get_active_project_id() })")

    # ── Scenario 1: single Shift+F lands src playhead at rec playhead ─────
    def test_shift_f_copies_rec_playhead_to_src(self) -> None:
        clip_id, src_seq, rec_seq = self._find_media_clip()

        start_tc = self.eval_int(
            f"return require('models.sequence').load('{rec_seq}').start_timecode_frame")
        # Pick a rec playhead well past start_tc so 0 / start_tc accidents
        # don't make the test pass for the wrong reason.
        rec_target = start_tc + 137
        self._set_record_playhead(rec_seq, rec_target)

        self._shift_f(clip_id)

        self.assertEqual("live_bound_clip", self.eval_str(
            "return tostring(require('ui.source_viewer').get_mode())"),
            "setUp: Shift+F didn't enter live_bound_clip mode")

        self.assertEqual(rec_target, self._src_engine_position(), (
            f"Shift+F must seek source engine to rec playhead "
            f"({rec_target}); got {self._src_engine_position()}"))
        self.assertEqual(rec_target, self._src_tab_playhead(src_seq), (
            f"Shift+F must update master.playhead_position (src tab "
            f"ruler) to rec playhead ({rec_target}); got "
            f"{self._src_tab_playhead(src_seq)}"))

    # ── Scenario 2: Joe's exact repro — Shift+F, `, move rec, Shift+F ─────
    def test_joe_repro_second_shift_f_uses_moved_rec_playhead(self) -> None:
        clip_id, src_seq, rec_seq = self._find_media_clip()

        start_tc = self.eval_int(
            f"return require('models.sequence').load('{rec_seq}').start_timecode_frame")

        # Step a: park rec playhead at A, Shift+F.
        rec_a = start_tc + 50
        self._set_record_playhead(rec_seq, rec_a)
        self._shift_f(clip_id)
        self.assertEqual(rec_a, self._src_engine_position(),
            "first Shift+F should land src playhead at rec_a")

        # Step b: toggle to record tab. Focus is now on the timeline /
        # record tab. ToggleSourceRecordTab in this state moves displayed
        # to the record tab.
        self.eval(
            "require('core.command_manager').execute('ToggleSourceRecordTab', "
            "{ project_id=require('core.command_manager').get_active_project_id() })")

        # Step c: move rec playhead to a *new* position B.
        rec_b = start_tc + 410
        self.assertNotEqual(rec_a, rec_b, "test fixture: rec_a == rec_b makes assertion below trivial")
        self._set_record_playhead(rec_seq, rec_b)

        # Step d: Shift+F again on the same clip.
        self._shift_f(clip_id)

        self.assertEqual(rec_b, self._src_engine_position(), (
            f"Joe's repro: after moving rec playhead from {rec_a} to "
            f"{rec_b} and re-Shift+F'ing the same clip, src engine "
            f"expected at {rec_b}; got {self._src_engine_position()}. "
            f"If it sits at {rec_a}, the second Shift+F isn't picking "
            f"up the moved rec playhead — sync regressed."))
        self.assertEqual(rec_b, self._src_tab_playhead(src_seq), (
            f"After Joe's repro, src tab (master.playhead_position) "
            f"expected {rec_b}; got {self._src_tab_playhead(src_seq)}"))


if __name__ == "__main__":
    unittest.main()
