"""
Peak cache invalidates on content change, not on path-only relink.

Pins: relinking a media row to a byte-identical file (same mtime) must
NOT regenerate peaks; relinking to a genuinely different file must
regenerate exactly once; close+reopen with valid .peaks on disk must
reuse them (no regen). Origin: tests/integration/test_relink_invalidates_peaks.lua.

# TODO: needs relink-via-UI primitive (Media > Relink... menu flow with
#       file-picker driving) — see MIGRATION_ANALYSIS.md entry for
#       tests/integration/test_relink_invalidates_peaks.lua.
# TODO: needs peak_cache state queries in core.debug_helpers
#       (peak_status(media_id), peak_gen_count(), peak_visible_bins(media_id)).
# TODO: needs PEAK_REQUEST counter exposed read-only (not a test-body
#       monkey-patch) so the smoke can assert exact gen deltas without
#       mutating EMP from Lua.
# TODO: needs distinguishable audio fixtures available on the anamnesis
#       template (or a way to introduce CLICK/TONE WAVs without bespoke
#       DB inserts).
# TODO: needs file-dialog driver for the relink picker
#       (~/.claude/.../todo_smoke_file_dialog_driver.md).
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestRelinkInvalidatesPeaks(JVESmokeCase):
    """Peak cache reuse-vs-regen across relink scenarios."""

    @unittest.skip("needs relink-via-UI + peak_cache debug_helpers + PEAK_REQUEST counter")
    def test_relink_invalidates_peaks(self) -> None:
        raise NotImplementedError


if __name__ == "__main__":
    unittest.main()
