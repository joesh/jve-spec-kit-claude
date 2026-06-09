"""
Source-tab rekey leaves no orphan: when the source viewer swaps from
master A to master B, the source tab is rekeyed in place (single
source-tab entry whose key matches the loaded master); when the source
viewer unloads, the source tab is dropped. The displayed strip ends up
holding exactly the record tab plus at most one source tab keyed to
the current source master.

Regression target (TSO 2026-05-23, verified by Joe 2026-05-24): with
master A loaded in the source viewer, F-pressing on a clip whose
master is B used to leave the panel showing the A tab AND a new B tab
— A stuck around as a ghost. Origin: tests/integration/test_source_tab_rekey_no_orphan.lua.

# TODO: needs source-viewer unload primitive (no keybind today) — see MIGRATION_ANALYSIS.md
# TODO: needs `open_tab_ids()` debug helper (only `open_tabs_count()` exists today)
# TODO: needs `source_tab_seq_id()` debug helper to read which seq the source tab is keyed under

Run:
    python3 -m unittest tests.live.cases.test_source_tab_rekey_no_orphan -v
"""

import unittest

from tests.live.runner.case import JVESmokeCase

class TestSourceTabRekeyNoOrphan(JVESmokeCase):
    """Source-tab rekey-in-place: A→B swap drops A; unload drops source tab."""

    @unittest.skip("needs source-viewer unload primitive + open_tab_ids/source_tab_seq_id debug helpers")
    def test_source_master_swap_rekeys_in_place_no_orphan(self) -> None:
        # Intended flow (once primitives land):
        #
        # 1. From anamnesis, pick two timeline clips backed by distinct
        #    master sequences MA and MB.
        # 2. Click clip backed by MA, focus timeline, press Shift+F →
        #    source viewer enters live-bound on MA, source tab opens
        #    keyed to MA. Assert: open_tab_ids == {record_seq, MA};
        #    source_tab_seq_id == MA.
        # 3. Click clip backed by MB, press Shift+F → source rekeys
        #    in place to MB. Assert: open_tab_ids == {record_seq, MB};
        #    source_tab_seq_id == MB. ORPHAN BUG: MA still present.
        # 4. Unload source viewer (primitive TBD). Assert:
        #    open_tab_ids == {record_seq}; source_tab_seq_id == nil.
        pass

if __name__ == "__main__":
    unittest.main()
