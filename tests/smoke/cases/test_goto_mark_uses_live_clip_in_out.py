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
            "    return string.format('%s|%d|%d|%d|%s', c.id, "
            "      c.source_in, c.source_out, c.sequence_start, c.sequence_id) "
            "  end "
            "end; "
            "error('no media clip with valid source range in fixture')")
        clip_id, src_in_str, src_out_str, seq_start_str, source_seq_id = \
            info.strip('"').split('|', 4)
        expected_in = int(src_in_str)
        expected_out_park = int(src_out_str) - 1  # GoToMarkOut parks at out-1 (exclusive)
        clip_seq_start = int(seq_start_str)

        # ── Pollute the displayed sequence's mark_in/mark_out with values
        # at unrelated timeline frames — simulates a prior staged-mode
        # SetMark session that left stale row marks. If GoToMark* reads
        # the row (the bug), it'll park at one of these. If it reads the
        # live override (the fix), it'll park at the clip's source_in/out.
        #
        # Set via real keypresses: I and O on the timeline scope set marks
        # on the displayed sequence. Picking two arbitrary timeline frames
        # well away from the target clip so any leak is obvious.
        self.focus_panel("timeline")
        bogus_in_frame = clip_seq_start + 1
        bogus_out_frame = clip_seq_start + 2
        self.move_playhead_to(bogus_in_frame)
        self.key("I")
        self.move_playhead_to(bogus_out_frame)
        self.key("O")

        # Park the playhead inside the target clip and load it live via
        # Shift+F (the canonical live-bound entry — see
        # test_keymap_shift_f_opens_clip_in_source_viewer).
        mid_frame = clip_seq_start + 1
        self.move_playhead_to(mid_frame)
        self.focus_panel("timeline")
        self.key("Shift+F")
        self.assertEqual("live_bound_clip", self.eval_str(
            "return tostring(require('ui.source_viewer').get_mode())"),
            "setUp: Shift+F didn't enter live_bound_clip mode")
        self.assertEqual(clip_id, self.eval_str(
            "return tostring(require('ui.source_viewer').get_live_clip_id())"),
            "setUp: Shift+F bound the wrong clip")

        # Press Shift+I (GoToMark in). Keymap routes Shift+I to
        # "GoToMark in @timeline @source_monitor @timeline_monitor"; with
        # the timeline focused it dispatches against the displayed
        # (source_seq_id) sequence. Live-bound override should win.
        self.key("Shift+I")
        after_in = self.eval_int(
            f"return require('core.debug_helpers').playhead_of('{source_seq_id}')")
        self.assertEqual(expected_in, after_in, (
            f"GoToMarkIn in live-bound mode expected to park at "
            f"clip.source_in={expected_in}; got {after_in}. Master row "
            f"mark_in was set to {bogus_in_frame} (stale) — if the command "
            f"read that instead of the live override, the user jumps to a "
            f"frame they can't see marked, breaking the 'mark I see is "
            f"the mark I jump to' invariant."))

        # Press Shift+O (GoToMark out).
        self.key("Shift+O")
        after_out = self.eval_int(
            f"return require('core.debug_helpers').playhead_of('{source_seq_id}')")
        self.assertEqual(expected_out_park, after_out, (
            f"GoToMarkOut in live-bound mode expected to park at "
            f"clip.source_out - 1 = {expected_out_park}; got {after_out}. "
            f"Master row mark_out was set to {bogus_out_frame} (stale)."))


if __name__ == "__main__":
    unittest.main()
