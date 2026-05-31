"""
Browser activation routes view + focus atomically and is non-undoable.

Migrated from tests/integration/test_browser_activation_routes_through_commands.lua.
Pins three domain behaviors observable via the project_browser:

  1. Right-clicking a master in the project_browser and picking "Open in
     Source" loads that master into the source viewer.
  2. Double-clicking a sequence in the project_browser routes that
     sequence into the timeline AND shifts keyboard focus to the
     timeline panel — atomically (view + focus together).
  3. Both activations are non-undoable: Cmd+Z does NOT revert the
     source-viewer load or the timeline switch.

# TODO: needs project_browser row interaction primitives
#   - double_click_browser_row(sequence_id)  → opens sequence in timeline
#   - right_click_browser_row(master_id) + context-menu "Open in Source"
#   See MIGRATION_ANALYSIS.md entry for
#   test_browser_activation_routes_through_commands.lua: "needs browser
#   interaction primitives (double-click row in browser)."
"""

import unittest

from tests.smoke.runner.case import JVESmokeCase

class TestBrowserActivationRoutes(JVESmokeCase):
    """Browser row activation atomically switches view + focus; non-undoable."""

    @unittest.skip("needs project_browser row double-click / right-click primitives")
    def test_browser_activation_routes_view_and_focus(self) -> None:
        # Step 1: right-click a master in the browser → "Open in Source"
        #   self.right_click_browser_row(master_id)
        #   self.menu_pick("Open in Source")
        # Assert source viewer holds the master:
        #   self.assertEvalEqual(master_id,
        #       'return require("core.debug_helpers").source_viewer_sequence_id()',
        #       msg="source monitor must show the master after browser activation")
        #
        # Step 2: double-click a different sequence in the browser
        #   self.double_click_browser_row(other_seq_id)
        # Assert timeline switched AND focus moved to timeline panel:
        #   self.assertEvalEqual(other_seq_id,
        #       'return require("core.debug_helpers").displayed_sequence_id()',
        #       msg="timeline_state must target the activated sequence")
        #   self.assertEvalEqual("timeline",
        #       'return require("core.debug_helpers").focused_panel()',
        #       msg="browser activation must atomically focus timeline panel")
        #
        # Step 3: non-undoable — Cmd+Z must NOT revert
        #   before = self.eval_str(
        #       'return require("core.debug_helpers").displayed_sequence_id()')
        #   self.key("Cmd+Z")
        #   after = self.eval_str(
        #       'return require("core.debug_helpers").displayed_sequence_id()')
        #   self.assertEqual(before, after,
        #       "browser activation must be non-undoable; view must survive Cmd+Z")
        raise AssertionError("unreachable — skipped")

if __name__ == "__main__":
    unittest.main()
