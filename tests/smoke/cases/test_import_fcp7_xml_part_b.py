"""
FCP7 XML import (Part B — post-import edit regressions) pins that
after importing an FCP7 XML timeline, the normal editing commands
flow correctly on the imported sequence: ``D`` toggles a clip's
enabled flag, ``Cmd+B`` blades the clip under the playhead into two,
and ``Delete`` removes a selected clip (``Cmd+Z`` then restores it).

These regressions matter because the import path constructs clips
through the importer instead of the normal Insert/Split commands —
if the resulting rows are subtly different (missing fields, wrong
track linkage), downstream edit commands silently no-op or corrupt
state.

Origin: ``tests/binding/test_import_fcp7_xml.lua`` (Part A is
``test_import_fcp7_xml.py``).

Run:
    python3 -m unittest tests.smoke.cases.test_import_fcp7_xml_part_b -v
"""

import unittest
from pathlib import Path

from tests.smoke.runner.case import JVESmokeCase

FIXTURE = "tests/fixtures/resolve/sample_timeline_fcp7xml.xml"

class TestImportFCP7Regressions(JVESmokeCase):
    """Post-import D / Cmd+B / Delete must operate correctly."""

    def _import_fixture(self) -> None:
        """Drive File > Import > FCP7 XML... once at the top of the class."""
        repo_root = Path(__file__).resolve().parents[3]
        fixture_path = repo_root / FIXTURE
        self.assertTrue(fixture_path.exists(),
            f"fixture missing: {fixture_path}")
        seq_before = self.eval_int(
            'return require("core.debug_helpers").sequence_count()')
        self.menu_pick("File > Import > FCP7 XML...")
        self.pick_file_in_open_dialog(str(fixture_path))
        self.wait_for(
            f'return require("core.debug_helpers").sequence_count() > {seq_before}',
            timeout=30.0)

    def _pick_displayed_clip(self) -> tuple[str, int, int]:
        """Return ``(clip_id, sequence_start, duration)`` for the
        first non-gap clip on the displayed (imported) sequence with
        enough duration to blade safely. Lua Clip model fields drop the
        ``_frame``/``_frames`` SQL-column suffix."""
        info = self.eval(
            'local ts = require("ui.timeline.timeline_state"); '
            'for _, c in ipairs(ts.get_tab_strip():displayed_clips()) do '
            '  if not c.is_gap and c.duration and c.duration > 10 then '
            '    return string.format("%s|%d|%d", c.id, '
            '      c.sequence_start, c.duration) '
            '  end '
            'end; '
            'error("no non-gap clip with duration > 10 frames on displayed sequence")')
        clip_id, start_str, dur_str = info.strip('"').split('|', 2)
        return clip_id, int(start_str), int(dur_str)

    def test_01_import_fixture(self) -> None:
        self._import_fixture()
        displayed = self.eval_str(
            'return require("core.debug_helpers").displayed_sequence_id()')
        clip_count = self.eval_int(
            'return require("core.debug_helpers")'
            f'.clip_count_on_sequence("{displayed}")')
        self.assertGreater(clip_count, 0,
            "import did not populate the displayed sequence — subsequent "
            "regression methods have nothing to edit")

    def test_02_d_toggles_imported_clip_enabled(self) -> None:
        clip_id, _, _ = self._pick_displayed_clip()
        self.click_clip(clip_id)
        self.focus_panel("timeline")

        enabled_before = self.eval_bool(
            f'return require("core.debug_helpers").clip_enabled("{clip_id}")')
        self.assertTrue(enabled_before,
            f"precondition: imported clip {clip_id} should start enabled")

        self.key("D")
        enabled_after = self.eval_bool(
            f'return require("core.debug_helpers").clip_enabled("{clip_id}")')
        self.assertFalse(enabled_after, (
            f"D on imported clip {clip_id} should flip enabled to false; "
            f"still true means ToggleClipEnabled didn't reach this clip — "
            f"likely the imported row is missing fields the executor "
            f"requires."))

        # Toggle back so subsequent methods see a normal enabled clip.
        self.key("D")

    def test_03_blade_splits_imported_clip_into_two(self) -> None:
        clip_id, start, dur = self._pick_displayed_clip()
        displayed = self.eval_str(
            'return require("core.debug_helpers").displayed_sequence_id()')
        clips_before = self.eval_int(
            f'return require("core.debug_helpers")'
            f'.clip_count_on_sequence("{displayed}")')

        # Park the playhead one third into the clip — well inside its
        # span on both sides so the blade produces two real pieces.
        blade_frame = start + max(2, dur // 3)
        self.move_playhead_to(blade_frame)
        self.focus_panel("timeline")

        self.key("Cmd+B")

        clips_after = self.eval_int(
            f'return require("core.debug_helpers")'
            f'.clip_count_on_sequence("{displayed}")')
        self.assertEqual(clips_before + 1, clips_after, (
            f"Cmd+B at frame {blade_frame} inside clip {clip_id} should "
            f"split it into two — expected clip count {clips_before + 1}, "
            f"got {clips_after}. BladeAtPlayhead silently no-op'd, likely "
            f"because the imported clip's source range or track linkage "
            f"is malformed."))

    def test_04_delete_removes_clip_and_undo_restores(self) -> None:
        clip_id, _, _ = self._pick_displayed_clip()
        displayed = self.eval_str(
            'return require("core.debug_helpers").displayed_sequence_id()')
        clips_before = self.eval_int(
            f'return require("core.debug_helpers")'
            f'.clip_count_on_sequence("{displayed}")')

        self.click_clip(clip_id)
        self.focus_panel("timeline")
        self.assertTrue(
            self.eval_bool(
                f'return require("core.debug_helpers").clip_exists("{clip_id}")'),
            f"precondition: clip {clip_id} should exist before Delete")

        self.key("Delete")
        self.assertFalse(
            self.eval_bool(
                f'return require("core.debug_helpers").clip_exists("{clip_id}")'),
            (f"Delete on selected clip {clip_id} should remove it; the "
             f"row still exists. DeleteSelection didn't reach this clip."))
        clips_after_delete = self.eval_int(
            f'return require("core.debug_helpers")'
            f'.clip_count_on_sequence("{displayed}")')
        self.assertEqual(clips_before - 1, clips_after_delete,
            "displayed sequence clip count should drop by one after Delete")

        self.key("Cmd+Z")
        self.assertTrue(
            self.eval_bool(
                f'return require("core.debug_helpers").clip_exists("{clip_id}")'),
            (f"Cmd+Z after Delete should restore clip {clip_id}; row "
             f"still gone — DeleteSelection's undoer didn't recreate it."))
        clips_after_undo = self.eval_int(
            f'return require("core.debug_helpers")'
            f'.clip_count_on_sequence("{displayed}")')
        self.assertEqual(clips_before, clips_after_undo,
            "displayed sequence clip count should return to pre-delete "
            "value after Cmd+Z")

if __name__ == "__main__":
    unittest.main()
