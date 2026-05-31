"""
FCP7 import view-state survives undo/redo: pins that after the user
imports an FCP7 XML, modifies the timeline viewport (zoom + scroll) and
moves the playhead, then undoes and redoes the import, the imported
sequence's viewport_start_time, viewport_duration and playhead_position
come back to the user-modified values (not stale cached values, and not
clobbered by a follow-up persist driven by some other UI action).

Origin: ``tests/binding/test_import_view_state_redo.lua`` — the legacy
test exercised the same redo-then-stale-persist scenario via inline
XML and direct ``timeline_state`` calls.

TODO: needs ``set_viewport_to(start_frame, duration_frames)`` primitive
(or a deterministic Cmd+=/Cmd+- + horizontal-scroll sequence with a
known starting zoom) — see MIGRATION_ANALYSIS.md entry for
``tests/binding/test_import_view_state_redo.lua``. Without it, the
test can drive ``move_playhead_to`` but cannot pin viewport_start /
viewport_duration to specific frame values from real input, so the
"DB still holds the user's modified viewport after redo+persist"
assertion can't be expressed in domain-level frames.

TODO: needs an FCP7 XML fixture under ``tests/fixtures/`` that mirrors
the 120-frame two-clip sequence the legacy test inlined as a string
(or reuse an existing small anamnesis FCP7 export). Smoke tests can
only import via File > Import > FCP7 XML... + pick_file_in_open_dialog
— no inline XML path exists.

Run:
    python3 -m unittest tests.smoke.cases.test_import_view_state_redo -v
"""

import unittest
from pathlib import Path

from tests.smoke.runner.case import JVESmokeCase

class TestImportViewStateRedo(JVESmokeCase):
    """Import + modify viewport/playhead + undo + redo + persist — the
    redone sequence row must still hold the user's modified viewport
    and playhead, not the stale cached values from before undo."""

    @unittest.skip(
        "needs set_viewport_to primitive + FCP7 fixture — see "
        "MIGRATION_ANALYSIS.md entry for test_import_view_state_redo.lua")
    def test_view_state_survives_undo_redo_and_stale_persist(self) -> None:
        repo_root = Path(__file__).resolve().parents[3]
        fixture_path = repo_root / "tests/fixtures/fcp7/view_state_redo.xml"
        self.assertTrue(fixture_path.exists(),
            f"fixture missing: {fixture_path}")

        # ---- 1. Import FCP7 XML via real File menu. ----
        seq_count_before = self.eval_int(
            'return require("core.debug_helpers").sequence_count()')

        self.menu_pick("File > Import > FCP7 XML...")
        self.pick_file_in_open_dialog(str(fixture_path))

        self.wait_for(
            'return require("core.debug_helpers").sequence_count() > '
            f'{seq_count_before}',
            timeout=30.0)

        imported_seq_id = self.eval_str(
            'return require("core.debug_helpers").displayed_sequence_id()')

        # ---- 2. User modifies viewport + playhead via real input. ----
        # TODO: needs set_viewport_to(20, 40) primitive. Today there is
        # no deterministic way from real OS input to land viewport_start
        # = 20 and viewport_duration = 40 — Cmd+= / Cmd+- zoom around
        # the playhead with implementation-dependent step sizes, and
        # the horizontal scroll surface isn't pinned via a key binding.
        self.move_playhead_to(35)

        target_vp_start = 20
        target_vp_dur = 40
        # self.set_viewport_to(target_vp_start, target_vp_dur)   # NOT YET

        # Read modified values back via Sequence row.
        vp_start_modified = self.eval_int(
            'return require("core.debug_helpers")'
            f'.sequence_field("{imported_seq_id}", "viewport_start_time")')
        vp_dur_modified = self.eval_int(
            'return require("core.debug_helpers")'
            f'.sequence_field("{imported_seq_id}", "viewport_duration")')
        playhead_modified = self.eval_int(
            'return require("core.debug_helpers")'
            f'.playhead_of("{imported_seq_id}")')
        self.assertEqual(target_vp_start, vp_start_modified,
            "viewport_start did not reach the requested modified value")
        self.assertEqual(target_vp_dur, vp_dur_modified,
            "viewport_duration did not reach the requested modified value")
        self.assertEqual(35, playhead_modified,
            "playhead did not reach the requested modified frame")

        # ---- 3. Undo the import. The sequence must be gone. ----
        self.key("Cmd+Z")
        self.wait_for(
            f'return require("core.debug_helpers")'
            f'.sequence_field("{imported_seq_id}", "id") == nil',
            timeout=5.0)

        # ---- 4. Redo. Sequence is back; viewport + playhead restored. ----
        self.key("Cmd+Shift+Z")
        self.wait_for(
            f'return require("core.debug_helpers")'
            f'.sequence_field("{imported_seq_id}", "id") ~= nil',
            timeout=5.0)

        vp_start_after_redo = self.eval_int(
            'return require("core.debug_helpers")'
            f'.sequence_field("{imported_seq_id}", "viewport_start_time")')
        vp_dur_after_redo = self.eval_int(
            'return require("core.debug_helpers")'
            f'.sequence_field("{imported_seq_id}", "viewport_duration")')
        playhead_after_redo = self.eval_int(
            'return require("core.debug_helpers")'
            f'.playhead_of("{imported_seq_id}")')
        self.assertEqual(target_vp_start, vp_start_after_redo, (
            f"DB viewport_start should be {target_vp_start} after redo, "
            f"got {vp_start_after_redo}"))
        self.assertEqual(target_vp_dur, vp_dur_after_redo, (
            f"DB viewport_duration should be {target_vp_dur} after redo, "
            f"got {vp_dur_after_redo}"))
        self.assertEqual(35, playhead_after_redo, (
            f"DB playhead should be 35 after redo, got "
            f"{playhead_after_redo}"))

        # ---- 5. Trigger an unrelated UI action that persists timeline
        # state. The freshly-restored DB values must NOT be clobbered by
        # a stale in-memory cache the UI carried across the undo. ----
        # TODO: needs a real-input action that forces timeline_state
        # persist_state_to_db without re-init (e.g. click somewhere in
        # the timeline panel that isn't a clip). Today the legacy test
        # called persist_state_to_db(true) directly — not allowed.
        # self.click_timeline_background()                        # NOT YET

        vp_start_after_persist = self.eval_int(
            'return require("core.debug_helpers")'
            f'.sequence_field("{imported_seq_id}", "viewport_start_time")')
        vp_dur_after_persist = self.eval_int(
            'return require("core.debug_helpers")'
            f'.sequence_field("{imported_seq_id}", "viewport_duration")')
        playhead_after_persist = self.eval_int(
            'return require("core.debug_helpers")'
            f'.playhead_of("{imported_seq_id}")')
        self.assertEqual(target_vp_start, vp_start_after_persist, (
            f"viewport_start should still be {target_vp_start} after "
            f"persist, got {vp_start_after_persist} — a stale cache "
            f"overwrote the restored DB value."))
        self.assertEqual(target_vp_dur, vp_dur_after_persist, (
            f"viewport_duration should still be {target_vp_dur} after "
            f"persist, got {vp_dur_after_persist}."))
        self.assertEqual(35, playhead_after_persist, (
            f"playhead should still be 35 after persist, got "
            f"{playhead_after_persist}."))

if __name__ == "__main__":
    unittest.main()
