"""
``F`` (MatchFrame) — full resolution-rules coverage.

Origin: ``tests/integration/test_match_frame.lua`` — 12 scenarios that
pin MatchFrame's clip-under-playhead resolution rules and the
side-effect of writing the clip's source range onto the loaded master
sequence (mark_in / mark_out / playhead).

The single-clip happy path (Test 3) is already pinned by
``test_keymap_f_match_frame.py``. This file groups the remaining
scenarios that ARE exercisable through real OS input on the
anamnesis-derived template:

- gap-under-playhead → F is a no-op (source viewer staging unchanged)
- marks/playhead written to master_clip reflect the spanning clip's
  source_in / source_out / sequence-relative playhead offset

The topology-dependent scenarios (Tests 4/5/6/9/10/11 — overlapping
V1+V2 clips, video-trumps-audio, audio-selection-override) cannot be
synthesized from anamnesis without a clip-overlap fixture-control
primitive AND a multi-select keystroke primitive (Cmd+Click). Test 8
(source_viewer.load_master_clip error surfacing) needs the ability to
patch a Lua function from the test body, which the no-mocks rule
forbids. Those scenarios are skipped here with TODO pointers — see
MIGRATION_ANALYSIS.md entry for `test_match_frame.lua`.

Methods chain in declared order; state accumulates intentionally
(JVESmokeCase shared-class-fixture convention).

Run:
    python3 -m unittest tests.smoke.cases.test_match_frame -v
"""

import sys
import unittest
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestMatchFrame(JVESmokeCase):
    """MatchFrame resolution + master-write side effects."""

    # ----- helpers --------------------------------------------------

    def _ensure_record_tab_focused(self) -> None:
        self.ensure_record_tab()
        self.focus_panel("timeline")
        self.assertEvalEqual("timeline",
            'return require("ui.focus_manager").get_focused_panel()',
            msg="setUp: focus did not anchor on timeline before F press")

    def _pick_clip_with_body(self) -> tuple[str, int, int, int, str, str]:
        """Return ``(clip_id, seq_start, source_in, source_out,
        master_seq_id, rec_seq_id)`` for a non-gap clip whose master
        sequence id is well-formed and whose source range is non-trivial."""
        info = self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            "local rec_seq = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(rec_seq, 'record engine has no loaded sequence'); "
            "local picked; "
            "for _, c in ipairs(ts.get_tab_strip():displayed_clips()) do "
            "  if not c.is_gap "
            "     and type(c.duration) == 'number' and c.duration > 48 "
            "     and type(c.source_in) == 'number' "
            "     and type(c.source_out) == 'number' "
            "     and c.source_out > c.source_in + 1 "
            "     and c.sequence_id and c.sequence_id ~= '' then "
            "    picked = c; break "
            "  end "
            "end; "
            "assert(picked, 'fixture: no clip with master + valid source range'); "
            "return string.format('%s|%d|%d|%d|%s|%s', "
            "  picked.id, picked.sequence_start, picked.source_in, "
            "  picked.source_out, picked.sequence_id, rec_seq)")
        parts = info.strip('"').split("|", 5)
        return (parts[0], int(parts[1]), int(parts[2]),
                int(parts[3]), parts[4], parts[5])

    def _find_gap_frame(self) -> Optional[int]:
        """Find a frame on the displayed record sequence that has no
        clip under it on any track. Returns nil if every frame is
        covered (no gap available in this fixture)."""
        result = self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            "local clips = ts.get_tab_strip():displayed_clips(); "
            "local max_end = 0; "
            "local covered = {}; "
            "for _, c in ipairs(clips) do "
            "  if not c.is_gap then "
            "    local s = c.sequence_start; "
            "    local e = s + c.duration; "
            "    for f = s, e - 1 do covered[f] = true end; "
            "    if e > max_end then max_end = e end "
            "  end "
            "end; "
            "for f = 0, max_end - 1 do "
            "  if not covered[f] then return tostring(f) end "
            "end; "
            "return ''")
        s = result.strip('"')
        return int(s) if s else None

    # ----- Test 1: gap → F is a no-op --------------------------------

    def test_01_f_over_gap_does_not_change_source_viewer(self) -> None:
        """Test 1 (lua): no clips under playhead → MatchFrame fails.
        Domain-level observation: no source viewer state change."""
        self._ensure_record_tab_focused()
        gap = self._find_gap_frame()
        if gap is None:
            self.skipTest(
                "anamnesis fixture has no gap on the displayed record "
                "sequence — every frame is covered, so the gap-error "
                "scenario can't be exercised. Would need a fixture-"
                "control primitive to insert a gap.")

        before_staged = self.eval_str(
            "return require('ui.source_viewer').get_staged_seq_id() or ''")
        before_mode = self.eval_str(
            "return tostring(require('ui.source_viewer').get_mode())")

        self.move_playhead_to(gap)
        # Belt-and-braces: clear selection so the selection-tiebreaker
        # path can't pick a clip not under the playhead.
        self.eval(
            "local rec_seq = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "require('ui.timeline.timeline_state').set_selection({})")

        self.key("F")

        after_staged = self.eval_str(
            "return require('ui.source_viewer').get_staged_seq_id() or ''")
        after_mode = self.eval_str(
            "return tostring(require('ui.source_viewer').get_mode())")
        self.assertEqual(before_staged, after_staged, (
            f"F over a gap must not change source-viewer staged sequence. "
            f"Before: {before_staged!r}; after: {after_staged!r}. If MatchFrame "
            f"silently loaded something, the gap-error rule has regressed."))
        self.assertEqual(before_mode, after_mode, (
            f"F over a gap must not change source-viewer mode. "
            f"Before: {before_mode!r}; after: {after_mode!r}."))

    # ----- Test 12: master marks/playhead written from clip ---------

    def test_02_master_marks_and_playhead_written_from_clip_source_range(self) -> None:
        """Test 12 (lua): MatchFrame writes master_clip.mark_in =
        clip.source_in, master_clip.mark_out = clip.source_out, and
        master_clip.playhead = source_in + (timeline_playhead -
        sequence_start). User-visible: the source viewer opens parked
        at the same frame the user was looking at on the record side,
        with marks that span the clip's used range."""
        self._ensure_record_tab_focused()
        clip_id, seq_start, src_in, src_out, master_id, rec_seq = \
            self._pick_clip_with_body()

        # Pick an offset comfortably inside the clip body (avoid 0 and
        # the boundary — non-trivial value per CLAUDE.md test-quality rule).
        offset_into_clip = 24
        playhead_frame = seq_start + offset_into_clip
        expected_master_playhead = src_in + offset_into_clip

        self.move_playhead_to(playhead_frame)
        # Clear any leftover selection from prior methods.
        self.eval("require('ui.timeline.timeline_state').set_selection({})")

        # Pollute the master's mark_in/out/playhead with values that
        # don't match what MatchFrame should write. If MatchFrame writes
        # correctly, our assertions pass; if it leaves the stale values,
        # we catch the regression.
        bogus_in = src_in + 9991
        bogus_out = src_in + 9992
        bogus_playhead = src_in + 9993
        self.eval(
            f"local s = require('models.sequence').load('{master_id}'); "
            f"s.mark_in = {bogus_in}; "
            f"s.mark_out = {bogus_out}; "
            f"s.playhead_position = {bogus_playhead}; "
            "assert(s:save())")

        self.key("F")

        loaded_master = self.eval_str(
            "return require('ui.source_viewer').get_staged_seq_id() or ''")
        self.assertEqual(master_id, loaded_master, (
            f"F should have loaded master {master_id!r} for clip "
            f"{clip_id!r}; got {loaded_master!r}. Earlier resolution "
            f"step failed — later mark/playhead assertions would be "
            f"meaningless."))

        m_in = self.eval_int(
            f"return require('models.sequence').load('{master_id}').mark_in")
        m_out = self.eval_int(
            f"return require('models.sequence').load('{master_id}').mark_out")
        m_playhead = self.eval_int(
            f"return require('models.sequence').load('{master_id}')"
            ".playhead_position")

        self.assertEqual(src_in, m_in, (
            f"master.mark_in must == clip.source_in ({src_in}); got "
            f"{m_in}. Stale bogus value was {bogus_in}. MatchFrame did "
            f"not write the clip's source_in onto the master's mark_in row."))
        self.assertEqual(src_out, m_out, (
            f"master.mark_out must == clip.source_out ({src_out}); got "
            f"{m_out}. Stale bogus value was {bogus_out}."))
        self.assertEqual(expected_master_playhead, m_playhead, (
            f"master.playhead must == source_in + (timeline_playhead - "
            f"sequence_start) = {src_in} + {offset_into_clip} = "
            f"{expected_master_playhead}; got {m_playhead}. Stale bogus "
            f"value was {bogus_playhead}. MatchFrame did not map the "
            f"record-side playhead onto the master's playhead row."))

    # ----- Topology-dependent scenarios (skipped) -------------------

    # TODO: needs clip-overlap fixture-control primitive — see
    # MIGRATION_ANALYSIS.md entry for test_match_frame.lua. Anamnesis
    # may or may not contain V1+V2 clips overlapping at a frame; even
    # if it does, we have no way to deterministically locate them.
    @unittest.skip("needs clip-overlap fixture-control primitive")
    def test_03_multi_clip_no_selection_picks_topmost(self) -> None:
        """Test 4 (lua): two video clips at same playhead → topmost
        track_index wins."""

    # TODO: needs Cmd+Click multi-select primitive — see
    # MIGRATION_ANALYSIS.md.
    @unittest.skip("needs Cmd+Click multi-select primitive")
    def test_04_single_selection_overrides_topmost(self) -> None:
        """Test 5 (lua): selecting a non-topmost clip overrides the
        topmost-wins default."""

    @unittest.skip("needs Cmd+Click multi-select primitive")
    def test_05_multi_selection_picks_topmost_selected(self) -> None:
        """Test 6 (lua): with V1+V2 both selected, topmost (V2) wins."""

    # TODO: forbidden by no-mocks rule — Test 8 (lua) monkey-patches
    # source_viewer.load_master_clip to throw and asserts the error
    # surfaces through MatchFrame's result. No UI surface for this;
    # belongs in a unit test of the executor's error-propagation
    # contract, not a smoke.
    @unittest.skip("monkey-patching forbidden by no-mocks rule")
    def test_06_source_viewer_error_surfaces(self) -> None:
        """Test 8 (lua): load_master_clip throws → error propagates."""

    @unittest.skip("needs clip-overlap fixture-control primitive")
    def test_07_video_trumps_audio_with_no_selection(self) -> None:
        """Test 9 / Test 10 (lua): with V1 + audio tracks under
        playhead and no selection, video wins."""

    @unittest.skip("needs Cmd+Click multi-select primitive")
    def test_08_selected_audio_overrides_video_preference(self) -> None:
        """Test 11 (lua): selecting an audio clip overrides the
        video-trumps-audio default."""


if __name__ == "__main__":
    unittest.main()
