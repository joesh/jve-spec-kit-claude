"""
019 live-bound trim routing — when the source viewer is in live_bound_clip
mode, an ``I`` press in the @source_monitor scope dispatches
SetMarkAndTrimIfClip, which trims the loaded clip's source_in (and ``O``
trims source_out) instead of writing a sequence mark. Plain SetMark in
the @timeline scope stays pure — it mutates the addressed sequence row
and never touches the live-bound clip. Collapse / inversion presses
(IN at-or-past OUT, OUT at-or-past IN) are no-ops that never reach the
SQL CHECK(duration_frames > 0).

Origin: tests/integration/test_set_mark_and_trim_if_clip_routes_to_trim.lua.
The Lua test passed ``frame=`` directly to ``execute_interactive`` and
drove ``source_viewer.load_clip`` from the test body; this smoke drives
the same behavior end-to-end through Shift+F, tab-toggle, real ruler
clicks for playhead seeding, and real I / O keypresses on the focused
source_monitor.

Run:
    python3 -m unittest tests.live.cases.test_set_mark_and_trim_if_clip_routes_to_trim -v
"""

import unittest

from tests.live.runner.case import JVESmokeCase

# Offsets chosen so I-then-O leaves a non-trivial source range and the
# collapse cases land cleanly at-or-past the surviving boundary.
TRIM_IN_OFFSET = 50    # frame inside clip source range for I press
TRIM_OUT_OFFSET = 150  # frame for O press (must stay > new source_in)

class TestSetMarkAndTrimIfClipRoutesToTrim(JVESmokeCase):
    """Live-bound source viewer routes I/O to clip trim, not sequence mark."""

    # ----- helpers -----------------------------------------------------------

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

    def _live_clip_id(self) -> str:
        return self.eval_str(
            "return tostring(require('core.debug_helpers').source_viewer_clip_id())")

    def _clip_source_in(self, clip_id: str) -> int:
        return self.eval_int(
            f"return require('core.debug_helpers').clip_field('{clip_id}', 'source_in')")

    def _clip_source_out(self, clip_id: str) -> int:
        return self.eval_int(
            f"return require('core.debug_helpers').clip_field('{clip_id}', 'source_out')")

    def _clip_duration(self, clip_id: str) -> int:
        return self.eval_int(
            f"return require('core.debug_helpers').clip_field('{clip_id}', 'duration')")

    def _seq_mark_in(self, seq_id: str) -> int:
        # -1 sentinel surfaces the unset (nil) case without int() parse error.
        return self.eval_int(
            f"return (require('models.sequence').load('{seq_id}').mark_in) or -1")

    def _seq_mark_out(self, seq_id: str) -> int:
        return self.eval_int(
            f"return (require('models.sequence').load('{seq_id}').mark_out) or -1")

    def _displayed_tab_kind(self) -> str:
        return self.eval_str(
            "return tostring(require('core.debug_helpers').displayed_tab_kind())")

    def _ensure_tab(self, kind: str) -> None:
        """Toggle Grave until displayed tab == kind. Asserts after."""
        if self._displayed_tab_kind() != kind:
            self.key("Grave")
        self.assertEqual(kind, self._displayed_tab_kind(),
            f"could not switch to {kind} tab via Grave")

    def _move_source_engine_playhead(self, frame: int) -> None:
        """Seed the source-engine playhead by switching to the source tab
        and ruler-clicking at `frame`. Restores record tab afterward."""
        self._ensure_tab("source")
        self.move_playhead_to(frame)
        actual = self.eval_int(
            "return require('core.playback.transport')"
            ".source_engine:get_position()")
        # Ruler click has ±1 frame rounding; assert within tolerance.
        self.assertLessEqual(abs(actual - frame), 1, (
            f"source engine playhead seed failed: clicked ruler at {frame}, "
            f"engine reports {actual}. Subsequent I/O press would act on "
            f"the wrong frame; abort here so the assertion below is honest."))
        self._ensure_tab("record")

    # ----- methods (order-sensitive, share state) ----------------------------

    def test_01_live_bound_in_trims_clip_source_in(self) -> None:
        # Park record playhead on an interior media clip with enough source
        # headroom for our I→O→collapse sequence to stay legal.
        info = self.eval(
            "local clips = require('ui.timeline.timeline_state')"
            ":get_tab_strip():displayed_clips(); "
            "for _, c in ipairs(clips) do "
            "  if not c.is_gap "
            "     and type(c.source_in) == 'number' "
            "     and type(c.source_out) == 'number' "
            "     and (c.source_out - c.source_in) >= 200 then "
            "    return string.format('%d', c.sequence_start + 5) "
            "  end "
            "end; "
            "error('fixture has no interior media clip with >=200 source frames')")
        click_frame = int(info.strip('"'))
        self.move_playhead_to(click_frame)

        # Shift+F live-binds the clip under the playhead into the source
        # viewer. We anchor focus on timeline first so the keymap reaches
        # the right scope.
        self.focus_panel("timeline")
        self.key("Shift+F")

        # The source viewer should now report live_bound_clip mode and
        # expose the clip id we just loaded.
        self.assertEqual("live_bound_clip", self.eval_str(
            "return tostring(require('core.debug_helpers').source_viewer_mode())"),
            "Shift+F did not enter live_bound_clip mode — load_clip dispatch broken.")
        clip_id = self._live_clip_id()
        self.assertNotIn(clip_id, ("", "nil"),
            "source_viewer_clip_id is empty after Shift+F.")

        src_seq = self._source_seq_id()
        rec_seq = self._record_seq_id()
        self.assertNotEqual(src_seq, rec_seq,
            "Shift+F bound the source engine to the timeline sequence — "
            "live-bound load_clip should target the master source, not the record.")

        # Snapshot the live-bound clip's source range. The trim assertions
        # express their expected values in domain terms (target frame chosen
        # below) — we keep the original endpoints around only to bound the
        # offsets and detect untouched-edge regressions.
        src_in_before = self._clip_source_in(clip_id)
        src_out_before = self._clip_source_out(clip_id)
        self.assertGreater(src_out_before - src_in_before, 200,
            f"clip {clip_id} source range too small for test: "
            f"({src_in_before}, {src_out_before}).")

        # Precondition: neither the record sequence nor the master source
        # sequence carries a stale mark from prior tests.
        self.assertEqual(-1, self._seq_mark_in(rec_seq),
            "fixture precondition: record sequence mark_in should be nil.")
        self.assertEqual(-1, self._seq_mark_in(src_seq),
            "fixture precondition: master source sequence mark_in should be nil.")

        # Seed the source-engine playhead at a frame inside the clip's
        # source range. This is where the I press should land the new
        # source_in.
        target_in = src_in_before + TRIM_IN_OFFSET
        self._move_source_engine_playhead(target_in)

        # Focus the source monitor so I dispatches through the
        # @source_monitor scope → SetMarkAndTrimIfClip in live-bound mode.
        self.focus_panel("source_monitor")
        self.assertEvalEqual("source_monitor",
            'return require("ui.focus_manager").get_focused_panel()',
            msg="setUp: focus did not anchor on source_monitor before I press")

        self.key("I")

        # Domain assertion: live-bound IN moves clip.source_in to the
        # source engine's reported playhead, leaves source_out alone, and
        # writes NO sequence mark on either side.
        src_in_after = self._clip_source_in(clip_id)
        src_out_after = self._clip_source_out(clip_id)
        self.assertEqual(target_in, src_in_after, (
            f"live-bound IN expected to move clip {clip_id}.source_in to "
            f"{target_in} (source engine playhead at press time); got "
            f"{src_in_after}. Dispatch chain (I → @source_monitor → "
            f"SetMarkAndTrimIfClip → live-bound branch → OverwriteTrimEdge/"
            f"RippleTrimEdge) is broken upstream of the clip mutator."))
        self.assertEqual(src_out_before, src_out_after, (
            f"live-bound IN must NOT touch source_out; was {src_out_before}, "
            f"now {src_out_after}. The trim path is mutating both edges."))
        self.assertEqual(-1, self._seq_mark_in(rec_seq), (
            "live-bound IN must NOT write the record sequence mark_in — "
            "the routing fell through to plain SetMark."))
        self.assertEqual(-1, self._seq_mark_in(src_seq), (
            "live-bound IN must NOT write the master source sequence "
            "mark_in — the routing fell through to plain SetMark on "
            "the source sequence."))

    def test_02_live_bound_out_trims_clip_source_out(self) -> None:
        # Inherits the trimmed-in clip from test_01. We pick a new source
        # playhead well past the new source_in but well below source_out
        # so the O press lands a legal, non-collapse trim.
        clip_id = self._live_clip_id()
        self.assertNotIn(clip_id, ("", "nil"),
            "test_02 expected live-bound clip carried over from test_01.")
        src_in_now = self._clip_source_in(clip_id)
        src_out_before = self._clip_source_out(clip_id)

        target_out = src_in_now + TRIM_OUT_OFFSET
        self.assertLess(target_out, src_out_before,
            f"test_02 target_out {target_out} must stay below current "
            f"source_out {src_out_before} to avoid a no-op collapse.")

        self._move_source_engine_playhead(target_out)

        self.focus_panel("source_monitor")
        self.key("O")

        src_in_after = self._clip_source_in(clip_id)
        src_out_after = self._clip_source_out(clip_id)
        self.assertEqual(target_out, src_out_after, (
            f"live-bound OUT expected to move clip {clip_id}.source_out to "
            f"{target_out} (source engine playhead at press time); got "
            f"{src_out_after}. SetMarkAndTrimIfClip OUT branch is broken."))
        self.assertEqual(src_in_now, src_in_after, (
            f"live-bound OUT must NOT touch source_in; was {src_in_now}, "
            f"now {src_in_after}."))

    def test_03_plain_set_mark_on_timeline_stays_pure(self) -> None:
        # Focus the timeline_monitor — the I press now dispatches via the
        # @timeline scope (plain SetMark on the record engine). The live-
        # bound clip from test_01/02 must remain untouched.
        clip_id = self._live_clip_id()
        self.assertNotIn(clip_id, ("", "nil"),
            "test_03 expected live-bound clip carried over from earlier methods.")
        src_in_before = self._clip_source_in(clip_id)
        src_out_before = self._clip_source_out(clip_id)

        rec_seq = self._record_seq_id()
        # Make sure we're displaying the record tab so the ruler click
        # seeds the record engine, not source.
        self._ensure_tab("record")
        rec_start = self.eval_int(
            f"return require('models.sequence').load('{rec_seq}').start_timecode_frame")
        rec_target = rec_start + 37  # arbitrary interior frame
        self.move_playhead_to(rec_target)
        rec_pos = self.eval_int(
            "return require('core.playback.transport')"
            ".record_engine:get_position()")
        self.assertLessEqual(abs(rec_pos - rec_target), 1,
            f"record-engine seed failed: clicked {rec_target}, got {rec_pos}")

        # Snapshot record sequence mark_in before the press (could be nil
        # or a leftover from an earlier method — we assert the delta below).
        rec_mark_before = self._seq_mark_in(rec_seq)
        self.assertEqual(-1, rec_mark_before, (
            "fixture precondition: record sequence mark_in should still be "
            "nil — earlier methods only mutated the live-bound clip."))

        self.focus_panel("timeline_monitor")
        self.key("I")

        # Plain SetMark must write the record sequence mark_in to the
        # record-engine playhead, and MUST leave the live-bound clip alone.
        self.assertEqual(rec_pos, self._seq_mark_in(rec_seq), (
            f"plain SetMark expected to write record sequence mark_in to "
            f"{rec_pos} (record engine playhead at press time); got "
            f"{self._seq_mark_in(rec_seq)}. @timeline scope SetMark is "
            f"broken or the press routed somewhere else."))
        self.assertEqual(src_in_before, self._clip_source_in(clip_id), (
            f"plain SetMark must NOT mutate the live-bound clip's "
            f"source_in; was {src_in_before}, now "
            f"{self._clip_source_in(clip_id)}. SetMark has a hidden "
            f"live-bound branch — it should not."))
        self.assertEqual(src_out_before, self._clip_source_out(clip_id), (
            f"plain SetMark must NOT mutate the live-bound clip's "
            f"source_out; was {src_out_before}, now "
            f"{self._clip_source_out(clip_id)}."))

    def test_04_collapse_in_at_or_past_out_is_noop(self) -> None:
        # Inverted-IN press: seed source playhead at-or-past the current
        # source_out. Must report a UX no-op (no crash, no mutation, no
        # SQL CHECK violation per TSO 2026-05-20).
        clip_id = self._live_clip_id()
        self.assertNotIn(clip_id, ("", "nil"),
            "test_04 expected live-bound clip carried over from earlier methods.")
        src_in_before = self._clip_source_in(clip_id)
        src_out_before = self._clip_source_out(clip_id)
        dur_before = self._clip_duration(clip_id)

        # Pick a frame strictly past source_out so the press is unambiguously
        # collapse-territory.
        target_collapse = src_out_before + 5
        self._move_source_engine_playhead(target_collapse)

        self.focus_panel("source_monitor")
        self.key("I")

        self.assertEqual(src_in_before, self._clip_source_in(clip_id), (
            f"collapse IN-past-OUT must NOT mutate clip source_in; was "
            f"{src_in_before}, now {self._clip_source_in(clip_id)}. The "
            f"executor wrote past the OUT boundary (TSO 2026-05-20 "
            f"SQL CHECK regression)."))
        self.assertEqual(src_out_before, self._clip_source_out(clip_id), (
            f"collapse IN-past-OUT must NOT mutate clip source_out; was "
            f"{src_out_before}, now {self._clip_source_out(clip_id)}."))
        self.assertEqual(dur_before, self._clip_duration(clip_id), (
            f"collapse IN-past-OUT must NOT mutate clip duration; was "
            f"{dur_before}, now {self._clip_duration(clip_id)}."))

    def test_05_collapse_out_at_or_past_in_is_noop(self) -> None:
        # Symmetric: O at-or-past current source_in is also a no-op.
        clip_id = self._live_clip_id()
        self.assertNotIn(clip_id, ("", "nil"),
            "test_05 expected live-bound clip carried over from earlier methods.")
        src_in_before = self._clip_source_in(clip_id)
        src_out_before = self._clip_source_out(clip_id)
        dur_before = self._clip_duration(clip_id)

        # Frame at-or-before source_in. Use src_in_before itself (OUT==IN
        # is the collapse boundary).
        target_collapse = src_in_before
        self._move_source_engine_playhead(target_collapse)

        self.focus_panel("source_monitor")
        self.key("O")

        self.assertEqual(src_in_before, self._clip_source_in(clip_id), (
            f"collapse OUT-at-IN must NOT mutate clip source_in; was "
            f"{src_in_before}, now {self._clip_source_in(clip_id)}."))
        self.assertEqual(src_out_before, self._clip_source_out(clip_id), (
            f"collapse OUT-at-IN must NOT mutate clip source_out; was "
            f"{src_out_before}, now {self._clip_source_out(clip_id)}. "
            f"The executor collapsed the source range (TSO 2026-05-20 "
            f"SQL CHECK regression)."))
        self.assertEqual(dur_before, self._clip_duration(clip_id), (
            f"collapse OUT-at-IN must NOT mutate clip duration; was "
            f"{dur_before}, now {self._clip_duration(clip_id)}."))

if __name__ == "__main__":
    unittest.main()
