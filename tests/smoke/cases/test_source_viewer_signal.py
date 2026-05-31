"""
015 T036: source_loaded_changed signal contract — pins that loading,
switching, reloading and unloading the source viewer emits
``source_loaded_changed(new, prev)`` with the correct previous-id
bookkeeping, and that a nil-id load asserts.

Migrated from ``tests/integration/test_source_viewer_signal.lua``.
MIGRATION_ANALYSIS.md groups this with the sibling
``test_source_viewer_publishes_selection.lua`` as
``TestSourceViewerLoadSignals``.

Status: skipped — exercising this through real UI requires primitives
that don't exist yet:

  - a way to load an arbitrary MASTER sequence (not a timeline clip)
    into the source viewer via real input. ``Shift+F`` only loads the
    clip under the playhead live-bound; there is no key/menu route to
    ``source_viewer.load_master_clip(seq_id)``.
  - a way to UNLOAD the source viewer (``source_viewer.unload()``) via
    real input — no keymap binding, no menu pick.
  - a signal listener hook on the Python side (case (e)'s "no signal
    on redundant unload" is a counting assertion across calls).
  - the (f) nil-arg assert path has no user-facing surface at all.

Authoring rules forbid driving ``source_viewer.load_master_clip`` /
``unload`` from the test body via eval — that's direct API mutation.
"""

# TODO: needs source_viewer_load_master / source_viewer_unload UI primitives + signal listener — see MIGRATION_ANALYSIS.md
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestSourceViewerLoadSignals(JVESmokeCase):
    """source_loaded_changed signal contract on load / switch / unload."""

    @unittest.skip("needs source_viewer_load_master + source_viewer_unload primitives + signal listener")
    def test_source_loaded_changed_emits_correct_prev_new_pairs(self) -> None:
        # See module docstring. Behavior to pin once primitives exist:
        #   (a) first load     → (new, nil)
        #   (b) switch load    → (new, prev)
        #   (c) reload same    → (same, same)  — listeners debounce
        #   (d) unload         → (nil, prev)
        #   (e) redundant unld → no signal
        #   (f) nil arg        → asserts
        pass


if __name__ == "__main__":
    unittest.main()
