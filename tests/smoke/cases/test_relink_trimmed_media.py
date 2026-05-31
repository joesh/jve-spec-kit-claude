"""
Relink-to-trimmed-media preserves absolute timecode (FR: TC is the
source of truth across relink). After relinking a clip from an
untrimmed master to a trimmed subset covering the same TC range, the
clip's source_in/source_out must be unchanged (TC is absolute), and
Cm+Z / Cmd+Shift+Z must round-trip both the media path and the
source coordinates atomically. Pinned previously by
``tests/integration/test_relink_trimmed_media.lua``.

# TODO: needs relink-via-UI primitive (Media > Relink menu + file
# picker driver) — see MIGRATION_ANALYSIS.md GROUP D entry for
# tests/integration/test_relink_trimmed_media.lua ("needs relink-via-UI
# flow (Media menu)"). Also needs debug_helpers queries
# ``clip_source_in(id)`` / ``clip_source_out(id)`` / ``clip_media_path(id)``
# (today ``clip_field(id, field)`` is the closest generic getter — verify
# it covers source_in_frame, source_out_frame, and the joined media row
# before un-skipping).
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestRelinkTrimmedMediaPreservesTC(JVESmokeCase):
    """Relink original→trimmed: source_in/out unchanged; undo/redo atomic."""

    @unittest.skip("needs relink-via-UI primitive (Media>Relink + file dialog)")
    def test_01_relink_to_trimmed_preserves_source_coords(self) -> None:
        # 1. Pick a clip on the displayed sequence whose media row points
        #    at the untrimmed master, capture source_in/source_out and
        #    media_path via debug_helpers.
        # 2. self.click_clip(clip_id) to select it.
        # 3. self.menu_pick("File > Relink Selected Media...") (exact
        #    menu path TBD when relink-via-UI primitive lands).
        # 4. self.pick_file_in_open_dialog(<trimmed path>).
        # 5. self.wait_for(...) until media row's file_path updates.
        # 6. Assert source_in/out unchanged — TC is absolute, so the
        #    same content frame still resolves through the trimmed file
        #    via file_pos = source_in - trimmed_tc_origin.
        raise NotImplementedError

    @unittest.skip("needs relink-via-UI primitive (Media>Relink + file dialog)")
    def test_02_undo_restores_original_media_path(self) -> None:
        # Cmd+Z must restore both the media row's file_path AND the
        # clip's source_in/source_out as a single atomic step.
        self.key("Cmd+Z")
        raise NotImplementedError

    @unittest.skip("needs relink-via-UI primitive (Media>Relink + file dialog)")
    def test_03_redo_reapplies_relink(self) -> None:
        # Cmd+Shift+Z must re-apply the relink: media path returns to
        # trimmed, clip source coords still unchanged from baseline.
        self.key("Cmd+Shift+Z")
        raise NotImplementedError


if __name__ == "__main__":
    unittest.main()
