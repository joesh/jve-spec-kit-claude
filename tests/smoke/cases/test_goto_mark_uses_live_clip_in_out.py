"""
019 FR-016d consumer: GoToMarkIn / GoToMarkOut must park the playhead
at the LIVE-BOUND CLIP's source_in / source_out, not the master source
sequence's mark_in / mark_out row.

Bug observed manually (2026-05-21): Joe loaded a clip live (Shift+F).
Source viewer + source tab correctly displayed marks at the clip's
source_in/out (post-display-wiring fix). But pressing Shift+I parked
the playhead at the MASTER source sequence's persisted mark_in row —
a stale value from a prior staged-mode SetMark. The displayed mark
and the GoToMark destination diverged.

Root cause: GoToMarkIn/Out read seq.mark_in/out from the sequence row
directly, never consulting effective_source's override slot. The
display path was wired to consult it (this commit's predecessor);
GoToMark* must consult the same channel for the user-visible "the
mark I see is the mark I jump to" invariant.

This test pins both directions: park at clip.source_in (GoToMarkIn)
and at clip.source_out - 1 (GoToMarkOut — exclusive convention).

Run:
    python3 -m unittest tests.smoke.cases.test_goto_mark_uses_live_clip_in_out -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestGoToMarkUsesLiveClipInOut(JVESmokeCase):
    """Shift+I / Shift+O must respect the live-clip overrides."""

    def test_goto_mark_in_parks_at_clip_source_in_in_live_bound_mode(self) -> None:
        seq_id = self.eval_str(
            "local sid = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(type(sid) == 'string' and sid ~= '', "
            "       'record engine has no loaded sequence — fixture broken'); "
            "return sid")

        info = self.eval(
            "local clips = require('ui.timeline.timeline_state').get_tab_strip():displayed_clips(); "
            "for _, c in ipairs(clips) do "
            "  if not c.is_gap "
            "     and type(c.source_in) == 'number' "
            "     and type(c.source_out) == 'number' "
            "     and c.source_out > c.source_in + 1 then "
            "    return string.format('%s|%d|%d|%s', c.id, "
            "      c.source_in, c.source_out, c.sequence_id) "
            "  end "
            "end; "
            "error('no media clip with valid source range in fixture')")
        clip_id, src_in_str, src_out_str, source_seq_id = info.strip('"').split('|', 3)
        expected_in = int(src_in_str)
        expected_out_park = int(src_out_str) - 1  # GoToMarkOut parks at out-1 (exclusive)

        # Pollute the master source sequence's mark_in/mark_out with a
        # different value — this simulates a prior staged-mode SetMark
        # session that left stale row marks. If GoToMark* reads the row
        # (the bug), it'll park here. If it reads the override (the
        # fix), it'll park at the clip's source_in.
        bogus_mark_in = expected_in + 1000
        bogus_mark_out = expected_in + 2000
        self.eval(
            f"local s = require('models.sequence').load('{source_seq_id}'); "
            f"s.mark_in = {bogus_mark_in}; "
            f"s.mark_out = {bogus_mark_out}; "
            "assert(s:save())")

        # Load the clip in live-bound mode.
        self.eval(f"require('ui.source_viewer').load_clip('{clip_id}')")
        self.assertEqual("live_bound_clip", self.eval_str(
            "return tostring(require('ui.source_viewer').get_mode())"),
            "setUp: load_clip didn't enter live_bound_clip mode")

        # Press Shift+I via the command path (the keymap routes Shift+I
        # to "GoToMark in @timeline @source_monitor @timeline_monitor";
        # @source_monitor active dispatches against the source seq).
        self.eval(
            "require('core.command_manager').execute('GoToMark', "
            f"{{ sequence_id='{source_seq_id}', project_id=require('core.command_manager').get_active_project_id(), "
            "_positional = { 'in' } })")
        after_in = self.eval_int(
            f"return require('models.sequence').load('{source_seq_id}').playhead_position")
        self.assertEqual(expected_in, after_in, (
            f"GoToMarkIn in live-bound mode expected to park at "
            f"clip.source_in={expected_in}; got {after_in}. Master row "
            f"mark_in is {bogus_mark_in} (stale) — if the command read "
            f"that instead of the live override, the user jumps to a "
            f"frame they can't see marked, breaking the 'mark I see is "
            f"the mark I jump to' invariant."))

        # Press Shift+O.
        self.eval(
            "require('core.command_manager').execute('GoToMark', "
            f"{{ sequence_id='{source_seq_id}', project_id=require('core.command_manager').get_active_project_id(), "
            "_positional = { 'out' } })")
        after_out = self.eval_int(
            f"return require('models.sequence').load('{source_seq_id}').playhead_position")
        self.assertEqual(expected_out_park, after_out, (
            f"GoToMarkOut in live-bound mode expected to park at "
            f"clip.source_out - 1 = {expected_out_park}; got {after_out}. "
            f"Master row mark_out is {bogus_mark_out} (stale)."))


if __name__ == "__main__":
    unittest.main()
