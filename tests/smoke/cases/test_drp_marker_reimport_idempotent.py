"""
Re-importing the same DRP into one project must NOT accumulate duplicate
markers. Pins per-UUID marker dedup: count on a marker-bearing clip is
stable across a second import of the same source file.

Origin: tests/binding/test_drp_marker_reimport_idempotent.lua. Migration
notes say chain after test_drp_marker_import in a shared TestDRPMarkers
class.

TODO: needs clip_marker_count_for_clip / clip_marker_count_on_sequence
      query in core.debug_helpers — see MIGRATION_ANALYSIS.md
      (Group A, test_drp_marker_reimport_idempotent.lua). The
      importer-driving primitives (menu_pick + pick_file_in_open_dialog
      + wait_for) are listed in PRIMITIVES.md, but there is no
      read-only query for clip_markers row counts. Without it the
      domain assertion ("count stable across re-import") cannot be
      observed black-box from the test body. Per authoring rules
      (do NOT invent missing primitives — flag it), this smoke is
      skipped until that helper lands.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestDRPMarkers(JVESmokeCase):
    """DRP marker import + re-import idempotency.

    Methods chain: test_01 establishes baseline marker count from a
    first import; test_02 re-imports the same DRP and asserts the
    count is stable (per-UUID dedup, not per-parse fresh insert).
    """

    FIXTURE = "tests/fixtures/resolve/markers_16color_edge.drp"

    @unittest.skip("needs clip_marker_count query in core.debug_helpers")
    def test_01_first_import_produces_markers(self) -> None:
        self.menu_pick("File > Import > Resolve Project (.drp)...")
        self.pick_file_in_open_dialog(str(Path(self.FIXTURE).resolve()))
        self.wait_for(
            "return require('core.debug_helpers').media_count() > 0",
            timeout=30.0)
        # TODO: query clip_marker_count_for_clip(<countdown clip id>) and
        # stash on the class for test_02 to compare against.

    @unittest.skip("needs clip_marker_count query in core.debug_helpers")
    def test_02_reimport_does_not_double_markers(self) -> None:
        # Re-import the same DRP. Per FR-011b, clip.id = Sm2Ti DbId is
        # stable per clip instance — so clip rows are reused and the
        # importer's per-marker UUID dedup path is what we're pinning.
        self.menu_pick("File > Import > Resolve Project (.drp)...")
        self.pick_file_in_open_dialog(str(Path(self.FIXTURE).resolve()))
        self.wait_for(
            "return require('core.debug_helpers').media_count() > 0",
            timeout=30.0)
        # TODO: re-query clip_marker_count_for_clip and assert equal to
        # the count captured in test_01. Re-import doubling the count is
        # the regression — per-marker UUID being fresh per parse would
        # cause every re-import to N×.


if __name__ == "__main__":
    unittest.main()
