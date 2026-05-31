"""
Undoing an FCP7 XML import removes the imported timeline AND its media —
no empty-shell sequence may be left behind in the host project.

Origin: tests/binding/test_import_undo_removes_sequence.lua (Lua/DB-driven
binding test). The smoke replacement drives the real File > Import menu
on the anamnesis-derived template (which IS the host project) and
inspects via core.debug_helpers; undo is driven by Cmd+Z.

Run:
    python3 -m unittest tests.smoke.cases.test_import_undo_removes_sequence -v
"""

import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT))

from tests.smoke.runner.case import JVESmokeCase

FIXTURE = REPO_ROOT / "tests" / "fixtures" / "resolve" / "sample_timeline_fcp7xml.xml"


class TestImportUndoRemovesSequence(JVESmokeCase):
    """Import an FCP7 XML into the host project, then undo. Methods chain."""

    def test_01_import_creates_sequence_and_media(self) -> None:
        self.assertTrue(FIXTURE.exists(), f"fixture missing: {FIXTURE}")

        host_project = self.eval_str(
            'return tostring(require("core.debug_helpers").active_project_id())')
        self.assertTrue(host_project and host_project != "nil",
            "setUp: anamnesis template did not open a host project")

        seq_before = self.eval_int(
            'return require("core.debug_helpers").sequence_count()')
        media_before = self.eval_int(
            'return require("core.debug_helpers").media_count()')

        # Stash for the undo method.
        type(self)._host_project = host_project
        type(self)._seq_before = seq_before
        type(self)._media_before = media_before

        # Drive the real menu → open dialog → file pick.
        self.menu_pick("File > Import > FCP7 XML...")
        self.pick_file_in_open_dialog(str(FIXTURE))

        # Importer is async; wait on the observable post-condition.
        self.wait_for(
            f'return require("core.debug_helpers").sequence_count() > {seq_before}',
            timeout=15.0)

        seq_after = self.eval_int(
            'return require("core.debug_helpers").sequence_count()')
        self.assertGreater(seq_after, seq_before,
            "Import should create an additional timeline sequence")
        type(self)._seq_after = seq_after

        media_after = self.eval_int(
            'return require("core.debug_helpers").media_count()')
        self.assertGreater(media_after, media_before,
            "Import should bring in at least one media row "
            "(no media after import means the undo-removes-media "
            "check below would be vacuous)")
        type(self)._media_after = media_after

    def test_02_undo_removes_imported_sequence_and_media(self) -> None:
        # Inherits state from test_01.
        host_project = type(self)._host_project
        seq_before = type(self)._seq_before
        media_before = type(self)._media_before

        self.focus_panel("timeline")
        self.key("Cmd+Z")

        # Undo runs async-ish; wait on the observable post-condition.
        self.wait_for(
            f'return require("core.debug_helpers").sequence_count() == {seq_before}',
            timeout=10.0)

        host_after_undo = self.eval_str(
            'return tostring(require("core.debug_helpers").active_project_id())')
        self.assertEqual(host_project, host_after_undo,
            "host project survives undo — undo of an FCP7 import must "
            "NOT delete the project the user was working in")

        seq_after_undo = self.eval_int(
            'return require("core.debug_helpers").sequence_count()')
        self.assertEqual(seq_before, seq_after_undo,
            "Undo should remove the imported timeline sequence")

        media_after_undo = self.eval_int(
            'return require("core.debug_helpers").media_count()')
        self.assertEqual(media_before, media_after_undo,
            "Imported media should be removed after undo")


if __name__ == "__main__":
    unittest.main()
