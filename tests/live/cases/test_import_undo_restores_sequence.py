"""
FCP7 XML import — undo restores the pre-import active sequence. Regression
target: undo deletes the imported sequence row but historically left the
timeline tab-strip's ``active_sequence_id`` pointing at the now-deleted id,
leaving the UI with a stale focus pointer (and crashing the next reload).

User-visible behavior pinned: after importing a FCP7 XML (which auto-
activates the imported sequence), pressing Cmd+Z removes the import AND
swings the active sequence pointer back to whatever was active before the
import. The active pointer must never reference a deleted sequence.

Origin: tests/binding/test_import_undo_restores_sequence.lua.

Run:
    python3 -m unittest tests.live.cases.test_import_undo_restores_sequence -v
"""

import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
from tests.live.runner.case import JVESmokeCase

FIXTURE = REPO_ROOT / "tests" / "fixtures" / "resolve" / "sample_timeline_fcp7xml.xml"

class TestImportUndoRestoresActiveSequence(JVESmokeCase):
    """Import FCP7 → undo → active sequence is the pre-import one."""

    def test_01_import_then_undo_restores_pre_import_active_sequence(self) -> None:
        self.assertTrue(FIXTURE.exists(), f"fixture missing: {FIXTURE}")

        active_before = self.eval_str(
            'return tostring(require("core.debug_helpers").active_sequence_id())')
        self.assertTrue(active_before and active_before != "nil",
            "setUp: template should already have an active sequence before import")

        seq_count_before = self.eval_int(
            'return require("core.debug_helpers").sequence_count()')

        # Drive the real menu + file picker.
        self.menu_pick("File > Import > FCP7 XML...")
        self.pick_file_in_open_dialog(str(FIXTURE))

        # Importer is async — wait until the new sequence(s) land AND the
        # importer has switched the active sequence to one of the newly
        # created ones (its documented post-import behavior).
        self.wait_for(
            f'return require("core.debug_helpers").sequence_count() > {seq_count_before}',
            timeout=30.0)
        self.wait_for(
            'return tostring(require("core.debug_helpers").active_sequence_id()) ~= '
            f'{active_before!r}',
            timeout=10.0)

        imported_active = self.eval_str(
            'return tostring(require("core.debug_helpers").active_sequence_id())')
        self.assertNotEqual(active_before, imported_active,
            "precondition: importer should activate the newly imported sequence, "
            "leaving the active pointer != pre-import active id")

        # Undo the import.
        self.focus_panel("timeline")
        self.key("Cmd+Z")

        # Wait until the imported sequence is gone (undo is async-ish).
        self.wait_for(
            f'return require("core.debug_helpers").sequence_count() == {seq_count_before}',
            timeout=10.0)

        # KEY ASSERTION 1: active sequence pointer must NOT still reference
        # the now-deleted imported sequence.
        active_after = self.eval_str(
            'return tostring(require("core.debug_helpers").active_sequence_id())')
        self.assertNotEqual(imported_active, active_after, (
            f"BUG: after undo, active sequence still points at deleted "
            f"imported sequence {imported_active}. Undo removed the row but "
            f"left the tab-strip's active pointer dangling — next reload "
            f"will reference a sequence that no longer exists."))

        # KEY ASSERTION 2: it should be back on the pre-import sequence.
        self.assertEqual(active_before, active_after, (
            f"Expected pre-import active sequence {active_before} after "
            f"undo, got {active_after}. Undo must restore the user's prior "
            f"editing context, not leave them on some arbitrary other tab."))

if __name__ == "__main__":
    unittest.main()
