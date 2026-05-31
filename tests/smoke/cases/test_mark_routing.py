"""
SetMark routing (spec 017) — pressing ``I`` writes mark_in to the
sequence loaded into the engine that the *focused* monitor side owns:
source_monitor focused → masterclip (source) sequence; timeline_monitor
focused → record (timeline) sequence. Regression target: pressing I
with the source side focused once wrote the mark to the record-side
sequence instead of the master being viewed.

Origin: tests/integration/test_mark_routing.lua. The Lua test stubs
engine positions via internal APIs; this smoke seeds positions through
real ruler clicks on each displayed tab so the routing is exercised
end-to-end through transport.engine_for_target().
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


# Offsets from each sequence's start_timecode_frame, chosen distinct
# enough that no accidental routing coincidence could pass both methods.
RECORD_PLAYHEAD_OFFSET = 47
SOURCE_PLAYHEAD_OFFSET = 113


class TestMarkRoutingFollowsFocus(JVESmokeCase):
    """`I` press routes SetMark by the focused monitor's engine binding."""

    # ----- helpers -------------------------------------------------------

    def _record_seq_id(self) -> str:
        return self.eval_str(
            "local sid = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(type(sid) == 'string' and sid ~= '', "
            "       'record engine has no loaded sequence — fixture broken'); "
            "return sid")

    def _source_seq_id(self) -> str:
        return self.eval_str(
            "local sid = require('core.playback.transport')"
            ".source_engine.loaded_sequence_id; "
            "assert(type(sid) == 'string' and sid ~= '', "
            "       'source engine has no loaded sequence — did Shift+F fire?'); "
            "return sid")

    def _seq_mark_in(self, seq_id: str) -> int:
        # -1 sentinel surfaces the unset (nil) case without int() parse error.
        return self.eval_int(
            f"return (require('models.sequence').load('{seq_id}').mark_in) or -1")

    def _seq_start_tc(self, seq_id: str) -> int:
        return self.eval_int(
            f"return require('models.sequence').load('{seq_id}').start_timecode_frame")

    def _displayed_tab_kind(self) -> str:
        return self.eval_str(
            "return tostring(require('core.debug_helpers').displayed_tab_kind())")

    # ----- methods (order-sensitive) -------------------------------------

    def test_01_source_focused_writes_master_mark(self) -> None:
        # Live-bind a clip into the source viewer so the source engine
        # has a loaded sequence to route SetMark against.
        rec_seq = self._record_seq_id()
        rec_start = self._seq_start_tc(rec_seq)
        clip_pick_frame = rec_start + RECORD_PLAYHEAD_OFFSET

        # Park record playhead on a real interior clip frame, then Shift+F.
        info = self.eval(
            "local clips = require('ui.timeline.timeline_state')"
            ":get_tab_strip():displayed_clips(); "
            "for _, c in ipairs(clips) do "
            "  if not c.is_gap and c.duration >= 20 then "
            "    return string.format('%d', c.sequence_start + 5) "
            "  end "
            "end; "
            "error('fixture has no interior media clip')")
        clip_pick_frame = int(info.strip('"'))
        self.move_playhead_to(clip_pick_frame)

        self.focus_panel("timeline")
        self.key("Shift+F")

        # Source engine should now be bound to a master source sequence.
        src_seq = self._source_seq_id()
        self.assertNotEqual(src_seq, rec_seq,
            "Shift+F bound source engine to the timeline sequence — "
            "live-bound load_clip should target the master, not the record.")

        # Seed the SOURCE engine playhead by switching to source tab and
        # clicking its ruler. This routes through the displayed-sequence
        # ruler (per move_playhead_to docstring) — the click moves the
        # currently-displayed (source) sequence's playhead.
        self.key("Grave")  # toggle to source tab
        self.assertEqual("source", self._displayed_tab_kind(),
            "Grave from timeline focus did not switch to source tab — "
            "subsequent ruler click will land on the wrong sequence.")
        src_start = self._seq_start_tc(src_seq)
        src_target = src_start + SOURCE_PLAYHEAD_OFFSET
        self.move_playhead_to(src_target)

        # Seed the RECORD engine playhead by toggling back and clicking.
        self.key("Grave")
        self.assertEqual("record", self._displayed_tab_kind(),
            "Grave did not return to record tab.")
        rec_target = rec_start + RECORD_PLAYHEAD_OFFSET
        self.move_playhead_to(rec_target)

        # Both engines should now report distinct positions. Verify before
        # touching marks so a routing assertion can't be masked by a
        # mis-seeded playhead.
        src_engine_pos = self.eval_int(
            "return require('core.playback.transport')"
            ".source_engine:get_position()")
        rec_engine_pos = self.eval_int(
            "return require('core.playback.transport')"
            ".record_engine:get_position()")
        self.assertEqual(src_target, src_engine_pos, (
            f"source engine playhead seed failed: expected {src_target}, "
            f"got {src_engine_pos}. Ruler click on source tab did not "
            f"reach the source engine — rest of test would be against an "
            f"unseeded engine."))
        self.assertEqual(rec_target, rec_engine_pos, (
            f"record engine playhead seed failed: expected {rec_target}, "
            f"got {rec_engine_pos}."))

        # Precondition: marks start clean on both sides (anamnesis fresh).
        self.assertEqual(-1, self._seq_mark_in(src_seq),
            "fixture precondition: master sequence mark_in should be nil "
            "before any mark is set; prior test contamination if not.")
        self.assertEqual(-1, self._seq_mark_in(rec_seq),
            "fixture precondition: record sequence mark_in should be nil.")

        # Focus the SOURCE monitor — engine_for_target() must now resolve
        # to the source engine; SetMark routes there.
        self.focus_panel("source_monitor")
        self.assertEvalEqual("source_monitor",
            'return require("ui.focus_manager").get_focused_panel()',
            msg="setUp: focus did not anchor on source_monitor before I press")

        self.key("I")

        master_mark = self._seq_mark_in(src_seq)
        timeline_mark = self._seq_mark_in(rec_seq)
        self.assertEqual(src_target, master_mark, (
            f"ROUTING BUG: source-focused SetMark must write the master "
            f"(source) sequence mark_in={src_target}; got {master_mark}. "
            f"-1 means no mark was set; another value means SetMark fired "
            f"against the wrong engine. Dispatch chain (I → SetMark → "
            f"command_manager auto-inject sequence_id from "
            f"transport.engine_for_target()) is broken upstream of the "
            f"executor."))
        self.assertEqual(-1, timeline_mark, (
            f"ROUTING BUG: source-focused SetMark must NOT touch the "
            f"record (timeline) sequence mark_in; got {timeline_mark}. "
            f"engine_for_target() returned the record engine despite the "
            f"source monitor being focused."))

    def test_02_record_focused_writes_timeline_mark(self) -> None:
        # Undo restores the master mark to nil — the same fresh-state
        # the Lua original wanted before the second press.
        self.key("Cmd+Z")

        src_seq = self._source_seq_id()
        rec_seq = self._record_seq_id()

        self.assertEqual(-1, self._seq_mark_in(src_seq), (
            "Cmd+Z did not restore master sequence mark_in to nil — "
            "second routing assertion can't distinguish a fresh write "
            "from leftover state."))

        # Make sure we're back on the record tab and focus the timeline
        # monitor. engine_for_target() must now resolve to the record
        # engine regardless of which tab is displayed (017: routing
        # follows focused-monitor side, not displayed tab).
        if self._displayed_tab_kind() != "record":
            self.key("Grave")
        self.assertEqual("record", self._displayed_tab_kind(),
            "could not return to record tab for record-focused press")

        # The record-engine playhead seeded in test_01 should still hold.
        rec_start = self._seq_start_tc(rec_seq)
        rec_target = rec_start + RECORD_PLAYHEAD_OFFSET
        rec_engine_pos = self.eval_int(
            "return require('core.playback.transport')"
            ".record_engine:get_position()")
        self.assertEqual(rec_target, rec_engine_pos, (
            f"record engine playhead drifted between methods: expected "
            f"{rec_target} from test_01 seed, got {rec_engine_pos}. "
            f"Re-seed before continuing or routing assertion is invalid."))

        self.focus_panel("timeline_monitor")
        self.assertEvalEqual("timeline_monitor",
            'return require("ui.focus_manager").get_focused_panel()',
            msg="setUp: focus did not anchor on timeline_monitor before I press")

        self.key("I")

        timeline_mark = self._seq_mark_in(rec_seq)
        master_mark = self._seq_mark_in(src_seq)
        self.assertEqual(rec_target, timeline_mark, (
            f"ROUTING BUG: record-focused SetMark must write the record "
            f"(timeline) sequence mark_in={rec_target}; got {timeline_mark}. "
            f"-1 means no mark was set; another value means SetMark fired "
            f"against the wrong engine."))
        self.assertEqual(-1, master_mark, (
            f"ROUTING BUG: record-focused SetMark must NOT touch the "
            f"master (source) sequence (was restored to nil by Cmd+Z); "
            f"got {master_mark}. engine_for_target() routed to the source "
            f"engine despite the timeline monitor being focused."))


if __name__ == "__main__":
    unittest.main()
