"""
GoToPrevEdit / GoToNextEdit (Up / Down arrow on @timeline) walk the
combined edit points across ALL tracks of the displayed sequence, and
clamp at the timeline's last edit point (Next at end stays).

Origin: tests/integration/test_timeline_edit_navigation.lua. The Lua
test built a bespoke 2-track 4-clip fixture (V1: 0-1500, 3000-4500;
V2: 1200-2400, 5000-6200) and pinned three scenarios:
  - Prev from a gap that's past a V2 clip's end walks to that V2 end
    (multi-track edit point, NOT the lower V1 edit).
  - Next from inside a clip walks to that clip's end.
  - Next at the last edit point stays.

This smoke derives the same scenarios from the anamnesis fixture's
real displayed clips: it builds the sorted combined edit-point set
from `displayed_clips`, then picks (a) a multi-track gap park to
exercise multi-track Prev, (b) a mid-clip park to exercise Next-to-
clip-end, and (c) the last edit point to exercise Next-clamping.
"""

import unittest

from tests.smoke.runner.case import JVESmokeCase

class TestGoToEditsMultiTrackNavigation(JVESmokeCase):
    """Up/Down on @timeline walk multi-track edits and clamp at the end."""

    # ---- helpers (read-only introspection only) ------------------------

    def _edit_points(self) -> list[int]:
        """Sorted, de-duped combined edit-point frames from every
        displayed clip's start and end."""
        csv = self.eval_str(
            "local strip = require('ui.timeline.timeline_state').get_tab_strip(); "
            "assert(strip, 'no tab strip'); "
            "local pts = {}; local seen = {}; "
            "for _, c in ipairs(strip:displayed_clips()) do "
            "  if not c.is_gap then "
            "    local s = c.sequence_start; local e = s + c.duration; "
            "    if not seen[s] then seen[s] = true; pts[#pts+1] = s end "
            "    if not seen[e] then seen[e] = true; pts[#pts+1] = e end "
            "  end "
            "end; "
            "table.sort(pts); "
            "local parts = {}; "
            "for i, p in ipairs(pts) do parts[i] = tostring(p) end; "
            "return table.concat(parts, ',')")
        return [int(x) for x in csv.split(",") if x]

    def _displayed_clip_spans(self):
        """List of (track_id, start, end) for every non-gap displayed clip.
        Anamnesis has many clips → CSV exceeds the 256-char repr cap;
        fetched chunked via the producer/pager primitive (spec phase1-
        test-overhaul.md §"State queries beyond the cap")."""
        rows = self.fetch_str_array(
            "return require('core.debug_helpers')"
            ".stash_displayed_clip_spans()",
            "displayed_clip_spans")
        out = []
        for row in rows:
            tid, s, e = row.split(":")
            out.append((tid, int(s), int(e)))
        return out

    def _playhead(self) -> int:
        return self.eval_int(
            "return require('core.debug_helpers').playhead()")

    def _seek(self, frame: int) -> None:
        """Park the playhead at a specific frame via real ruler click."""
        self.move_playhead_to(frame)
        # Ruler click pixel-rounds; assert we landed on the requested frame.
        got = self._playhead()
        self.assertEqual(frame, got, (
            f"ruler seek to {frame} landed at {got}; pixel resolution "
            f"on the displayed sequence's viewport is too coarse for "
            f"this scenario. The smoke needs a wider viewport or a "
            f"different park frame."))

    # ---- scenarios ----------------------------------------------------

    def test_01_prev_walks_to_multi_track_edit_point(self) -> None:
        """Park in a gap that sits above another track's clip end.
        Prev (Up) must land on that other-track edit point, not on a
        lower edit point one track over."""
        spans = self._displayed_clip_spans()
        self.assertGreater(len(spans), 0,
            "anamnesis fixture has no displayed clips; cannot test edit nav")

        # Find a clip whose end is NOT also an edit point shared with
        # the same track's next clip — i.e. it's a true multi-track
        # boundary that the single-track walk would miss. Park just
        # after it, where no clip on its own track covers, but a
        # different track may.
        edits = self._edit_points()
        target = None
        for tid, s, e in spans:
            # Park at e + small offset; previous edit must be e itself.
            park_frame = e + 30
            # Ensure park_frame is strictly less than the max edit
            # (so Prev has somewhere to land that's still inside the seq).
            if park_frame >= edits[-1]:
                continue
            # Ensure NO clip on the SAME track also starts exactly at e
            # (otherwise the walk to e is trivially same-track).
            shares = any(other_s == e for other_tid, other_s, _ in spans
                         if other_tid == tid)
            if shares:
                continue
            target = (e, park_frame)
            break

        if target is None:
            self.skipTest(
                "anamnesis fixture has no clip boundary suitable for "
                "the multi-track Prev scenario (need a clip end with "
                "no same-track follower and room to park after it)")

        expected_prev, park_frame = target
        self._seek(park_frame)
        self.focus_panel("timeline")
        self.key("Up")
        landed = self._playhead()
        self.assertEqual(expected_prev, landed, (
            f"Prev from {park_frame} expected to land on {expected_prev} "
            f"(nearest lower edit point combining all tracks); got "
            f"{landed}. If a lower frame, the walk only considered the "
            f"current track and skipped the multi-track edit point."))

    def test_02_next_from_inside_clip_walks_to_its_end(self) -> None:
        """Park strictly inside a clip's body. Next (Down) must land on
        the clip's end, which is the nearest upper edit point."""
        spans = self._displayed_clip_spans()
        # Pick the longest clip — gives the most pixel headroom for the
        # ruler-click round-trip, and guarantees an interior park frame.
        spans_sorted = sorted(spans, key=lambda r: r[2] - r[1], reverse=True)
        edits = self._edit_points()
        target = None
        for _tid, s, e in spans_sorted:
            if e - s < 100:
                continue
            park = s + (e - s) // 2
            # Expected next edit = smallest edit > park. By construction
            # that's e (interior of [s,e), nothing else inside).
            expected_next = None
            for p in edits:
                if p > park:
                    expected_next = p
                    break
            if expected_next == e:
                target = (park, expected_next)
                break

        self.assertIsNotNone(target,
            "no clip interior suitable for Next-to-clip-end scenario "
            "in fixture")

        park_frame, expected_next = target
        self._seek(park_frame)
        self.focus_panel("timeline")
        self.key("Down")
        landed = self._playhead()
        self.assertEqual(expected_next, landed, (
            f"Next from {park_frame} (interior of a clip) expected to "
            f"land on the clip's end at {expected_next}; got {landed}."))

    def test_03_next_at_last_edit_point_stays(self) -> None:
        """Park on the timeline's last edit point. Next (Down) must NOT
        move past it — the walk clamps at the highest edit."""
        edits = self._edit_points()
        last = edits[-1]
        self._seek(last)
        self.focus_panel("timeline")
        self.key("Down")
        landed = self._playhead()
        self.assertEqual(last, landed, (
            f"Next at the timeline's last edit point ({last}) must "
            f"stay put; got {landed}. If higher, the walk produced a "
            f"frame past the last edit (no clamp). If lower, Next "
            f"moved backwards — a different bug."))

if __name__ == "__main__":
    unittest.main()
