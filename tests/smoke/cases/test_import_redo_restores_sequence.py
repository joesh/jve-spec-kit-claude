"""
Redo after undoing an FCP7 XML import restores the imported sequence,
its tracks, and its clips — even though the timeline stack pointed at
the now-deleted imported sequence ID when the undo ran.

Pins the same domain behavior as the now-replaced
``tests/binding/test_import_redo_restores_sequence.lua``: import FCP7
XML, switch to the imported sequence's tab, toggle a clip's enabled
flag (D), Cmd+Z twice (undo toggle, undo import), Cmd+Shift+Z (redo
import) — sequence / track / clip counts must match the post-import
baseline, with no stranded redo stack from the deleted-sequence focus.

TODO: needs ``debug_helpers.track_count()`` and
``debug_helpers.last_imported_sequence_id()`` (or equivalent) plus a
``click_tab_for_sequence(seq_id)`` primitive — see MIGRATION_ANALYSIS.md
entry for ``tests/binding/test_import_redo_restores_sequence.lua``.
The legacy Lua test counted ``sequences``/``tracks``/``clips`` directly
in the DB and called ``activate_timeline_stack(imported_sequence_id)``
to simulate the UI focusing the imported tab. Smokes go through real
input + ``core.debug_helpers``; no tab-strip click primitive or
track-row count helper exists yet.

Run:
    python3 -m unittest tests.smoke.cases.test_import_redo_restores_sequence -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


FIXTURE = "tests/fixtures/resolve/sample_timeline_fcp7xml.xml"


class TestImportRedoRestoresSequence(JVESmokeCase):
    """Redo after import-undo recreates sequence/tracks/clips even when
    the timeline stack points at the deleted imported sequence ID."""

    @unittest.skip(
        "needs debug_helpers.track_count + click_tab_for_sequence primitive "
        "+ last_imported_sequence_id query — see MIGRATION_ANALYSIS.md "
        "entry for test_import_redo_restores_sequence.lua")
    def test_redo_after_import_undo_restores_sequence_state(self) -> None:
        repo_root = Path(__file__).resolve().parents[3]
        fixture_path = repo_root / FIXTURE
        self.assertTrue(fixture_path.exists(),
            f"fixture missing: {fixture_path}")

        # ---- 1. Pre-import baseline ----
        seq_before = self.eval_int(
            'return require("core.debug_helpers").sequence_count()')
        tracks_before = self.eval_int(
            'return require("core.debug_helpers").track_count()')
        clips_before = self.eval_int(
            'return require("core.debug_helpers")'
            '.sequence_clip_count_total()')

        # ---- 2. Import FCP7 XML via the real menu + file dialog ----
        self.menu_pick("File > Import > FCP7 XML...")
        self.pick_file_in_open_dialog(str(fixture_path))

        # Importer is async — wait until at least one new sequence lands.
        self.wait_for(
            'return require("core.debug_helpers").sequence_count() > '
            f'{seq_before}',
            timeout=30.0)

        # Snapshot the post-import baseline. These are what redo must
        # restore after the round-trip.
        baseline_sequences = self.eval_int(
            'return require("core.debug_helpers").sequence_count()')
        baseline_tracks = self.eval_int(
            'return require("core.debug_helpers").track_count()')
        baseline_clips = self.eval_int(
            'return require("core.debug_helpers")'
            '.sequence_clip_count_total()')

        self.assertGreater(baseline_sequences, seq_before,
            "FCP7 import did not add any sequence")
        self.assertGreater(baseline_tracks, tracks_before,
            "FCP7 import did not add any tracks")
        self.assertGreater(baseline_clips, clips_before,
            "FCP7 import did not add any clips")

        imported_seq_id = self.eval_str(
            'return require("core.debug_helpers")'
            '.last_imported_sequence_id()')
        self.assertNotEqual("", imported_seq_id,
            "could not identify imported sequence id")

        # ---- 3. Focus the imported sequence's tab (real click) ----
        self.click_tab_for_sequence(imported_seq_id)
        self.assertEvalEqual(imported_seq_id,
            'return require("core.debug_helpers")'
            '.displayed_sequence_id()',
            msg="tab click did not focus the imported sequence")

        # ---- 4. Select first clip on the imported sequence + press D ----
        first_clip_id = self.eval_str(
            "local clips = require('ui.timeline.timeline_state')"
            ":get_tab_strip():displayed_clips(); "
            "for _, c in ipairs(clips) do "
            "  if not c.is_gap then return c.id end "
            "end; "
            "error('imported sequence has no non-gap clip')")
        self.click_clip(first_clip_id)
        self.focus_panel("timeline")
        self.key("D")

        # ---- 5. Cmd+Z twice — undo toggle, undo import ----
        self.key("Cmd+Z")  # undo ToggleClipEnabled
        self.key("Cmd+Z")  # undo ImportFCP7XML
        self.wait_for(
            'return require("core.debug_helpers").sequence_count() == '
            f'{seq_before}',
            timeout=10.0)

        after_undo_sequences = self.eval_int(
            'return require("core.debug_helpers").sequence_count()')
        after_undo_tracks = self.eval_int(
            'return require("core.debug_helpers").track_count()')
        after_undo_clips = self.eval_int(
            'return require("core.debug_helpers")'
            '.sequence_clip_count_total()')
        self.assertEqual(seq_before, after_undo_sequences,
            "Undo should remove imported sequence")
        self.assertEqual(tracks_before, after_undo_tracks,
            "Undo should remove imported tracks")
        self.assertEqual(clips_before, after_undo_clips,
            "Undo should remove imported clips")

        # ---- 6. Cmd+Shift+Z — redo import ----
        # The UI stack still points at the (now-deleted) imported
        # sequence ID; the bug-under-test is that redo strands when the
        # focused stack target is gone. After redo, counts must match
        # the post-import baseline.
        self.key("Cmd+Shift+Z")
        self.wait_for(
            'return require("core.debug_helpers").sequence_count() == '
            f'{baseline_sequences}',
            timeout=10.0)

        after_redo_sequences = self.eval_int(
            'return require("core.debug_helpers").sequence_count()')
        after_redo_tracks = self.eval_int(
            'return require("core.debug_helpers").track_count()')
        after_redo_clips = self.eval_int(
            'return require("core.debug_helpers")'
            '.sequence_clip_count_total()')

        self.assertEqual(baseline_sequences, after_redo_sequences, (
            f"Redo should restore sequence count "
            f"({after_redo_sequences} vs {baseline_sequences})"))
        self.assertEqual(baseline_tracks, after_redo_tracks, (
            f"Redo should restore track count "
            f"({after_redo_tracks} vs {baseline_tracks})"))
        self.assertEqual(baseline_clips, after_redo_clips, (
            f"Redo should restore clip count "
            f"({after_redo_clips} vs {baseline_clips})"))


if __name__ == "__main__":
    unittest.main()
