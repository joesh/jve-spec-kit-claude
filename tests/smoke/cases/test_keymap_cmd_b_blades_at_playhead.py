"""
Cmd+B (Blade / razor at playhead) — pressing Cmd+B with the timeline
focused and the playhead strictly inside a clip on an armed track
splits that clip in two at the playhead. After the press, the frame
that was previously inside one clip is now exactly on the boundary
between two adjacent clips covering the same range.

Selection semantics (Premiere Cmd+K parity — see spec 013
contracts/commands.md "Cmd+B keyboard adapter"):

  - INTERSECTING selection (some selected clip is on an armed track
    AND strictly spans the playhead): cut narrows to those tracks
    only. Other armed tracks with spanning clips are left alone.
  - NON-INTERSECTING selection (empty, or no selected clip spans the
    playhead, or all selected spanning clips are on non-armed tracks):
    fall back to "cut every armed track that spans." A stale selection
    far from the playhead doesn't turn Cmd+B into a surprise no-op.

Four scenarios are pinned below:

  - No clips selected → all armed-track spanning clips get split.
  - An UNRELATED clip selected (not spanning playhead) → fallback path;
    all armed-track spanning clips get split.
  - The SPANNING clip itself selected → narrows to that clip's track
    (a one-track narrowing is still narrowing).
  - Two armed tracks both spanning playhead; selection contains only
    ONE of the two spanning clips → ONLY the selected track gets cut,
    the sibling armed track is left alone. This is the scenario that
    distinguishes the narrows-when-intersecting contract from a
    selection-irrelevant contract.

History: Blade's T045a rewrite (2026-04-24) made Blade a pure-model
command requiring `sequence_id`/`blade_frame`/`track_ids` from the
caller. The keymap binding ``"Cmd+B" = "Blade @timeline"`` never
supplied `blade_frame` or `track_ids` — those aren't in command_manager's
auto-inject set — so every Cmd+B press logged a LUA CALLBACK ERROR
and silently no-op'd. No existing test caught it because the lone
"keyboard Blade" lua test mocked execute_interactive (defeating the
dispatch-validation path), and the model-tier Blade test called
``Blade.execute({...})`` directly with hand-built params. This smoke
case drives the *real* dispatch chain (Cmd+B → QShortcut →
command_manager → BladeAtPlayhead adapter → Blade) end-to-end against
a real fixture. The adapter (`core.commands.blade_at_playhead`)
resolves `blade_frame` from the active record playhead and `track_ids`
from autoselect=1, locked=0 tracks before dispatching Blade.

Domain assertion (no executor internals named): pick a clip on an
armed video track whose body is wide enough to seed the playhead
strictly inside it; assert that track has exactly N video clips
before the press, and N+1 after, with adjacent halves meeting at the
seeded playhead frame. ``find_strictly_spanning(track, frame)``
returning a clip pre-press AND nil post-press is the user-visible
contract of "the playhead is no longer in the middle of a clip" that
Blade promises.

Run:
    python3 -m unittest tests.smoke.cases.test_keymap_cmd_b_blades_at_playhead -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


# Frames from the clip's left boundary at which to seed the playhead.
# Must be strictly between sequence_start and sequence_end for Blade to
# treat it as inside-the-clip (boundary-touching is a no-op per spec).
SEED_OFFSET_INTO_CLIP = 24


class TestCmdBBladesClipAtPlayhead(JVESmokeCase):
    """Cmd+B on @timeline must split the spanning clip at the playhead,
    irrespective of which clips happen to be selected."""

    def setUp(self) -> None:
        super().setUp()
        # Long-lived runner; prior tests may have left the source tab
        # displayed and/or selection populated. Blade fires on the active
        # *record* sequence regardless (`sequence_id` for active-record
        # routing) but the user-visible state must match what a human
        # would see when they press Cmd+B.
        self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            "if ts.get_displayed_tab_kind() ~= 'record' then "
            "  local active = ts.get_active_sequence_id(); "
            "  assert(active, 'no active sequence to switch back to'); "
            "  ts.switch_to_record_tab(active); "
            "end")
        # Canonical baseline: nothing selected. Per-scenario tests below
        # may then layer a specific selection on top via SelectClips.
        self._deselect_all()

    # ── Probes ─────────────────────────────────────────────────────────

    def _pick_armed_video_clips_with_body(self, n: int) -> list[dict]:
        """Return the first ``n`` distinct armed (autoselect=1, locked=0)
        video clips whose duration is wide enough to seed the playhead
        strictly inside. Each entry: ``{id, track_id, seq_start, seq_end,
        rec_seq}``. Asserts when the fixture can't supply ``n``."""
        info = self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            "local Track = require('models.track'); "
            "local rec_seq = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(rec_seq, 'record engine has no loaded sequence'); "
            "local armed = {}; "
            "for _, t in ipairs(Track.find_by_sequence(rec_seq)) do "
            "  if t.track_type == 'VIDEO' and t.autoselect and not t.locked then "
            "    armed[t.id] = true "
            "  end "
            "end; "
            "local picked = {}; "
            "for _, c in ipairs(ts.get_tab_strip():displayed_clips()) do "
            "  if armed[c.track_id] and not c.is_gap "
            "     and type(c.sequence_start) == 'number' "
            "     and type(c.duration) == 'number' "
            f"     and c.duration > {SEED_OFFSET_INTO_CLIP + 1} then "
            "    picked[#picked + 1] = c "
            f"    if #picked >= {n} then break end "
            "  end "
            "end; "
            f"assert(#picked >= {n}, 'fixture has fewer than {n} armed-video "
            "clip(s) wide enough'); "
            "local lines = {} "
            "for i, c in ipairs(picked) do "
            "  lines[i] = string.format('%s|%s|%d|%d|%s', "
            "    c.id, c.track_id, c.sequence_start, "
            "    c.sequence_start + c.duration, rec_seq) "
            "end; "
            "return table.concat(lines, ';')")
        out = []
        for row in info.strip('"').split(";"):
            parts = row.split("|", 4)
            out.append({
                "id":         parts[0],
                "track_id":   parts[1],
                "seq_start":  int(parts[2]),
                "seq_end":    int(parts[3]),
                "rec_seq":    parts[4],
            })
        return out

    def _pick_two_armed_clips_spanning_common_frame(
            self) -> tuple[dict, dict, int]:
        """Find two clips on DIFFERENT armed tracks whose time ranges
        overlap, and return them along with a frame that strictly lies
        inside both. Used by the intersecting-narrow scenario.

        Walks every armed clip and looks for the first pair on
        different tracks with overlap > 2*SEED_OFFSET (enough room to
        seed the playhead well inside both). Anamnesis-class fixtures
        have linked V+A throughout, so the first armed-video clip
        almost always pairs with its sibling A-track clip.

        Returns ``(a, b, common_frame)`` where ``a`` and ``b`` have the
        same shape as ``_pick_armed_video_clips_with_body`` entries."""
        info = self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            "local Track = require('models.track'); "
            "local rec_seq = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(rec_seq, 'record engine has no loaded sequence'); "
            "local armed = {}; "
            "for _, t in ipairs(Track.find_by_sequence(rec_seq)) do "
            "  if t.autoselect and not t.locked then armed[t.id] = true end "
            "end; "
            "local armed_clips = {}; "
            "for _, c in ipairs(ts.get_tab_strip():displayed_clips()) do "
            "  if armed[c.track_id] and not c.is_gap "
            "     and type(c.sequence_start) == 'number' "
            "     and type(c.duration) == 'number' then "
            "    armed_clips[#armed_clips + 1] = c "
            "  end "
            "end; "
            f"local min_overlap = {2 * SEED_OFFSET_INTO_CLIP + 2}; "
            "local pair_a, pair_b, common; "
            "for i = 1, #armed_clips do "
            "  for j = i + 1, #armed_clips do "
            "    local a, b = armed_clips[i], armed_clips[j]; "
            "    if a.track_id ~= b.track_id then "
            "      local lo = math.max(a.sequence_start, b.sequence_start); "
            "      local hi = math.min(a.sequence_start + a.duration, "
            "                          b.sequence_start + b.duration); "
            "      if hi - lo >= min_overlap then "
            "        pair_a, pair_b = a, b; "
            "        common = lo + math.floor((hi - lo) / 2); "
            "        break "
            "      end "
            "    end "
            "  end "
            "  if pair_a then break end "
            "end; "
            "assert(pair_a and pair_b, "
            "  'fixture has no pair of armed clips on different tracks "
            "with sufficient time overlap'); "
            "return string.format('%s|%s|%d|%d|%s||%s|%s|%d|%d|%s||%d', "
            "  pair_a.id, pair_a.track_id, pair_a.sequence_start, "
            "  pair_a.sequence_start + pair_a.duration, rec_seq, "
            "  pair_b.id, pair_b.track_id, pair_b.sequence_start, "
            "  pair_b.sequence_start + pair_b.duration, rec_seq, "
            "  common)")
        bare = info.strip('"')
        a_raw, b_raw, common_raw = bare.split("||", 2)
        ap = a_raw.split("|", 4)
        bp = b_raw.split("|", 4)
        a = {"id": ap[0], "track_id": ap[1],
             "seq_start": int(ap[2]), "seq_end": int(ap[3]),
             "rec_seq": ap[4]}
        b = {"id": bp[0], "track_id": bp[1],
             "seq_start": int(bp[2]), "seq_end": int(bp[3]),
             "rec_seq": bp[4]}
        return a, b, int(common_raw)

    def _active_project_id(self) -> str:
        return self.eval_str(
            "return require('core.command_manager').get_active_project_id()")

    def _deselect_all(self) -> None:
        # Use the real DeselectAll command — same path a user would take
        # via Esc / equivalent. project_id is the only required arg.
        proj = self._active_project_id()
        self.eval(
            "require('core.command_manager').execute('DeselectAll', "
            f"{{ project_id='{proj}' }})")

    def _select_only(self, clip_id: str, sequence_id: str) -> None:
        # SelectClips with no modifier and target_clip_ids=[id] is the
        # "replace selection with just this clip" form — equivalent to
        # a plain click on that clip in the timeline.
        proj = self._active_project_id()
        self.eval(
            "require('core.command_manager').execute('SelectClips', "
            f"{{ project_id='{proj}', sequence_id='{sequence_id}', "
            f"target_clip_ids={{'{clip_id}'}} }})")

    def _selected_clip_ids(self) -> list[str]:
        # Return current selection as a list of clip ids — used by the
        # assertion messages to surface why a scenario failed.
        s = self.eval(
            "local ids = {}; "
            "for _, c in ipairs("
            "  require('ui.timeline.timeline_state').get_selected_clips()) do "
            "  ids[#ids + 1] = c.id "
            "end; return table.concat(ids, ',')")
        bare = s.strip('"')
        return [x for x in bare.split(",") if x]

    def _seek_record_playhead(self, seq_id: str, frame: int) -> None:
        # SetPlayhead is the canonical model-write for the playhead;
        # transport listeners pick up the change and seek the engine.
        self.eval(
            "require('core.command_manager').execute('SetPlayhead', "
            f"{{ sequence_id='{seq_id}', playhead_position={frame} }})")

    def _clip_count_on_track(self, track_id: str) -> int:
        # Count non-gap clips currently on the named track. Reads from
        # the live timeline cache (the same state Blade's mutations
        # write through).
        return self.eval_int(
            "local n = 0; "
            "for _, c in ipairs(require('ui.timeline.timeline_state').get_tab_strip():displayed_clips()) do "
            f"  if c.track_id == '{track_id}' and not c.is_gap then n = n + 1 end "
            "end; return n")

    def _strictly_spans(self, track_id: str, frame: int) -> bool:
        # find_strictly_spanning is the same predicate Blade uses to
        # decide whether a track has something to cut. Pre-press: true.
        # Post-press: false (the cut creates a boundary at `frame`, and
        # boundary-touching is excluded from "strictly inside").
        return self.eval_bool(
            "return require('models.clip')."
            f"find_strictly_spanning('{track_id}', {frame}) ~= nil")

    # ── Shared press-and-assert ────────────────────────────────────────

    def _press_cmd_b_and_assert_split(
        self,
        clip_id: str,
        track_id: str,
        rec_seq: str,
        seq_start: int,
        seq_end: int,
        scenario_label: str,
    ) -> None:
        """Seek into ``clip_id``, snapshot state, press Cmd+B, assert
        that clip got split. ``scenario_label`` is woven into failure
        messages so a per-scenario failure names itself."""
        blade_frame = seq_start + SEED_OFFSET_INTO_CLIP
        assert blade_frame < seq_end, (
            f"[{scenario_label}] test fixture violated its own "
            f"precondition: blade_frame={blade_frame} not strictly "
            f"inside clip [{seq_start}, {seq_end})")

        self._seek_record_playhead(rec_seq, blade_frame)

        before_count = self._clip_count_on_track(track_id)
        self.assertTrue(self._strictly_spans(track_id, blade_frame),
            f"[{scenario_label}] precondition: clip {clip_id} on track "
            f"{track_id} must strictly span frame {blade_frame} before "
            f"the press; if this fails, the fixture/seed combination is "
            f"wrong, not Cmd+B.")

        # Snapshot the selection so the failure message can show what
        # was in scope when the press happened.
        selection_at_press = self._selected_clip_ids()

        self.focus_panel("timeline")
        self.assertEvalEqual("timeline",
            'return require("ui.focus_manager").get_focused_panel()',
            msg=f"[{scenario_label}] focus did not anchor on timeline")

        # Real OS keypress — exercises the keymap → QShortcut →
        # command_manager → BladeAtPlayhead → Blade chain in full.
        self.key("Cmd+B")

        after_count = self._clip_count_on_track(track_id)
        still_spanning = self._strictly_spans(track_id, blade_frame)

        self.assertEqual(before_count + 1, after_count, (
            f"[{scenario_label}] after Cmd+B with playhead at {blade_frame} "
            f"strictly inside clip {clip_id} on armed video track "
            f"{track_id} (selection at press: {selection_at_press or 'none'}), "
            f"expected track clip count to grow by 1 (the split's two halves "
            f"replace the original spanning clip). Got: before={before_count}, "
            f"after={after_count}. If after == before, Blade was dispatched "
            f"but refused (check suite.log for LUA CALLBACK ERROR — most "
            f"commonly 'missing required param track_ids', which means the "
            f"BladeAtPlayhead adapter was bypassed and the keymap still "
            f"routes Cmd+B directly to the pure-model Blade). If selection "
            f"was non-empty and after == before, the adapter is now "
            f"selection-gating when it shouldn't be — Avid/Premiere/FCP7 "
            f"all key off track arming, not clip selection."))
        self.assertFalse(still_spanning, (
            f"[{scenario_label}] after Cmd+B, no clip on track {track_id} "
            f"should strictly span frame {blade_frame} — the cut should "
            f"have produced a boundary AT that frame, with the left and "
            f"right halves meeting there. Strictly-spanning still true "
            f"means the split didn't land where it was supposed to."))

    # ── Scenarios ──────────────────────────────────────────────────────

    def test_cmd_b_with_no_selection_splits_spanning_clip(self) -> None:
        """Baseline: no clips selected → no-intersecting-selection
        fallback fires → every armed track with a spanning clip gets
        cut. Asserts on one such track."""
        picks = self._pick_armed_video_clips_with_body(1)
        c = picks[0]
        # Reaffirm baseline (setUp already did this; pin it in the
        # scenario so a failure here surfaces "DeselectAll didn't").
        self.assertEqual([], self._selected_clip_ids(),
            "no-selection scenario: selection should be empty after setUp")
        self._press_cmd_b_and_assert_split(
            c["id"], c["track_id"], c["rec_seq"],
            c["seq_start"], c["seq_end"],
            scenario_label="no selection")

    def test_cmd_b_with_unrelated_clip_selected_falls_back(self) -> None:
        """Non-intersecting selection: a clip OTHER than the spanning
        one is selected (not spanning the playhead). Selection-narrow
        check fails → fallback path → spanning clip still gets cut.
        Premiere parity: stale selection from elsewhere doesn't turn
        Cmd+B into a no-op."""
        picks = self._pick_armed_video_clips_with_body(2)
        unrelated, target = picks[0], picks[1]
        assert unrelated["id"] != target["id"], (
            "fixture probe returned duplicate clip ids")
        self._select_only(unrelated["id"], unrelated["rec_seq"])
        self.assertEqual([unrelated["id"]], self._selected_clip_ids(),
            "unrelated-selection scenario: SelectClips did not replace "
            "selection with just the unrelated clip")
        # We will seed the playhead inside `target` — `unrelated` lives
        # elsewhere, so selection won't intersect; fallback fires.
        self._press_cmd_b_and_assert_split(
            target["id"], target["track_id"], target["rec_seq"],
            target["seq_start"], target["seq_end"],
            scenario_label="unrelated clip selected (non-intersecting)")

    def test_cmd_b_with_spanning_clip_itself_selected_narrows_to_it(self) -> None:
        """Intersecting selection (single-track case): select the
        spanning clip itself. Selection intersects → narrow to that
        clip's track. With only one track in the narrow set, the
        observable outcome is identical to no-selection, but the
        resolution path taken is different (narrow, not fallback)."""
        picks = self._pick_armed_video_clips_with_body(1)
        c = picks[0]
        self._select_only(c["id"], c["rec_seq"])
        self.assertEqual([c["id"]], self._selected_clip_ids(),
            "spanning-selected scenario: SelectClips did not replace "
            "selection with just the spanning clip")
        self._press_cmd_b_and_assert_split(
            c["id"], c["track_id"], c["rec_seq"],
            c["seq_start"], c["seq_end"],
            scenario_label="spanning clip itself selected (narrow=1 track)")

    def test_cmd_b_intersecting_selection_narrows_other_armed_track_untouched(
            self) -> None:
        """Discriminating case: two armed tracks BOTH have a clip that
        strictly spans the playhead. Select only ONE of the two clips.
        Press Cmd+B. The selected clip's track gets cut; the sibling
        armed track is left alone.

        This is the scenario that distinguishes the narrows-when-
        intersecting contract from a selection-irrelevant contract.
        Under "selection irrelevant," both tracks would be cut and the
        sibling-untouched assertion would fail."""
        a, b, common_frame = self._pick_two_armed_clips_spanning_common_frame()
        assert a["id"] != b["id"], "probe returned duplicate clip"
        assert a["track_id"] != b["track_id"], (
            "probe returned two clips on the same track")
        assert a["rec_seq"] == b["rec_seq"], (
            "probe returned clips on different sequences")

        # Seed playhead at the common frame BEFORE selecting — so the
        # spanning check runs against an already-seated playhead.
        self._seek_record_playhead(a["rec_seq"], common_frame)
        self._select_only(a["id"], a["rec_seq"])
        self.assertEqual([a["id"]], self._selected_clip_ids(),
            "intersecting-narrow scenario: SelectClips did not replace "
            "selection with just clip A")

        # Pre-press: both tracks have their spanning clip.
        before_a = self._clip_count_on_track(a["track_id"])
        before_b = self._clip_count_on_track(b["track_id"])
        self.assertTrue(self._strictly_spans(a["track_id"], common_frame),
            f"precondition: clip A {a['id']} on track {a['track_id']} "
            f"must strictly span frame {common_frame}")
        self.assertTrue(self._strictly_spans(b["track_id"], common_frame),
            f"precondition: clip B {b['id']} on track {b['track_id']} "
            f"must strictly span frame {common_frame} (this is the WHOLE "
            f"POINT of this scenario — if B doesn't span, the test "
            f"degenerates into single-track narrowing)")

        self.focus_panel("timeline")
        self.assertEvalEqual("timeline",
            'return require("ui.focus_manager").get_focused_panel()',
            msg="intersecting-narrow scenario: focus didn't anchor on timeline")

        self.key("Cmd+B")

        after_a = self._clip_count_on_track(a["track_id"])
        after_b = self._clip_count_on_track(b["track_id"])

        self.assertEqual(before_a + 1, after_a, (
            f"selected armed track A ({a['track_id']}) should have grown "
            f"by 1 clip after Cmd+B (its spanning clip got split). "
            f"before={before_a}, after={after_a}. If equal, the adapter "
            f"refused the cut for this scenario (check suite.log)."))
        self.assertEqual(before_b, after_b, (
            f"UNSELECTED armed track B ({b['track_id']}) should be "
            f"unchanged after Cmd+B — selection narrows the cut to "
            f"selected/intersecting tracks. before={before_b}, "
            f"after={after_b}. If after == before+1, the adapter is "
            f"ignoring the selection and cutting all armed tracks "
            f"(the pre-fix \"selection irrelevant\" behavior)."))
        self.assertFalse(self._strictly_spans(a["track_id"], common_frame),
            f"after Cmd+B, no clip on track A should strictly span "
            f"frame {common_frame} — the cut should have produced a "
            f"boundary AT that frame.")
        self.assertTrue(self._strictly_spans(b["track_id"], common_frame),
            f"after Cmd+B, track B's spanning clip should still strictly "
            f"span frame {common_frame} — it wasn't selected, so the "
            f"narrow excluded it.")


if __name__ == "__main__":
    unittest.main()
