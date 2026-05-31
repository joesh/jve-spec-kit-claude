"""
Pins two user-visible behaviors on a freshly imported FCP7 timeline:
(1) the importer produces a structurally sound timeline — track indices
per type are contiguous from 1, and clips on the same track do not
overlap; (2) ripple-trimming a clip's tail (Cmd+Shift+]) at a playhead
inside the clip shrinks that clip and shifts the next downstream clip
on the same track left by the exact amount the trimmed clip shrank
(length identity across the ripple).

Origin: tests/binding/test_imported_ripple.lua (see
tests/smoke/MIGRATION_ANALYSIS.md — Group B, smoke rewrite).

Run:
    python3 -m unittest tests.smoke.cases.test_imported_sequence_ripple -v
"""

import unittest
from pathlib import Path

from tests.smoke.runner.case import JVESmokeCase

FIXTURE = "tests/fixtures/resolve/sample_timeline_fcp7xml.xml"

# Park the playhead this many frames into the target clip before
# Cmd+Shift+] so TrimTail has a meaningful tail to drop. Must be small
# enough to leave a head, large enough to produce a visible downstream
# shift (and >1 even after seek/snap rounding).
SEED_OFFSET_INTO_CLIP = 24

class TestImportedSequenceRipple(JVESmokeCase):
    """Import an FCP7 timeline, then ripple-trim a clip; downstream shifts."""

    # ---------- helpers ----------

    def _seq_count(self) -> int:
        return self.eval_int(
            'return require("core.debug_helpers").sequence_count()')

    def _displayed_seq(self) -> str:
        return self.eval_str(
            'return require("core.debug_helpers").displayed_sequence_id()')

    def _rec_seq(self) -> str:
        sid = self.eval_str(
            "local sid = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(type(sid) == 'string' and sid ~= '', "
            "       'record engine has no loaded sequence after import'); "
            "return sid")
        return sid

    def _clip_geometry(self, clip_id: str) -> tuple[int, int, int, int]:
        """Returns (sequence_start, source_in, source_out, duration) for a clip."""
        s = self.eval(
            f"local c = require('models.clip').load('{clip_id}'); "
            f"assert(c, 'clip not found: {clip_id}'); "
            "return string.format('%d|%d|%d|%d', "
            "  c.sequence_start, c.source_in, c.source_out, c.duration)")
        parts = s.strip('"').split("|", 3)
        return int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3])

    # ---------- methods (ordered) ----------

    def test_01_import_fcp7_produces_structurally_sound_timeline(self) -> None:
        repo_root = Path(__file__).resolve().parents[3]
        fixture_path = repo_root / FIXTURE
        self.assertTrue(fixture_path.exists(),
            f"fixture missing: {fixture_path}")

        seq_before = self._seq_count()

        self.menu_pick("File > Import > FCP7 XML...")
        self.pick_file_in_open_dialog(str(fixture_path))

        self.wait_for(
            f'return require("core.debug_helpers").sequence_count() > {seq_before}',
            timeout=30.0)

        seq_id = self._displayed_seq()
        self.assertTrue(seq_id and seq_id != "",
            "importer should activate the imported sequence on the displayed tab")

        # Structural invariants — straight from the source Lua test:
        # 1) track indices per type are contiguous starting at 1
        # 2) all clips' owner_sequence_id matches the imported sequence
        # 3) clips on the same track do not overlap (sorted by start)
        # Helper packs all three checks into one Lua eval so the smoke
        # sees a single domain-level pass/fail with a precise message.
        report = self.eval(
            "local Track = require('models.track'); "
            "local Clip = require('models.clip'); "
            f"local seq_id = '{seq_id}'; "
            "local tracks = Track.find_by_sequence(seq_id); "
            "assert(#tracks > 0, 'Importer created no tracks'); "
            "local by_type = {}; "
            "for _, t in ipairs(tracks) do "
            "  assert(t.track_index >= 1, "
            "    string.format('Track %s has invalid index %d', "
            "                  tostring(t.id), t.track_index)); "
            "  by_type[t.track_type] = by_type[t.track_type] or {}; "
            "  table.insert(by_type[t.track_type], t.track_index); "
            "end; "
            "for ttype, indices in pairs(by_type) do "
            "  table.sort(indices); "
            "  for expected, actual in ipairs(indices) do "
            "    assert(actual == expected, string.format("
            "      'Track indices for %s not contiguous (expected %d, got %d)', "
            "      ttype, expected, actual)); "
            "  end; "
            "end; "
            "local clips = Clip.list_in_sequence(seq_id); "
            "local by_track = {}; "
            "for _, c in ipairs(clips) do "
            "  assert(c.sequence_id == seq_id, string.format("
            "    'Clip %s references sequence %s (expected %s)', "
            "    tostring(c.id), tostring(c.sequence_id), seq_id)); "
            "  by_track[c.track_id] = by_track[c.track_id] or {}; "
            "  table.insert(by_track[c.track_id], c); "
            "end; "
            "for tid, list in pairs(by_track) do "
            "  table.sort(list, function(a,b) return a.sequence_start < b.sequence_start end); "
            "  local prev_end, prev_id; "
            "  for _, c in ipairs(list) do "
            "    if prev_end then "
            "      assert(c.sequence_start >= prev_end, string.format("
            "        'Track %s overlaps: clip %s starts at %d before prev end %d (prev %s)', "
            "        tostring(tid), tostring(c.id), c.sequence_start, prev_end, tostring(prev_id))); "
            "    end; "
            "    prev_end = c.sequence_start + c.duration; prev_id = c.id; "
            "  end; "
            "end; "
            "return string.format('tracks=%d clips=%d', #tracks, #clips)")
        # Stash for chained methods.
        TestImportedSequenceRipple._import_report = report

    def test_02_ripple_trim_tail_shifts_downstream_clip_left_by_same_delta(self) -> None:
        seq_id = self._displayed_seq()
        self.assertTrue(seq_id and seq_id != "",
            "precondition: prior method should have left the imported "
            "sequence displayed")

        # Find a target video clip with a downstream neighbor on the same
        # armed/unlocked video track, and enough body to allow a ~20-frame
        # tail trim. Returns target + downstream identity + geometry.
        info = self.eval(
            "local Track = require('models.track'); "
            "local Clip = require('models.clip'); "
            f"local seq_id = '{seq_id}'; "
            "local video_tracks = {}; "
            "for _, t in ipairs(Track.find_by_sequence(seq_id)) do "
            "  if t.track_type == 'VIDEO' and t.autoselect and not t.locked then "
            "    video_tracks[t.id] = true "
            "  end "
            "end; "
            "local by_track = {}; "
            "for _, c in ipairs(Clip.list_in_sequence(seq_id)) do "
            "  if video_tracks[c.track_id] then "
            "    by_track[c.track_id] = by_track[c.track_id] or {}; "
            "    table.insert(by_track[c.track_id], c); "
            "  end; "
            "end; "
            "for _, list in pairs(by_track) do "
            "  table.sort(list, function(a,b) return a.sequence_start < b.sequence_start end); "
            "  for i = 1, #list - 1 do "
            "    local t, d = list[i], list[i+1]; "
            "    if t.duration > 48 then "
            "      return string.format('%s|%s|%d|%d|%s|%d', "
            "        t.id, t.track_id, t.sequence_start, t.duration, "
            "        d.id, d.sequence_start); "
            "    end; "
            "  end; "
            "end; "
            "error('no armed video track with target+downstream clip pair found')")
        parts = info.strip('"').split("|", 5)
        target_id = parts[0]
        target_seq_start = int(parts[2])
        target_duration_before = int(parts[3])
        downstream_id = parts[4]
        downstream_seq_start_before = int(parts[5])

        # Select target via real click (canonical selection path).
        self.click_clip(target_id)
        self.assertEvalEqual(1,
            'return require("core.debug_helpers").selection_count()',
            msg=(f"click_clip({target_id}) did not result in a single "
                 f"selection — selection precondition for TrimTail broken."))

        # Park the playhead inside the clip so Cmd+Shift+] has a tail to drop.
        target_frame = target_seq_start + SEED_OFFSET_INTO_CLIP
        self.move_playhead_to(target_frame)

        self.focus_panel("timeline")
        self.assertEvalEqual("timeline",
            'return require("ui.focus_manager").get_focused_panel()',
            msg="focus did not anchor on timeline before Cmd+Shift+] press")

        # TrimTail = ripple trim of the tail to the playhead; downstream
        # clips on the same track shift left to close the gap.
        self.key("Cmd+Shift+BracketRight")

        # Domain assertions — describe what the user sees, derive
        # expected from the geometry observed before the press.
        _, _, _, target_duration_after = self._clip_geometry(target_id)
        downstream_seq_start_after, _, _, _ = self._clip_geometry(downstream_id)

        delta_applied = target_duration_after - target_duration_before
        self.assertLess(delta_applied, 0, (
            f"Ripple-trim (Cmd+Shift+]) on target {target_id} should "
            f"shorten the clip. duration before={target_duration_before}, "
            f"after={target_duration_after}, delta={delta_applied}. "
            f"If 0, the keypress didn't reach TrimTail. If positive, "
            f"the executor is growing the clip instead of trimming."))

        expected_downstream_start = downstream_seq_start_before + delta_applied
        self.assertEqual(expected_downstream_start, downstream_seq_start_after, (
            f"Ripple should shift downstream clip {downstream_id} left "
            f"by exactly the trim delta. expected sequence_start="
            f"{expected_downstream_start} (was "
            f"{downstream_seq_start_before}, delta {delta_applied}); got "
            f"{downstream_seq_start_after}. Length identity broken — "
            f"the ripple didn't propagate, or it propagated by a "
            f"different amount than the clip shrank."))

if __name__ == "__main__":
    unittest.main()
