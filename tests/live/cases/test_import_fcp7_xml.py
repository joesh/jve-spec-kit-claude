"""
FCP7 XML import (Part A — import + nudge + undo/redo) pins these
user-visible behaviors: picking File > Import > FCP7 XML... and
choosing a valid FCP7 XML file grows the project's sequence/clip
counts; pressing a nudge key on a selected post-import clip moves
that clip (and ``Cmd+Z`` restores the original position); ``Cmd+Z``
on the import itself removes the imported entities, and
``Cmd+Shift+Z`` restores them exactly (no duplicates, no leftovers).

Origin: ``tests/binding/test_import_fcp7_xml.lua`` (split per
MIGRATION_ANALYSIS.md — Part B is in
``test_import_fcp7_xml_part_b.py``).

Run:
    python3 -m unittest tests.live.cases.test_import_fcp7_xml -v
"""

import unittest
from pathlib import Path

from tests.live.runner.case import JVESmokeCase

FIXTURE = "tests/fixtures/resolve/sample_timeline_fcp7xml.xml"

class TestImportFCP7(JVESmokeCase):
    """Import + nudge + undo/redo on an FCP7 XML timeline."""

    def _seq_count(self) -> int:
        return self.eval_int(
            'return require("core.debug_helpers").sequence_count()')

    def _media_count(self) -> int:
        return self.eval_int(
            'return require("core.debug_helpers").media_count()')

    def test_01_import_grows_sequence_and_media_counts(self) -> None:
        repo_root = Path(__file__).resolve().parents[3]
        fixture_path = repo_root / FIXTURE
        self.assertTrue(fixture_path.exists(),
            f"fixture missing: {fixture_path}")

        seq_before = self._seq_count()
        media_before = self._media_count()

        self.menu_pick("File > Import > FCP7 XML...")
        self.pick_file_in_open_dialog(str(fixture_path))

        # Importer is async — wait until the new sequence(s) land.
        self.wait_for(
            f'return require("core.debug_helpers").sequence_count() > {seq_before}',
            timeout=30.0)

        # Remember the post-import counts on `self` so chained methods
        # can compare against them.
        TestImportFCP7._seq_after_import = self._seq_count()
        TestImportFCP7._media_after_import = self._media_count()

        self.assertGreater(TestImportFCP7._seq_after_import, seq_before,
            "Import should add sequences")
        self.assertGreaterEqual(TestImportFCP7._media_after_import, media_before,
            "Import should add or reuse media")

        # And the displayed sequence should now have clips on it — the
        # importer activates the imported timeline.
        displayed = self.eval_str(
            'return require("core.debug_helpers").displayed_sequence_id()')
        clips = self.eval_int(
            'return require("core.debug_helpers")'
            f'.clip_count_on_sequence("{displayed}")')
        self.assertGreater(clips, 0,
            "expected importer to populate the displayed sequence with clips")

    def test_02_nudge_moves_selected_clip_and_undo_restores(self) -> None:
        # Pick the first non-gap clip on the displayed (imported) sequence.
        info = self.eval(
            'local ts = require("ui.timeline.timeline_state"); '
            'for _, c in ipairs(ts.get_tab_strip():displayed_clips()) do '
            '  if not c.is_gap then '
            '    return string.format("%s|%d", c.id, c.sequence_start) '
            '  end '
            'end; '
            'error("no non-gap clip on displayed sequence — import did not populate it")')
        clip_id, start_str = info.strip('"').split('|', 1)
        start_before = int(start_str)

        self.click_clip(clip_id)
        self.assertEvalEqual(1,
            'return require("core.debug_helpers").selection_count()',
            msg=f"click_clip({clip_id}) did not result in a single selection")

        self.focus_panel("timeline")
        # `Period` is NudgeSelection direction=+1 magnitude=1 in
        # keymaps/default.jvekeys — clip moves +1 frame on the timeline.
        self.key("Period")

        start_after_nudge = self.eval_int(
            f'return require("core.debug_helpers")'
            f'.clip_field("{clip_id}", "sequence_start")')
        self.assertEqual(start_before + 1, start_after_nudge, (
            f"Period (nudge +1) on selected clip {clip_id} should advance "
            f"sequence_start by 1 (was {start_before}, expected "
            f"{start_before + 1}, got {start_after_nudge}). Keypress did "
            f"not reach the Nudge executor, or executor's mutation didn't "
            f"persist."))

        self.key("Cmd+Z")
        start_after_undo = self.eval_int(
            f'return require("core.debug_helpers")'
            f'.clip_field("{clip_id}", "sequence_start")')
        self.assertEqual(start_before, start_after_undo, (
            f"Cmd+Z after nudge should restore sequence_start to "
            f"{start_before}; got {start_after_undo}. The nudge command "
            f"undoer didn't reverse the mutation."))

    def test_03_undo_import_removes_imported_entities(self) -> None:
        # We're back at the import-only state after the prior method's
        # nudge-then-undo. One more Cmd+Z should undo the import itself.
        seq_before_undo = self._seq_count()
        self.assertEqual(seq_before_undo, TestImportFCP7._seq_after_import,
            "precondition: prior method should have left us at "
            "import-only state (nudge already undone)")

        self.key("Cmd+Z")
        self.wait_for(
            f'return require("core.debug_helpers").sequence_count() < {seq_before_undo}',
            timeout=10.0)

        seq_after_undo = self._seq_count()
        media_after_undo = self._media_count()
        self.assertLess(seq_after_undo, TestImportFCP7._seq_after_import,
            "Cmd+Z on import should remove imported sequences")
        self.assertLessEqual(media_after_undo, TestImportFCP7._media_after_import,
            "Cmd+Z on import should not increase media count")

        TestImportFCP7._seq_after_undo = seq_after_undo
        TestImportFCP7._media_after_undo = media_after_undo

    def test_04_redo_import_restores_exact_counts(self) -> None:
        self.key("Cmd+Shift+Z")
        self.wait_for(
            f'return require("core.debug_helpers").sequence_count() > '
            f'{TestImportFCP7._seq_after_undo}',
            timeout=30.0)

        seq_after_redo = self._seq_count()
        media_after_redo = self._media_count()
        self.assertEqual(TestImportFCP7._seq_after_import, seq_after_redo, (
            f"Redo should reproduce sequence count exactly: expected "
            f"{TestImportFCP7._seq_after_import}, got {seq_after_redo}. "
            f"Redo is leaking duplicates or missing rows."))
        self.assertEqual(TestImportFCP7._media_after_import, media_after_redo, (
            f"Redo should reproduce media count exactly: expected "
            f"{TestImportFCP7._media_after_import}, got {media_after_redo}."))

if __name__ == "__main__":
    unittest.main()
