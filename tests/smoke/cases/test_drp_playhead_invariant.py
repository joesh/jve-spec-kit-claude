# TODO: needs `core.debug_helpers.sequence_ids()` (and underlying
# `Sequence.list_all_ids()`) to enumerate every sequence produced by a
# DRP import — see MIGRATION_ANALYSIS.md entry for
# tests/binding/test_drp_playhead_invariant.lua. Reads through the
# anamnesis substrate happen to expose a single record sequence via
# `displayed_sequence_id()`, but the invariant must hold for EVERY
# imported sequence (masters + timelines), so a per-id enumerator is
# required. Until then this smoke is skipped.
"""
DRP import invariant — every sequence produced by the DRP→JVP conversion
path satisfies playhead_position >= start_timecode_frame. A playhead
below the sequence's TC origin trips the C++ playback engine's
start-frame assert at seek time, so pre-content space is meaningless
anyway. Sequence.create enforces this at construction; this smoke pins
the importer call paths as honoring it end-to-end.

Origin: tests/binding/test_drp_playhead_invariant.lua (pre-2026-05-30
binding test that called `_convert_drp_to_jvp` directly; replaced here
by driving File > Open Project... on `sample_project.drp` through the
real menu + file dialog).

Run:
    python3 -m unittest tests.smoke.cases.test_drp_playhead_invariant -v
"""

import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT))

from tests.smoke.runner.case import JVESmokeCase

FIXTURE_DRP = REPO_ROOT / "tests" / "fixtures" / "resolve" / "sample_project.drp"


class TestDRPPlayheadInvariant(JVESmokeCase):
    """Every imported sequence must satisfy playhead >= start_timecode_frame."""

    @unittest.skip("needs core.debug_helpers.sequence_ids() enumerator — "
                   "see TODO at top of file")
    def test_drp_open_emits_no_sub_tc_origin_playhead(self) -> None:
        # Fresh project at class setup is the anamnesis template; for
        # this test we want a pristine open of the DRP fixture so the
        # only sequences in the project are the ones the importer
        # emitted. Reset to template first, then drive File > Open
        # Project... onto the DRP — JVE's open path converts .drp to
        # .jvp on the way in (the behavior we're pinning).
        self._reset_to_template()

        self.assertTrue(FIXTURE_DRP.exists(),
            f"fixture missing: {FIXTURE_DRP}")

        before = self.eval_int(
            'return require("core.debug_helpers").sequence_count()')

        self.menu_pick("File > Open Project...")
        self.pick_file_in_open_dialog(str(FIXTURE_DRP))

        # Import is async — wait for the sequence table to grow past
        # the pre-import count.
        self.wait_for(
            f'return require("core.debug_helpers").sequence_count() > {before}',
            timeout=20.0)

        # Enumerate every sequence id and assert the invariant.
        # `sequence_ids()` is the missing primitive that gates this
        # test — must return a delimited string of all sequence ids in
        # the active project so the smoke can split + iterate.
        ids_blob = self.eval_str(
            'return table.concat('
            '  require("core.debug_helpers").sequence_ids(), "|")')
        ids = [s for s in ids_blob.strip('"').split("|") if s]
        self.assertGreater(len(ids), 0,
            "DRP import produced no sequences — importer broken or "
            "the Open dialog didn't accept the file.")

        for seq_id in ids:
            playhead = self.eval_int(
                f'return require("core.debug_helpers").playhead_of("{seq_id}")')
            start_tc = self.eval_int(
                f'return require("core.debug_helpers").sequence_start_tc("{seq_id}")')
            name = self.eval_str(
                f'return require("core.debug_helpers").sequence_field("{seq_id}", "name")')
            kind = self.eval_str(
                f'return require("core.debug_helpers").sequence_field("{seq_id}", "kind")')
            self.assertGreaterEqual(playhead, start_tc, (
                f"DRP import violates playhead invariant for sequence "
                f"'{name}' (kind={kind}): "
                f"playhead_position={playhead} < "
                f"start_timecode_frame={start_tc} — track down which "
                f"Sequence.create call site emitted a sub-TC-origin "
                f"playhead."))


if __name__ == "__main__":
    unittest.main()
