"""
DRT import preserves ``<OriginalClip>`` substitution history as
metadata on the active clip, and refuses to harvest the historical
Windows path as a phantom media row. Origin:
``tests/binding/test_drt_historical_clip_ignored.lua``.

Behavior pinned (domain-level): after importing the anamnesis-GOLD
.drt via File>Import>Resolve Timeline:
  (1) no media row exists for the historical Windows path
      ``D:\\Reshoots\\IMG_3270.MOV`` — it appears only as history, not
      as content the timeline plays;
  (2) the real ``IMG_3270.MOV`` media is present with non-zero
      duration;
  (3) the clip named ``IMG_3270.MOV Render`` carries an
      ``original_clip`` property whose ``file_path`` is the historical
      Windows path, so Inspector / relink-fallback / history view can
      surface it.

# TODO: needs debug_helpers queries
#   - media_has_file_path(path) -> bool
#   - media_exists_with_name_and_nonzero_duration(name) -> bool
#   - clip_property_value(clip_id, "original_clip") -> JSON string or nil
#   - find_clip_id_by_name_substring(seq_id, "IMG_3270.MOV Render") -> id
# Also relies on `pick_file_in_open_dialog` reliably driving the
# QFileDialog for a deep nested fixture path with spaces.
# See MIGRATION_ANALYSIS.md entry for
# tests/binding/test_drt_historical_clip_ignored.lua.

Run:
    python3 -m unittest tests.smoke.cases.test_drt_historical_clip_ignored -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


FIXTURE = (
    "tests/fixtures/media/anamnesis/"
    "2026-02-28-anamnesis joe edit-mm/"
    "2026-02-28-anamnesis-GOLD-MASTER-CANDIDATE.drt"
)
PHANTOM_PATH = r"D:\Reshoots\IMG_3270.MOV"


class TestDRTHistoricalClipIgnored(JVESmokeCase):
    """Import the gold DRT and inspect the resulting catalog + clip metadata."""

    @unittest.skip(
        "needs debug_helpers: media_has_file_path, "
        "media_exists_with_name_and_nonzero_duration, "
        "clip_property_value, find_clip_id_by_name_substring — "
        "see MIGRATION_ANALYSIS.md")
    def test_01_import_drt_via_menu(self) -> None:
        """File>Import>Resolve Timeline (.drt)..., pick the gold fixture,
        wait for the sequence count to climb (merge import).
        """
        baseline_seqs = self.eval_int(
            "return require('core.debug_helpers').sequence_count()")
        self.menu_pick("File > Import > Resolve Timeline (.drt)...")
        self.pick_file_in_open_dialog(str(Path(FIXTURE).resolve()))
        self.wait_for(
            "return require('core.debug_helpers').sequence_count() > "
            f"{baseline_seqs}",
            timeout=30.0)

    @unittest.skip(
        "needs debug_helpers.media_has_file_path — see MIGRATION_ANALYSIS.md")
    def test_02_phantom_windows_path_not_in_media_catalog(self) -> None:
        """Invariant 1: <OriginalClip> history must not pollute the
        media catalog with the historical Windows path."""
        has_phantom = self.eval_bool(
            "return require('core.debug_helpers').media_has_file_path("
            f"{PHANTOM_PATH!r})")
        self.assertFalse(has_phantom, (
            f"phantom media row present for historical <OriginalClip> "
            f"path {PHANTOM_PATH!r} — the importer's raw-XML catch-all "
            f"is harvesting history blocks as if they were active media"))

    @unittest.skip(
        "needs debug_helpers.media_exists_with_name_and_nonzero_duration "
        "— see MIGRATION_ANALYSIS.md")
    def test_03_real_img_3270_media_present(self) -> None:
        """Invariant 2: the active IMG_3270.MOV media (what the timeline
        actually plays) remains present with valid duration — the fix
        for invariant 1 must not over-reach."""
        found = self.eval_bool(
            "return require('core.debug_helpers')"
            ".media_exists_with_name_and_nonzero_duration('IMG_3270.MOV')")
        self.assertTrue(found, (
            "no real IMG_3270.MOV media row with non-zero duration after "
            "DRT import — the phantom-path fix has over-reached and is "
            "dropping the active media too"))

    @unittest.skip(
        "needs debug_helpers.find_clip_id_by_name_substring + "
        "clip_property_value — see MIGRATION_ANALYSIS.md")
    def test_04_render_clip_carries_original_clip_metadata(self) -> None:
        """Invariants 3+4: the Render.mov clip carries the substitution
        history as an ``original_clip`` property pointing at the
        historical Windows path, and that property survives persistence
        so Inspector / relink fallback can see it."""
        seq_id = self.eval_str(
            "return require('core.debug_helpers').displayed_sequence_id()")
        clip_id = self.eval_str(
            "return require('core.debug_helpers')"
            f".find_clip_id_by_name_substring('{seq_id}', "
            "'IMG_3270.MOV Render')")
        self.assertTrue(clip_id and clip_id != "",
            "no Render.mov clip with substitution history found on the "
            "imported timeline — fixture or import path changed")

        encoded = self.eval_str(
            "return require('core.debug_helpers')"
            f".clip_property_value('{clip_id}', 'original_clip')")
        self.assertTrue(encoded and encoded != "", (
            "Render.mov clip has no persisted original_clip property — "
            "substitution history was lost between parse and persist; "
            "downstream consumers (Inspector, relink fallback, history "
            "view) cannot surface it"))

        # Domain assertion: persisted history points at the historical
        # Windows path with the original filename. Parsing JSON in Lua
        # keeps the eval string short.
        file_path = self.eval_str(
            "local json = require('dkjson'); "
            "local row = require('core.debug_helpers')"
            f".clip_property_value('{clip_id}', 'original_clip'); "
            "local decoded = json.decode(row); "
            "local v = decoded and (decoded.value or decoded); "
            "return tostring(v and v.file_path or '')")
        self.assertEqual(PHANTOM_PATH, file_path, (
            f"persisted original_clip.file_path = {file_path!r}, "
            f"expected {PHANTOM_PATH!r}"))

        name = self.eval_str(
            "local json = require('dkjson'); "
            "local row = require('core.debug_helpers')"
            f".clip_property_value('{clip_id}', 'original_clip'); "
            "local decoded = json.decode(row); "
            "local v = decoded and (decoded.value or decoded); "
            "return tostring(v and v.name or '')")
        self.assertEqual("IMG_3270.MOV", name, (
            f"persisted original_clip.name = {name!r}, expected "
            f"'IMG_3270.MOV'"))


if __name__ == "__main__":
    unittest.main()
