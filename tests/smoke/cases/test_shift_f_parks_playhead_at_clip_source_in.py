"""
019 FR-024 v2 (2026-05-22): Shift+F (OpenClipInSourceMonitor) must
match-frame map the record-tab playhead into the loaded clip's source
frame space, then park the source tab + source viewer there.

Joe's spec call: "since Shift+F, like F, loads src tab and viewer with
the clip under the playhead, there is no 'if the playhead is over the
clip.' so yes, every time Shift+F executes, the src tab and viewer's
playhead should sync to the rec tab's playhead."

The naive interpretation ("copy the rec playhead value verbatim") is
wrong because rec and source sequences don't share a frame space.
The correct mapping is the same one MatchFrame uses
(match_frame.lua:102):

    source_frame = clip.source_in + (rec_playhead - clip.sequence_start)

This puts the src viewer on the same source frame that's currently
showing at the rec playhead — which is what "show me the frame I'm
on" actually means.

Also pinned: Shift+F passes skip_focus=true so focus stays on the
Timeline (the src tab on the timeline panel is the read-out for the
viewer; the user keeps typing in Timeline).

Run:
    python3 -m unittest tests.smoke.cases.test_shift_f_parks_playhead_at_clip_source_in -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestShiftFMatchFrameMapsRecPlayheadToSource(JVESmokeCase):
    """OpenClipInSourceMonitor must MAP rec playhead through the clip."""

    def _find_media_clip(self) -> tuple[str, int, int, str, str]:
        """Return (clip_id, source_in, sequence_start, src_seq_id, rec_seq_id)."""
        info = self.eval(
            "local clips = require('ui.timeline.timeline_state').get_clips(); "
            "local picked "
            "for _, c in ipairs(clips) do "
            "  if not c.is_gap "
            "     and type(c.source_in) == 'number' "
            "     and type(c.source_out) == 'number' "
            "     and type(c.sequence_start) == 'number' "
            "     and c.source_out > c.source_in + 1 then "
            "    picked = c "
            "    break "
            "  end "
            "end; "
            "assert(picked, 'no media clip in fixture'); "
            "local rec_seq = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(rec_seq, 'record engine has no loaded sequence'); "
            "return string.format('%s|%d|%d|%s|%s', "
            "  picked.id, picked.source_in, picked.sequence_start, "
            "  picked.sequence_id, rec_seq)")
        parts = info.strip('"').split('|', 4)
        return parts[0], int(parts[1]), int(parts[2]), parts[3], parts[4]

    def _set_record_playhead(self, rec_seq_id: str, frame: int) -> None:
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
        return self.eval_int(
            f"return require('models.sequence').load('{src_seq_id}').playhead_position")

    def _focused_panel(self) -> str:
        return self.eval_str(
            "return require('ui.focus_manager').get_focused_panel() or 'nil'")

    def _shift_f(self, clip_id: str) -> None:
        self.eval(
            "require('core.command_manager').execute('OpenClipInSourceMonitor', "
            f"{{ clip_id='{clip_id}', "
            "project_id=require('core.command_manager').get_active_project_id() })")

    # ── Scenario 1: src playhead = source_in + (rec_playhead - sequence_start)
    def test_shift_f_match_frame_maps_rec_playhead(self) -> None:
        clip_id, source_in, seq_start, src_seq, rec_seq = self._find_media_clip()

        # Park rec playhead at clip.sequence_start + 47 — 47 frames into
        # the clip. Match-frame map → source_in + 47.
        offset = 47
        rec_target = seq_start + offset
        self._set_record_playhead(rec_seq, rec_target)

        # Focus the timeline first so we can verify focus DOESN'T move
        # to source_monitor on Shift+F.
        self.eval("require('ui.focus_manager').focus_panel('timeline')")

        self._shift_f(clip_id)

        self.assertEqual("live_bound_clip", self.eval_str(
            "return tostring(require('ui.source_viewer').get_mode())"),
            "Shift+F didn't enter live_bound_clip mode")

        expected_src = source_in + offset
        self.assertEqual(expected_src, self._src_engine_position(), (
            f"Shift+F must match-frame map rec_playhead → source: "
            f"source_in({source_in}) + (rec_playhead({rec_target}) - "
            f"sequence_start({seq_start})) = {expected_src}; "
            f"got src engine at {self._src_engine_position()}. If src "
            f"engine sits at {rec_target}, the executor is copying "
            f"verbatim instead of mapping through the clip."))
        self.assertEqual(expected_src, self._src_tab_playhead(src_seq), (
            f"src tab (master.playhead_position) expected {expected_src}; "
            f"got {self._src_tab_playhead(src_seq)}"))

        self.assertEqual("timeline", self._focused_panel(), (
            "Shift+F must keep focus on the Timeline (the src tab on "
            "the timeline is the user-facing readout for the viewer); "
            f"focused panel is {self._focused_panel()!r}"))

    # ── Scenario 2: Joe's repro — Shift+F, `, move rec, Shift+F ───────────
    def test_joe_repro_second_shift_f_uses_moved_rec_playhead(self) -> None:
        clip_id, source_in, seq_start, _src_seq, rec_seq = self._find_media_clip()

        # Step a: park rec at clip_start+10, Shift+F.
        self._set_record_playhead(rec_seq, seq_start + 10)
        self._shift_f(clip_id)
        self.assertEqual(source_in + 10, self._src_engine_position(),
            "first Shift+F mapping wrong")

        # Step b: toggle tabs.
        self.eval(
            "require('core.command_manager').execute('ToggleSourceRecordTab', "
            "{ project_id=require('core.command_manager').get_active_project_id() })")

        # Step c: move rec to clip_start+60.
        self._set_record_playhead(rec_seq, seq_start + 60)

        # Step d: Shift+F same clip again — src must now reflect new rec.
        self._shift_f(clip_id)
        self.assertEqual(source_in + 60, self._src_engine_position(), (
            f"Joe's repro: after moving rec playhead by +60 frames and "
            f"re-Shift+F'ing the same clip, src engine expected at "
            f"{source_in + 60} (source_in + new offset); got "
            f"{self._src_engine_position()}. If it sits at {source_in + 10}, "
            f"the second Shift+F is using the stale rec-playhead value."))


if __name__ == "__main__":
    unittest.main()
