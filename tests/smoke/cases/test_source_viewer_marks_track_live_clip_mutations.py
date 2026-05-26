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

        # Find a media clip with all three kinds of headroom:
        #   - source_in >= 10        — can walk source earlier by 5
        #   - duration > 50          — non-trivial clip
        #   - has a real prior clip on the same track (NOT the first
        #     clip on its track) — BRE silent-no-ops on in-edge ripple
        #     into the implicit pre-clip gap, so the test needs the
        #     prior-clip-as-absorber path. (Per memory:
        #     todo_test_source_viewer_marks_track_live_clip_mutations
        #     calls out this exact trap — picking the first clip on
        #     its track masquerades as "signal didn't fire" when
        #     really BRE refused to do anything.)
        # Group clips by track + sort by sequence_start so we can skip
        # the first-on-track clip (where in-edge ripple silent-no-ops).
        info = self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            "local tracks = {}; "
            "for _, t in ipairs(ts.get_all_tracks() or {}) do tracks[t.id] = t end; "
            "local by_track = {}; "
            "for _, c in ipairs(ts.get_clips()) do "
            "  if not c.is_gap then "
            "    by_track[c.track_id] = by_track[c.track_id] or {}; "
            "    table.insert(by_track[c.track_id], c); "
            "  end "
            "end; "
            "for _, list in pairs(by_track) do "
            "  table.sort(list, function(a,b) return (a.sequence_start or 0) < (b.sequence_start or 0) end); "
            "end; "
            "for _, list in pairs(by_track) do "
            "  local t = tracks[list[1].track_id]; "
            "  if t and t.track_type == 'VIDEO' then "
            "    for i = 2, #list do "
            "      local c = list[i]; "
            "      if (c.duration or 0) > 50 and (c.source_in or 0) >= 10 then "
            "        return string.format('%s|%s', c.id, c.track_id) "
            "      end "
            "    end "
            "  end "
            "end; "
            "error('no non-first video clip with source headroom in fixture')")
        clip_id, track_id = info.strip('"').split('|', 1)

        # Load into source viewer in live-bound mode.
        self.eval(
            "require('ui.source_viewer').load_clip("
            f"'{clip_id}', require('models.clip').load('{clip_id}'))")
        self.assertEqual(clip_id, self.eval_str(
            "return tostring(require('ui.source_viewer').get_live_clip_id())"),
            "setUp: load_clip did not pin the clip in live-bound mode")

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
        result_summary = self.eval_str(
            "local cm = require('core.command_manager'); "
            f"local r = cm.execute('BatchRippleEdit', {{ "
            f"sequence_id='{seq_id}', "
            f"edge_infos = {{ {{ clip_id='{clip_id}', edge_type='in', trim_type='ripple', track_id='{track_id}' }} }}, "
            "delta_frames = -5 }); "
            "return tostring(r.success) .. ':' .. tostring(r.error_message or 'ok')")
        self.assertTrue(result_summary.startswith('true:'),
            f"BatchRippleEdit failed: {result_summary}")

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
