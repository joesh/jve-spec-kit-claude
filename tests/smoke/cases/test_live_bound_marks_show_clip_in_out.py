"""
019 FR-016d display path: when the source viewer is in live_bound_clip
mode, the source-side ruler (source monitor's mark bar) and the source
tab (timeline tab strip) must show the loaded clip's source_in /
source_out as visible marks.

Bug observed manually (2026-05-21): after Shift+F loads a clip in
live-bound mode, the source monitor + source tab show NO in/out marks.
``effective_source.get()`` carries the right values (clip.source_in,
clip.source_out) but the display surfaces don't consult those overrides
— they pull from the master source sequence's ``mark_in/mark_out`` row,
which is nil for fresh clips. Only the EDIT-into-timeline path
(Insert/Overwrite) was wired to consult ``effective_source`` per
FR-016d; the matching display wiring was never landed.

This test pins both display surfaces:
  1. ``SequenceMonitor:get_mark_in/out`` (drives the source monitor's
     mark bar widget — sequence_monitor.lua:472).
  2. ``timeline_state.get_source_mark_in/out`` (drives the source tab's
     ruler via the display-aware mark accessors).

Run:
    python3 -m unittest tests.smoke.cases.test_live_bound_marks_show_clip_in_out -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestLiveBoundMarksShowClipInOut(JVESmokeCase):
    """Source monitor + source tab must show clip in/out as marks in live-bound mode."""

    def test_marks_reflect_clip_source_in_out_in_live_bound_mode(self) -> None:
        seq_id = self.eval_str(
            "local sid = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(type(sid) == 'string' and sid ~= '', "
            "       'record engine has no loaded sequence — fixture broken'); "
            "return sid")

        # Pick any interior media clip with non-zero source range.
        info = self.eval(
            "local clips = require('ui.timeline.timeline_state').get_tab_strip():displayed_clips(); "
            "for _, c in ipairs(clips) do "
            "  if not c.is_gap "
            "     and type(c.source_in) == 'number' "
            "     and type(c.source_out) == 'number' "
            "     and c.source_out > c.source_in then "
            "    return string.format('%s|%d|%d', c.id, c.source_in, c.source_out) "
            "  end "
            "end; "
            "error('no media clip with valid source range in fixture')")
        clip_id, src_in_str, src_out_str = info.strip('"').split('|', 2)
        expected_in = int(src_in_str)
        expected_out = int(src_out_str)

        # Load the clip in live-bound mode.
        self.eval(
            f"require('ui.source_viewer').load_clip('{clip_id}')")
        self.assertEqual("live_bound_clip", self.eval_str(
            "return tostring(require('ui.source_viewer').get_mode())"),
            "setUp: load_clip didn't enter live_bound_clip mode")

        # ── Source monitor's mark bar (sequence_monitor.lua:472 consumes
        #    get_mark_in/get_mark_out into the bar widget). ──
        sm_in = self.eval_str(
            "local pm = require('ui.panel_manager'); "
            "local sm = pm.get_sequence_monitor('source_monitor'); "
            "assert(sm, 'source monitor not registered'); "
            "return tostring(sm:get_mark_in())")
        sm_out = self.eval_str(
            "local pm = require('ui.panel_manager'); "
            "local sm = pm.get_sequence_monitor('source_monitor'); "
            "assert(sm, 'source monitor not registered'); "
            "return tostring(sm:get_mark_out())")
        self.assertEqual(str(expected_in), sm_in, (
            f"source monitor's mark bar reads in via "
            f"SequenceMonitor:get_mark_in(); for a live-bound clip with "
            f"source_in={expected_in}, expected {expected_in}, got {sm_in}. "
            f"The mark bar widget at sequence_monitor.lua:472 will draw "
            f"NO mark-in if this returns nil — that's the manually-"
            f"observed bug."))
        self.assertEqual(str(expected_out), sm_out, (
            f"source monitor's mark bar reads out via "
            f"SequenceMonitor:get_mark_out(); for a live-bound clip with "
            f"source_out={expected_out}, expected {expected_out}, got "
            f"{sm_out}. Mark bar draws no mark-out if nil."))

        # ── Source tab marks (timeline_state.get_source_mark_in/out is
        #    the strip-authoritative accessor consumed by the ruler when
        #    the source tab is the displayed tab). ──
        tab_in = self.eval_str(
            "return tostring(require('ui.timeline.timeline_state').get_source_mark_in())")
        tab_out = self.eval_str(
            "return tostring(require('ui.timeline.timeline_state').get_source_mark_out())")
        self.assertEqual(str(expected_in), tab_in, (
            f"source tab's get_source_mark_in() expected {expected_in} "
            f"(clip.source_in) in live-bound mode; got {tab_in}. The "
            f"timeline ruler reading display marks via "
            f"get_display_mark_in() will draw NO mark when the source "
            f"tab is displayed."))
        self.assertEqual(str(expected_out), tab_out, (
            f"source tab's get_source_mark_out() expected {expected_out} "
            f"(clip.source_out) in live-bound mode; got {tab_out}."))


if __name__ == "__main__":
    unittest.main()
