"""
FCP7 XML importer must strip out-of-bounds (negative) sentinel
start/end values — no clip persisted on the timeline may have a
negative ``sequence_start_frame``.

Pins the same domain behavior as the now-replaced
``tests/binding/test_import_fcp7_negative_start.lua``: import the
``2025-07-08-anamnesis-PICTURE-LOCK-TWO more comps.xml`` fixture
(which carries the negative sentinels the importer must filter), then
assert zero clips landed with a negative timeline start.

TODO: needs ``debug_helpers.count_clips_with_negative_start(seq_id?)`` —
see MIGRATION_ANALYSIS.md entry for
``tests/binding/test_import_fcp7_negative_start.lua``. The legacy Lua
test reached straight into the DB with
``SELECT COUNT(*) FROM clips WHERE sequence_start_frame < 0``; smokes
must go through ``core.debug_helpers`` instead, and no such helper
exists yet.

Run:
    python3 -m unittest tests.smoke.cases.test_import_fcp7_negative_start -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


FIXTURE = (
    "tests/fixtures/resolve/"
    "2025-07-08-anamnesis-PICTURE-LOCK-TWO more comps.xml"
)


class TestImportFCP7NegativeStart(JVESmokeCase):
    """FCP7 importer must not leak negative-start sentinel clips."""

    @unittest.skip(
        "needs debug_helpers.count_clips_with_negative_start — see "
        "MIGRATION_ANALYSIS.md entry for "
        "test_import_fcp7_negative_start.lua")
    def test_fcp7_import_strips_negative_start_sentinels(self) -> None:
        repo_root = Path(__file__).resolve().parents[3]
        fixture_path = repo_root / FIXTURE
        self.assertTrue(fixture_path.exists(),
            f"fixture missing: {fixture_path}")

        seq_count_before = self.eval_int(
            'return require("core.debug_helpers").sequence_count()')

        self.menu_pick("File > Import > FCP7 XML...")
        self.pick_file_in_open_dialog(str(fixture_path))

        # Importer is async — wait until at least one new sequence lands.
        self.wait_for(
            'return require("core.debug_helpers").sequence_count() > '
            f'{seq_count_before}',
            timeout=30.0)

        # Domain assertion (origin: legacy Lua test message):
        # "found N clips with negative start_value" — must be zero.
        negative_count = self.eval_int(
            'return require("core.debug_helpers")'
            '.count_clips_with_negative_start()')
        self.assertEqual(0, negative_count, (
            f"found {negative_count} clips with negative start_value — "
            "FCP7 importer is not filtering out-of-bounds sentinel "
            "start/end markers; downstream timeline math will treat "
            "them as real pre-zero placements."))

        # Sanity: the import actually produced clips (otherwise the zero
        # above is vacuous).
        seq_id = self.eval_str(
            'return require("core.debug_helpers").displayed_sequence_id()')
        clips = self.eval_int(
            'return require("core.debug_helpers")'
            f'.clip_count_on_sequence("{seq_id}")')
        self.assertGreater(clips, 0,
            "expected importer to create timeline clips on the displayed "
            "sequence; got zero — negative-count assertion above was "
            "vacuous.")


if __name__ == "__main__":
    unittest.main()
