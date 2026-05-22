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
The correct mapping lives in `Clip.owner_frame_to_source(clip, frame)`
(shared with MatchFrame):

    source_frame = clip.source_in + (rec_playhead - clip.sequence_start)

This puts the src viewer on the same source frame that's currently
showing at the rec playhead — what "show me the frame I'm on" means.
`source_viewer.load_clip` then clamps to the clip's source range so
a far-off rec playhead doesn't park the viewer outside its mark
window (FR-024 v2 parking-clamp).

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

    # ── Per-scenario setUp: get to a known state + sample a fixture clip ──
    def setUp(self) -> None:
        super().setUp()
        # The smoke runner is a long-lived singleton — prior tests may
        # have left the source tab displayed. `timeline_state.get_clips()`
        # is keyed on the displayed sequence, so we must put the
        # timeline on the record tab before sampling (otherwise we'd
        # pick a master clip whose `source_in == sequence_start` and
        # the mapping equation goes degenerate).
        self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            "if ts.get_displayed_tab_kind() ~= 'record' then "
            "  local active = ts.get_active_sequence_id(); "
            "  assert(active, 'no active sequence to switch back to'); "
            "  ts.switch_to_record_tab(active); "
            "end")
        (
            self.clip_id,
            self.source_in,
            self.seq_start,
            self.src_seq,
            self.rec_seq,
        ) = self._find_media_clip()

    # ── Probe helpers ──────────────────────────────────────────────────
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

    def _set_record_playhead(self, frame: int) -> None:
        self.eval(
            "require('core.command_manager').execute('SetPlayhead', "
            f"{{ sequence_id='{self.rec_seq}', "
            "project_id=require('core.command_manager').get_active_project_id(), "
            f"playhead_position={frame} }})")

    def _src_engine_position(self) -> int:
        return self.eval_int(
            "local sm = require('ui.panel_manager')"
            ".get_sequence_monitor('source_monitor'); "
            "assert(sm and sm.engine, 'no source monitor engine'); "
            "return sm.engine:get_position()")

    def _src_tab_playhead(self) -> int:
        return self.eval_int(
            f"return require('models.sequence').load('{self.src_seq}').playhead_position")

    def _focused_panel(self) -> str:
        return self.eval_str(
            "return require('ui.focus_manager').get_focused_panel() or 'nil'")

    def _shift_f(self) -> None:
        self.eval(
            "require('core.command_manager').execute('OpenClipInSourceMonitor', "
            f"{{ clip_id='{self.clip_id}', "
            "project_id=require('core.command_manager').get_active_project_id() })")

    # ── Scenario 1: src playhead = source_in + (rec_playhead - sequence_start)
    def test_shift_f_match_frame_maps_rec_playhead(self) -> None:
        offset = 47
        rec_target = self.seq_start + offset
        self._set_record_playhead(rec_target)

        # Focus the timeline first so we can verify focus DOESN'T move
        # to source_monitor on Shift+F.
        self.eval("require('ui.focus_manager').focus_panel('timeline')")

        self._shift_f()

        self.assertEqual("live_bound_clip", self.eval_str(
            "return tostring(require('ui.source_viewer').get_mode())"),
            "Shift+F didn't enter live_bound_clip mode")

        expected = self.source_in + offset
        actual_engine = self._src_engine_position()
        self.assertEqual(expected, actual_engine, (
            f"Shift+F must match-frame map rec_playhead → source: "
            f"source_in({self.source_in}) + (rec_playhead({rec_target}) - "
            f"sequence_start({self.seq_start})) = {expected}; got "
            f"{actual_engine}. If src engine sits at {rec_target}, the "
            f"executor is copying verbatim instead of mapping through "
            f"the clip."))
        self.assertEqual(expected, self._src_tab_playhead(),
            "src tab (master.playhead_position) must equal the mapped frame")

        focused = self._focused_panel()
        self.assertEqual("timeline", focused, (
            "Shift+F must keep focus on the Timeline (the src tab on "
            "the timeline is the user-facing readout for the viewer); "
            f"focused panel is {focused!r}"))

    # ── Scenario 1b: rec playhead beyond the clip clamps to source_out ────
    def test_rec_playhead_beyond_clip_clamps_to_source_out(self) -> None:
        clip_info = self.eval(
            f"local c = require('models.clip').load('{self.clip_id}'); "
            "return string.format('%d|%d', c.duration, c.source_out)")
        duration, source_out = (int(x) for x in clip_info.strip('"').split('|'))

        # Rec playhead 500 frames past the clip's right edge → would map
        # to source_out + 500 if unclamped.
        beyond = self.seq_start + duration + 500
        self._set_record_playhead(beyond)
        self._shift_f()

        unclamped = self.source_in + (beyond - self.seq_start)
        clamped = max(self.source_in, min(source_out, unclamped))
        actual_engine = self._src_engine_position()
        self.assertEqual(clamped, actual_engine, (
            f"Rec playhead {beyond} (past clip end {self.seq_start + duration}) "
            f"should clamp src playhead to clip's source bound; expected "
            f"{clamped}, got {actual_engine}. Unclamped value would be {unclamped}."))
        self.assertEqual(clamped, self._src_tab_playhead(),
            "src tab (master.playhead_position) must reflect the clamp too")

    # ── Scenario 2: Joe's repro — Shift+F, `, move rec, Shift+F ───────────
    def test_joe_repro_second_shift_f_uses_moved_rec_playhead(self) -> None:
        # Step a: park rec at clip_start+10, Shift+F.
        self._set_record_playhead(self.seq_start + 10)
        self._shift_f()
        self.assertEqual(self.source_in + 10, self._src_engine_position(),
            "first Shift+F mapping wrong")

        # Step b: toggle tabs (the manual `\``).
        self.eval(
            "require('core.command_manager').execute('ToggleSourceRecordTab', "
            "{ project_id=require('core.command_manager').get_active_project_id() })")

        # Step c: move rec to clip_start+60.
        self._set_record_playhead(self.seq_start + 60)

        # Step d: Shift+F same clip again — src must now reflect new rec.
        self._shift_f()
        actual_engine = self._src_engine_position()
        self.assertEqual(self.source_in + 60, actual_engine, (
            f"Joe's repro: after moving rec playhead by +60 frames and "
            f"re-Shift+F'ing the same clip, src engine expected at "
            f"{self.source_in + 60} (source_in + new offset); got "
            f"{actual_engine}. If it sits at {self.source_in + 10}, the "
            f"second Shift+F is using the stale rec-playhead value."))


if __name__ == "__main__":
    unittest.main()
