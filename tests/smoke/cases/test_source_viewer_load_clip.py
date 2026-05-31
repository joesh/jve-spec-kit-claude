"""
019 source_viewer.load_clip — Shift+F on a selected timeline clip enters
live-bound mode, binds the source monitor to the clip's source master,
and parks the master playhead at the clip's source_in. Deleting the
loaded clip auto-unloads.

Replaces tests/integration/test_source_viewer_load_clip.lua. The
original pinned six scenarios; the three that map to user-visible UI
input are pinned here (Shift+F load, default-park at source_in, auto-
unload on delete). The other three (opts.playhead_frame caller-wins,
parking-clamp out-of-range, sequence_content_changed reload+retitle on
rename) live below the UI surface — they need either internal-API entry
points or an inspector-rename primitive that does not exist yet. Each
is preserved as a skipped placeholder with a TODO.

Run:
    python3 -m unittest tests.smoke.cases.test_source_viewer_load_clip -v
"""

# TODO: needs inspector-rename primitive (F2 on clip name field) for
# the sequence_content_changed reload+retitle scenario. Also needs a
# selection_hub item_type / owner_sequence_id query in core.debug_helpers
# to pin the FR-002 publish contract through real UI. See MIGRATION_ANALYSIS.md.

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestSourceViewerLoadClip(JVESmokeCase):
    """Shift+F on a selected timeline clip live-binds the source viewer."""

    def _pick_clip(self) -> tuple[str, str, int, int, str]:
        """Return (clip_id, owner_seq_id, source_in, source_out, source_seq_id)
        for the first non-gap clip on the displayed record sequence whose
        source range has > 1 frame of room (so we can observe a real park)."""
        info = self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            "local rec_seq = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(rec_seq, 'record engine has no loaded sequence'); "
            "for _, c in ipairs(ts.get_tab_strip():displayed_clips()) do "
            "  if not c.is_gap "
            "     and type(c.source_in) == 'number' "
            "     and type(c.source_out) == 'number' "
            "     and c.source_out > c.source_in + 1 "
            "     and type(c.sequence_id) == 'string' then "
            "    return string.format('%s|%s|%d|%d|%s', c.id, rec_seq, "
            "      c.source_in, c.source_out, c.sequence_id) "
            "  end "
            "end; "
            "error('no media clip with valid source range in fixture')")
        clip_id, owner_seq, sin, sout, src_seq = info.strip('"').split('|', 4)
        return clip_id, owner_seq, int(sin), int(sout), src_seq

    def test_01_shift_f_enters_live_bound_mode(self) -> None:
        clip_id, owner_seq, src_in, _src_out, src_seq = self._pick_clip()

        # Select the clip via a real timeline click.
        self.ensure_record_tab()
        self.click_clip(clip_id)
        self.focus_panel("timeline")

        # Shift+F → OpenClipInSourceMonitor (019 FR-024).
        self.key("Shift+F")

        mode = self.eval_str(
            "return tostring(require('core.debug_helpers').source_viewer_mode())")
        self.assertEqual("live_bound_clip", mode, (
            f"after Shift+F on selected timeline clip {clip_id}, source viewer "
            f"mode must be 'live_bound_clip'; got {mode}. Either the keypress "
            f"never reached OpenClipInSourceMonitor, or load_clip aborted "
            f"before the mode transition."))

        loaded_clip = self.eval_str(
            "return tostring(require('core.debug_helpers').source_viewer_clip_id() or '')")
        self.assertEqual(clip_id, loaded_clip, (
            f"live-bound clip id must match the selected clip ({clip_id}); "
            f"got '{loaded_clip}'."))

        bound_seq = self.eval_str(
            "return tostring(require('core.debug_helpers').source_viewer_sequence_id() or '')")
        self.assertEqual(src_seq, bound_seq, (
            f"source monitor must bind to clip.sequence_id (the source "
            f"master {src_seq}), NOT the owner sequence ({owner_seq}) and "
            f"NOT the clip id. Got '{bound_seq}'."))

        # FR-024 v2: default-park master.playhead at clip.source_in.
        parked = self.eval_int(
            f"return require('core.debug_helpers').playhead_of('{src_seq}')")
        self.assertEqual(src_in, parked, (
            f"default-park: master ({src_seq}) playhead must == "
            f"clip.source_in ({src_in}); got {parked}. The load_clip path "
            f"is not writing the canonical park position via core.playhead.set."))

    def test_02_delete_loaded_clip_auto_unloads(self) -> None:
        # Inherits state from test_01: clip is loaded live-bound and
        # still selected on the timeline.
        loaded_clip = self.eval_str(
            "return tostring(require('core.debug_helpers').source_viewer_clip_id() or '')")
        self.assertNotEqual("", loaded_clip,
            "precondition: test_01 should have left a clip loaded live-bound")

        # Focus the timeline so Delete routes to DeleteSelection
        # (keymap: 'Delete' = 'DeleteSelection' on @timeline).
        self.focus_panel("timeline")
        # Re-select the clip in case focus shifts cleared selection.
        self.click_clip(loaded_clip)
        self.focus_panel("timeline")

        self.key("Delete")

        # FR-004a: clip vanishes → source_viewer must leave live_bound_clip.
        self.wait_for(
            f"return not require('core.debug_helpers').clip_exists('{loaded_clip}')",
            timeout=3.0)

        mode = self.eval_str(
            "return tostring(require('core.debug_helpers').source_viewer_mode())")
        self.assertNotEqual("live_bound_clip", mode, (
            f"after the loaded clip ({loaded_clip}) was deleted from the "
            f"timeline, source viewer must leave live_bound_clip mode "
            f"(FR-004a auto-unload). Mode is still '{mode}' — the deletion "
            f"path is not triggering re-resolve, or re-resolve is not "
            f"detecting the missing clip."))

    @unittest.skip("internal API surface — opts.playhead_frame has no UI keybinding; "
                   "needs explicit Lua entrypoint test or a new primitive.")
    def test_03_opts_playhead_frame_caller_wins(self) -> None:
        """FR-024 v2: opts.playhead_frame overrides default-park. The
        only callers passing playhead_frame are internal (match_frame,
        scripted load). No real-OS-input gesture expresses this option;
        leave as a documented gap."""

    @unittest.skip("internal API surface — parking-clamp branches on the "
                   "opts.playhead_frame value, same gap as test_03.")
    def test_04_parking_clamp_out_of_range(self) -> None:
        """FR-024 v2 clamp: out-of-range opts.playhead_frame snaps to
        [source_in, source_out]. Same UI-surface gap as test_03."""

    @unittest.skip("needs inspector-rename primitive (F2 on clip name field) — "
                   "see TODO at file head and MIGRATION_ANALYSIS.md.")
    def test_05_sequence_content_changed_reload_and_retitle(self) -> None:
        """FR-004b: renaming the loaded clip in the owner sequence fires
        sequence_content_changed; source viewer reloads + retitles to
        include the new name. Needs F2-rename primitive that doesn't
        yet exist."""


if __name__ == "__main__":
    unittest.main()
