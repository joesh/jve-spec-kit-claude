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
    python3 -m unittest tests.live.cases.test_source_viewer_marks_track_live_clip_mutations -v
"""

import unittest

from tests.live.runner.case import JVESmokeCase

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

        # Load into source viewer in live-bound mode via real input:
        # ensure record tab is displayed, park playhead on the clip,
        # then press Shift+F (OpenClipInSourceMonitor — 019 FR-024).
        self.ensure_record_tab()
        clip_start_frame = self.eval_int(
            f"return require('core.debug_helpers').clip_field('{clip_id}', 'sequence_start')")
        # Position playhead a few frames into the clip so Shift+F lands on it.
        self.move_playhead_to(clip_start_frame + 2)
        self.focus_panel("timeline")
        self.key("Shift+F")
        self.assertEqual(clip_id, self.eval_str(
            "return tostring(require('core.debug_helpers').source_viewer_clip_id())"),
            "setUp: Shift+F did not pin the clip in live-bound mode")

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

        # External mutation via real UI: ripple the in-edge by -5 frames.
        # Shift+F auto-switched the displayed tab to the source master, so
        # we have to swap back to the record tab to click the clip on the
        # record timeline. The source viewer's live-bound pin survives the
        # tab swap (019 FR-024 contract).
        # Then click_clip_edge picks the in-edge as ripple, and Shift+Comma
        # nudges -5 via NudgeSelection → BatchRippleEdit. No
        # command_manager.execute() shortcut — all real OS input.
        self.ensure_record_tab()
        self.click_clip_edge(clip_id, "in", "ripple")
        self.focus_panel("timeline")
        self.key("Shift+Comma")

        after_clip_source_in = self.eval_int(
            f"return require('models.clip').load('{clip_id}').source_in")
        # Shift+Comma → NudgeSelection magnitude=5 → BatchRippleEdit -5 on
        # the in-edge moves source_in DOWN by 5 (trimming the head leftward
        # exposes 5 more source frames at the start). Assert the exact
        # delta — a future keymap default change (e.g. magnitude=10) would
        # silently pass an inequality check while testing the wrong thing.
        self.assertEqual(before_clip_source_in - 5, after_clip_source_in, (
            f"Shift+Comma ripple-in by -5 expected source_in "
            f"{before_clip_source_in} -> {before_clip_source_in - 5}; "
            f"got {after_clip_source_in}. If delta is 0, ripple didn't "
            f"fire; if a different magnitude, NudgeSelection's default "
            f"changed and this test needs updating."))

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
