"""
End-to-end domain behavior for track lock: locking V1 must persist,
the renderer must survive the locked-overlay draw pass, an Insert
targeting the locked track must refuse with a "locked" error, a
SetClipProperty on a clip ON the locked track must refuse, and a
pre-lock edit must remain undoable after a subsequent re-lock (the
undo path bypasses lock).

Origin: tests/binding/test_track_lock_end_to_end.lua (Group B,
MIGRATION_ANALYSIS.md line 192). The Lua test drove via direct
command_manager.execute calls and seeded a custom clip + patch via
raw SQL. The smoke rewrite must drive each step through real OS
input — toggle lock via the track-header lock button, attempt the
Insert via F9 with a real source clip loaded + patch routing
established, attempt the property toggle via D after selecting the
clip, undo via Cmd+Z — and observe outcomes via core.debug_helpers.

This requires primitives not yet in the smoke toolkit:
  - clicking the track-header lock button (track_lock_btn_rect coords)
  - reading the most recent command error message
    (last_error_message() helper)
  - track_locked(id) helper on core.debug_helpers

Without these, a faithful rewrite either degenerates into eval-shim
direct-command-execution (which is the exact anti-pattern that
SMOKE_TEST_AUTHORING.md and the migration notes prohibit) or skips
real-OS-input verification of the lock-button itself — defeating
the point of moving it out of --test mode. Skipping until the
primitives land.

Run (after primitives exist):
    python3 -m unittest tests.smoke.cases.test_track_lock_end_to_end -v
"""

# TODO: needs click_track_lock_button(track_id) primitive — see MIGRATION_ANALYSIS.md line 196
# TODO: needs core.debug_helpers.last_error_message() — see MIGRATION_ANALYSIS.md line 195
# TODO: needs core.debug_helpers.track_locked(track_id) — see MIGRATION_ANALYSIS.md line 195

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestTrackLockEndToEnd(JVESmokeCase):
    """Track lock persists, blocks edits on the locked track, allows undo
    of pre-lock edits, and the renderer survives the locked overlay."""

    @unittest.skip("needs click_track_lock_button, last_error_message, "
                   "track_locked primitives — see MIGRATION_ANALYSIS.md")
    def test_lock_persists_blocks_edits_and_allows_undo(self) -> None:
        # Intended flow (once primitives exist):
        #   1. click the lock button on the displayed-sequence V1 header,
        #      assert track_locked(v1_id) is true and a render pump
        #      doesn't crash;
        #   2. load a source clip, patch route source V1 -> rec V1,
        #      press F9, assert displayed_clips_count() unchanged and
        #      last_error_message() matches /[Ll]ocked/;
        #   3. select a clip ON V1 (click_clip), press D, assert
        #      clip_enabled(id) unchanged and last_error_message() matches
        #      /[Ll]ocked/;
        #   4. click the lock button to unlock, press D, assert
        #      clip_enabled flipped, click the lock button to re-lock,
        #      press Cmd+Z, assert the pre-lock D edit was undone
        #      (clip_enabled flipped back) — undo bypasses the lock.
        raise AssertionError("unreachable: test is skipped")


if __name__ == "__main__":
    unittest.main()
