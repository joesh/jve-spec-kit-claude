"""
ImportResolveTimeline merges a .drt into the CURRENT project — pins
the verb semantic that distinguishes it from ImportResolveProject:
no new project is created, imported sequences attach to the host
project, undo removes them while preserving the host, redo restores.

Origin: tests/binding/test_import_resolve_timeline.lua (Lua/DB-driven
binding test). Smoke replacement drives the real File > Import menu
on the anamnesis-derived template (which IS the host project) and
inspects via core.debug_helpers.

Fixture: tests/fixtures/resolve/retime-test.drt — shared with other
DRT-import smokes per MIGRATION_ANALYSIS grouping note.

Run:
    python3 -m unittest tests.smoke.cases.test_import_resolve_timeline -v
"""

import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
from tests.smoke.runner.case import JVESmokeCase

FIXTURE = REPO_ROOT / "tests" / "fixtures" / "resolve" / "retime-test.drt"

class TestImportResolveTimelineMergesIntoHostProject(JVESmokeCase):
    """One session: import DRT into host, undo, redo. Methods chain."""

    def test_01_import_attaches_sequences_to_host_project(self) -> None:
        host_project = self.eval_str(
            'return tostring(require("core.debug_helpers").active_project_id())')
        self.assertTrue(host_project and host_project != "nil",
            "setUp: anamnesis template did not open a host project")

        seq_before = self.eval_int(
            'return require("core.debug_helpers").sequence_count()')
        self.assertGreater(seq_before, 0,
            "setUp: host project should already carry at least one sequence")

        # Stash for later methods (shared state).
        type(self)._host_project = host_project
        type(self)._seq_before = seq_before
        type(self)._media_before = self.eval_int(
            'return require("core.debug_helpers").media_count()')

        # Drive the real menu → open dialog → file pick.
        self.menu_pick("File > Import > Resolve Timeline (.drt)...")
        self.pick_file_in_open_dialog(str(FIXTURE))

        # Import runs async; wait on the observable post-condition.
        self.wait_for(
            f'return require("core.debug_helpers").sequence_count() > {seq_before}',
            timeout=15.0)

        # Invariant 1: host project still the active project (DRT is a
        # merge — it must NOT have created or switched to a new project).
        host_after = self.eval_str(
            'return tostring(require("core.debug_helpers").active_project_id())')
        self.assertEqual(host_project, host_after,
            "no new project created by import — active project must remain the host")

        # Invariant 2: at least one new sequence attached.
        seq_after = self.eval_int(
            'return require("core.debug_helpers").sequence_count()')
        self.assertGreater(seq_after, seq_before,
            "imported sequences attached to host project")
        type(self)._seq_after = seq_after

        # Invariant 3: imported sequence(s) carry tracks + clips. Pick
        # one of the newly created sequences and assert non-empty.
        new_seq_id = self.eval_str(
            "local debug_h = require('core.debug_helpers'); "
            "local host = tostring(debug_h.active_project_id()); "
            "local Sequence = require('models.sequence'); "
            "for _, s in ipairs(Sequence.list_in_project(host)) do "
            "  local n = debug_h.sequence_clip_count(s.id); "
            "  if n and n > 0 then return s.id end "
            "end; "
            "error('no imported sequence with clips found in host project')")
        self.assertTrue(new_seq_id and new_seq_id != "nil",
            "imported clips exist on at least one new sequence")

    def test_02_undo_removes_imports_but_preserves_host(self) -> None:
        # Inherits state from test_01.
        host_project = type(self)._host_project
        seq_before = type(self)._seq_before

        self.focus_panel("timeline")
        self.key("Cmd+Z")

        # Undo runs async-ish; wait on the observable post-condition.
        self.wait_for(
            f'return require("core.debug_helpers").sequence_count() == {seq_before}',
            timeout=10.0)

        host_after_undo = self.eval_str(
            'return tostring(require("core.debug_helpers").active_project_id())')
        self.assertEqual(host_project, host_after_undo,
            "host project survives undo — undo of a DRT merge must NOT "
            "delete the project the user was working in")

        seq_after_undo = self.eval_int(
            'return require("core.debug_helpers").sequence_count()')
        self.assertEqual(seq_before, seq_after_undo,
            "imported sequences removed on undo")

    def test_03_redo_restores_imported_sequences(self) -> None:
        seq_after = type(self)._seq_after

        self.key("Cmd+Shift+Z")
        self.wait_for(
            f'return require("core.debug_helpers").sequence_count() == {seq_after}',
            timeout=15.0)

        seq_after_redo = self.eval_int(
            'return require("core.debug_helpers").sequence_count()')
        self.assertEqual(seq_after, seq_after_redo,
            "redo restores imported sequences")

if __name__ == "__main__":
    unittest.main()
