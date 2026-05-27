"""
MVC correctness: when an external command mutates the live clip's
source_in / source_out (e.g., timeline ripple-trim, roll, relink), the
source viewer's effective marks must follow.

The source viewer is a View. Its displayed marks come from
``effective_source.get()`` (returns ``(seq_id, in_frame, out_frame)``
when in live-bound mode) which is populated by ``publish_live_bound``
through ``update_effective_source_live`` reading the LIVE clip's
``source_in`` / ``source_out``. The refresh hook subscribes to
``sequence_content_changed`` on the clip's owner sequence: any command
that mutates the live clip must emit that signal so the viewer re-pulls.

Bug: ``BatchRippleEdit`` (and its delegates ``ExtendEdit``,
``RippleTrimEdge``, ``OverwriteTrimEdge``) do not emit
``sequence_content_changed`` after committing. The clip row updates in
the DB but the source viewer's effective marks stay stale until some
unrelated path triggers a refresh. The View is then displaying a frame
range that no longer matches the model.

This test loads a clip into the source viewer, ripples its in-edge from
the timeline, and asserts ``effective_source.get()`` reflects the new
``source_in`` immediately.

Run:
    python3 -m unittest tests.smoke.cases.test_source_viewer_marks_track_live_clip_mutations -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestSourceViewerMarksTrackLiveClipMutations(JVESmokeCase):
    """External mutation to the live clip must refresh source viewer marks."""

    def test_in_edge_ripple_updates_source_viewer_effective_in(self) -> None:
        seq_id = self.eval_str(
            "local sid = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(type(sid) == 'string' and sid ~= '', "
            "       'record engine has no loaded sequence — fixture broken'); "
            "return sid")

        # Hard-coded clip from the Anamnesis-gold-timeline fixture. The
        # fixture is fixed (rebuilt deterministically from
        # tests/fixtures/resolve/anamnesis-gold-timeline.drp), so the
        # set of "BRE will actually move this on in-edge ripple -5"
        # clips is also fixed. Picking arbitrarily here saves a
        # whole-timeline dry-run scan per setUp.
        #
        # Why hard-coding matters: source_in >= N + duration > N looks
        # like sufficient headroom but isn't — many clips silently
        # clamp via `apply_media_limits` (either because the clip sits
        # at file frame 0, or because of audio-TC unit confusion
        # against video TC on multi-stream files; both root-caused in
        # todo_019_media_tc_off_media). The canonical signal is BRE's
        # own `result_data.clamped_delta_frames == requested_delta`.
        #
        # If the fixture changes and this clip disappears or becomes
        # un-movable: re-run /tmp/bre_probe.py against the new
        # template, pick any (mover=True, VIDEO, duration > 50,
        # source_in > 100) clip, paste its ids here.
        clip_id = "000d79cc-7aad-4df8-b4ca-0916ec8d990c"
        track_id = "142f526f-a96a-47e3-9997-175a86af2082"
        # Confirm the fixture still carries this clip (asserts loudly
        # if the fixture was regenerated without updating these ids).
        self.assertEqual(track_id, self.eval_str(
            f"return tostring(require('models.clip').load('{clip_id}').track_id)"),
            f"hard-coded clip {clip_id} not on hard-coded track {track_id} — "
            f"fixture changed? regenerate per the comment above")

        # Load into source viewer in live-bound mode.
        self.eval(
            "require('ui.source_viewer').load_clip("
            f"'{clip_id}', require('models.clip').load('{clip_id}'))")
        self.assertEqual(clip_id, self.eval_str(
            "return tostring(require('ui.source_viewer').get_live_clip_id())"),
            "setUp: load_clip did not pin the clip in live-bound mode")

        # spec 022 / 1.3a-ii: no workaround needed. BRE's build_clip_cache
        # reads from the ACTIVE record tab's per-tab cache directly via
        # strip:find_record_tab_by_sequence_id(ctx.sequence_id), so the
        # edit lands correctly even while the displayed tab is the source
        # master (this test's setup loads a clip into source viewer, which
        # auto-switches displayed to the master).
        before_clip_source_in = self.eval_int(
            f"return require('models.clip').load('{clip_id}').source_in")
        before_effective = self.eval_str(
            "local s, i, o = require('core.effective_source').get(); "
            "return string.format('%s|%s|%s', tostring(s), tostring(i), tostring(o))")
        before_seq, before_in_str, _ = before_effective.split('|', 2)
        self.assertEqual(str(before_clip_source_in), before_in_str, (
            f"setUp: effective_source.get() in_frame ({before_in_str}) "
            f"should already match clip.source_in ({before_clip_source_in}) "
            f"after load_clip; got {before_effective}"))

        # External mutation: ripple the in-edge by -5 frames. This moves
        # the clip's source_in (in-edge ripple grows duration + walks
        # source_in earlier; sequence_start stays).
        # Verify BRE actually applied the requested delta (didn't clamp).
        # Reads top-level fields surfaced by the executor (see
        # batch_ripple_edit.lua finalize_execution real-path). A
        # clamped_delta_frames != requested signals the test picked an
        # un-movable clip (see hard-coding rationale above).
        result_summary = self.eval_str(
            "local cm = require('core.command_manager'); "
            f"local r = cm.execute('BatchRippleEdit', {{ "
            f"sequence_id='{seq_id}', "
            f"edge_infos = {{ {{ clip_id='{clip_id}', edge_type='in', trim_type='ripple', track_id='{track_id}' }} }}, "
            "delta_frames = -5 }); "
            "return tostring(r.success) "
            "  .. '|err=' .. tostring(r.error_message or 'ok') "
            "  .. '|req=' .. tostring(r.requested_delta_frames) "
            "  .. '|clamp=' .. tostring(r.clamped_delta_frames)")
        self.assertTrue(result_summary.startswith('true|'),
            f"BatchRippleEdit failed: {result_summary}")
        self.assertIn("|req=-5|clamp=-5", result_summary, (
            f"BRE clamped the requested delta away from -5 — selector "
            f"picked an un-movable clip: {result_summary}"))

        after_clip_source_in = self.eval_int(
            f"return require('models.clip').load('{clip_id}').source_in")
        self.assertNotEqual(before_clip_source_in, after_clip_source_in, (
            "ripple in-edge by -5 expected to move clip.source_in; if it "
            "didn't, the test isn't exercising the right mutation"))

        after_effective = self.eval_str(
            "local s, i, o = require('core.effective_source').get(); "
            "return string.format('%s|%s|%s', tostring(s), tostring(i), tostring(o))")
        _, after_in_str, _ = after_effective.split('|', 2)
        self.assertEqual(str(after_clip_source_in), after_in_str, (
            f"After BatchRippleEdit on live clip {clip_id} "
            f"(source_in: {before_clip_source_in} -> {after_clip_source_in}), "
            f"effective_source.get() in_frame expected to follow to "
            f"{after_clip_source_in}; got {after_in_str}. "
            f"BatchRippleEdit must emit sequence_content_changed on its "
            f"owner_sequence_id so source_viewer's refresh_live_bound "
            f"re-pulls the clip and republishes its source_in/out."))


if __name__ == "__main__":
    unittest.main()
