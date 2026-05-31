"""
ImportResolveProject refuses to overwrite a non-empty .jvp.

Pins the architectural gate: the ImportResolveProject command is
reserved for the genuinely-empty-DB case. First-open of a .drp goes
through OpenProject's convert path; once a project already exists in
the .jvp, the importer must refuse rather than clobber. Origin:
tests/binding/test_import_resolve_drp.lua (parse-tier coverage stays
in the _convert_drp_to_jvp binding tests; this smoke pins the
command-layer refusal contract only).

# TODO: needs pick_file_in_open_dialog (QFileDialog driver) — see
#       SMOKE_TEST_AUTHORING.md "File / menu dialog driving" +
#       MIGRATION_ANALYSIS.md entry for test_import_resolve_drp.lua.
# TODO: needs core.debug_helpers.last_command_error() to read the
#       command_manager refusal message without touching internals.
"""

import unittest

from tests.smoke.runner.case import JVESmokeCase

class TestImportResolveDRPRefusal(JVESmokeCase):
    """File>Import>Resolve Project against a populated .jvp must refuse."""

    @unittest.skip("needs pick_file_in_open_dialog + last_command_error primitives")
    def test_import_resolve_project_refuses_on_non_empty_jvp(self) -> None:
        # Anamnesis template is already a non-empty .jvp at class setUp
        # — exactly the precondition the refusal contract guards.
        before_projects = self.eval_int(
            'return require("core.debug_helpers").project_count()')
        before_sequences = self.eval_int(
            'return require("core.debug_helpers").sequence_count()')

        # Drive the menu + file picker via real OS input.
        self.menu_pick("File > Import > Resolve Project (.drp)...")
        self.pick_file_in_open_dialog(
            "tests/fixtures/resolve/sample_project.drp")

        # The importer surfaces the refusal as an error toast/dialog and
        # leaves last_command_error set; wait for either to settle.
        self.wait_for(
            'return (require("core.debug_helpers").last_command_error() or "")'
            ':find("refuses to import into a non-empty .jvp", 1, true) ~= nil',
            timeout=10.0)

        err = self.eval_str(
            'return require("core.debug_helpers").last_command_error() or ""')
        self.assertIn("refuses to import into a non-empty .jvp", err,
            "error message names the refusal")

        # Nothing was overwritten.
        self.assertEqual(before_projects, self.eval_int(
            'return require("core.debug_helpers").project_count()'),
            "project count unchanged after refusal")
        self.assertEqual(before_sequences, self.eval_int(
            'return require("core.debug_helpers").sequence_count()'),
            "sequence count unchanged after refusal")

if __name__ == "__main__":
    unittest.main()
