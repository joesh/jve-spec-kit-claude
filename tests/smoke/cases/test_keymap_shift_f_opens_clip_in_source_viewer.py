"""
Phase A Tier 1 — ``Shift+F`` loads the timeline clip under the playhead
into the source viewer in live-bound mode.

Per 019 FR-024: Shift+F is the live-bound entry point. Distinct from F
(MatchFrame), which loads the underlying MASTER with copied marks. The
source viewer ends up in mode == "live_bound_clip" with the resolved
clip id pinned for trim-back operations.

Domain assertion: after pressing Shift+F with the playhead parked
inside an interior clip, source_viewer.get_live_clip_id() returns
that clip's id and source_viewer.get_mode() == "live_bound_clip".

Run:
    python3 -m unittest tests.smoke.cases.test_keymap_shift_f_opens_clip_in_source_viewer -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestShiftFLoadsClipInSourceViewer(JVESmokeCase):
    """`Shift+F` must load the clip under the playhead into the source viewer."""

    def test_shift_f_loads_playhead_clip_into_source_viewer_live_bound(self) -> None:
        seq_id = self.eval_str(
            "local sid = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(type(sid) == 'string' and sid ~= '', "
            "       'record engine has no loaded sequence — fixture broken'); "
            "return sid")

        # Pick an interior clip + a frame in the middle of it (avoids
        # boundary ambiguity at clip edges where multiple clips may
        # claim the same frame).
        info = self.eval(
            "local clips = require('ui.timeline.timeline_state').get_tab_strip():displayed_clips(); "
            "for _, c in ipairs(clips) do "
            "  if c.duration >= 10 then "
            "    return string.format('%s|%d', c.id, c.sequence_start + 5) "
            "  end "
            "end; "
            "error('no clip with duration >= 10 found in fixture')")
        clip_id, mid_frame_str = info.strip('"').split('|', 1)
        mid_frame = int(mid_frame_str)

        # Park playhead inside that clip.
        self.eval(
            "require('core.command_manager').execute('SetPlayhead', "
            f"{{ sequence_id='{seq_id}', playhead_position={mid_frame} }})")
        self.assertEqual(mid_frame, self.eval_int(
            "return require('core.playback.transport')"
            ".engine_for_target():get_position()"),
            "setUp: playhead didn't reach the seeded frame")

        # Focus the timeline so we're in the canonical scope for the
        # global Shift+F binding (no @scope on the binding; pick a
        # focus that doesn't override).
        self.focus_panel("timeline")

        self.key("Shift+F")

        # Source viewer must be in live-bound mode with this clip pinned.
        loaded = self.eval_str(
            "return tostring(require('ui.source_viewer').get_live_clip_id())")
        mode = self.eval_str(
            "return tostring(require('ui.source_viewer').get_mode())")
        self.assertEqual(clip_id, loaded, (
            f"Shift+F expected to load clip {clip_id} (under playhead at "
            f"{mid_frame}) into the source viewer in live-bound mode; "
            f"got live_clip_id={loaded}. Dispatch chain (keymap → "
            f"QShortcut → OpenClipInSourceMonitor executor → "
            f"source_viewer.load_clip) is broken upstream of source_viewer."))
        self.assertEqual("live_bound_clip", mode,
            f"after Shift+F, source viewer mode expected 'live_bound_clip'; "
            f"got {mode}")


if __name__ == "__main__":
    unittest.main()
