"""
Importing an FCP7 XML must reuse an existing media row when the
referenced file_path already has one — no duplicate media row, and
undoing the import must not delete the pre-existing media.

Origin: tests/binding/test_import_reuses_existing_media_by_path.lua
(domain behavior: importer dedupes media by file_path; undo doesn't
orphan pre-existing rows).

# TODO: needs media_id_for_path() debug helper — see MIGRATION_ANALYSIS.md
# TODO: needs pre-seed Media via File > Import > Media menu path through
#       pick_file_in_open_dialog (not yet exercised in any smoke).
# TODO: confirm anamnesis template does NOT already contain the FCP7
#       fixture's referenced media paths; otherwise pre-seed step is moot.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestImportReusesExistingMedia(JVESmokeCase):
    """FCP7 import dedupes media by file_path; undo preserves pre-existing."""

    @unittest.skip("needs media_id_for_path() debug helper + Import Media menu "
                   "primitive — see MIGRATION_ANALYSIS.md entry for "
                   "test_import_reuses_existing_media_by_path.lua")
    def test_fcp7_import_reuses_pre_seeded_media_and_undo_preserves_it(self) -> None:
        pass
        # ---- 1. Pre-seed: pick a media file path that the FCP7 fixture
        #        references, then import it via File > Import > Media.
        # fixture_xml = "tests/fixtures/resolve/sample_timeline_fcp7xml.xml"
        # media_path  = <one path from inside that XML>
        #
        # self.menu_pick("File > Import > Media...")
        # self.pick_file_in_open_dialog(media_path)
        # self.wait_for("return require('core.debug_helpers')"
        #               ".media_id_for_path('" + media_path + "') ~= nil",
        #               timeout=10.0)
        # pre_id = self.eval_str(
        #     "return require('core.debug_helpers')"
        #     ".media_id_for_path('" + media_path + "')")
        # self.assertTrue(pre_id, "pre-seed: ImportMedia did not create row")

        # ---- 2. Import the FCP7 XML that references the same path.
        # self.menu_pick("File > Import > Final Cut Pro 7 XML...")
        # self.pick_file_in_open_dialog(fixture_xml)
        # self.wait_for("return require('core.debug_helpers')"
        #               ".sequence_count() >= 2", timeout=20.0)

        # ---- 3. Domain assertion: the importer reused the pre-existing
        #        row (no duplicate media created for that path).
        # post_id = self.eval_str(
        #     "return require('core.debug_helpers')"
        #     ".media_id_for_path('" + media_path + "')")
        # self.assertEqual(pre_id, post_id, (
        #     "Importer created a duplicate media row instead of reusing "
        #     "the existing one keyed by file_path. The dedupe-by-path "
        #     "path is broken."))
        # rows_for_path = self.eval_int(
        #     "return require('core.debug_helpers')"
        #     ".media_count_for_path('" + media_path + "')")
        # self.assertEqual(1, rows_for_path,
        #     "more than one media row for the same file_path after import")

        # ---- 4. Undo the import; the pre-existing media row must survive.
        # self.focus_panel("timeline")
        # self.key("Cmd+Z")
        # self.wait_for("return require('core.debug_helpers')"
        #               ".media_id_for_path('" + media_path + "') ~= nil",
        #               timeout=5.0)
        # surviving = self.eval_str(
        #     "return require('core.debug_helpers')"
        #     ".media_id_for_path('" + media_path + "')")
        # self.assertEqual(pre_id, surviving,
        #     "Undo import must not delete pre-existing media rows that "
        #     "the import merely referenced.")


if __name__ == "__main__":
    unittest.main()
