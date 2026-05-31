"""
017 transport-target derivation: displaying the source tab OR loading a
master into the source viewer must route transport to the SOURCE side,
not record. Pins the same domain behavior as the Lua origin
``tests/integration/test_source_tab_and_viewer_set_transport_target.lua``.

Domain rules:
  * Fresh project, no source loaded, no source tab displayed → transport
    target derives to "record".
  * Loading a master into the source viewer (here: via ``F`` /
    MatchFrame, whose executor calls ``source_viewer.load_master_clip``)
    focuses the source monitor → transport target derives to "source",
    AND the source-role engine binds to the loaded master while the
    record engine does NOT mirror it.
  * Toggling the displayed tab back to the record tab (``Grave``) →
    transport target derives back to "record".
"""

import unittest

from tests.smoke.runner.case import JVESmokeCase

class TestSourceTabAndViewerSetTransportTarget(JVESmokeCase):
    """Source-tab / source-viewer display flips transport target to source."""

    def test_01_fresh_target_is_record(self) -> None:
        # No source viewer load, no source tab displayed → derived target
        # is "record". Matches the Lua origin's first assertion.
        target = self.eval_str(
            'return require("core.debug_helpers").transport_target()')
        self.assertEqual("record", target, (
            "fresh state: no source loaded, no source tab displayed → "
            f"derived target should be 'record'; got '{target}'"))

        kind = self.eval_str(
            'return tostring(require("core.debug_helpers").displayed_tab_kind())')
        self.assertEqual("record", kind, (
            "fresh state should be displaying the record tab; "
            f"got displayed_tab_kind='{kind}'"))

    def test_02_match_frame_loads_master_and_flips_target_to_source(self) -> None:
        # MatchFrame (F) on a selected timeline clip calls
        # source_viewer.load_master_clip(target_master_id) — the same
        # entry point exercised by the Lua origin. It focuses the source
        # monitor, which causes transport.get_target() to derive 'source'.
        clip = self.first_armed_video_clip(48)

        rec_engine_seq_before = self.eval_str(
            'return tostring(require("core.debug_helpers")'
            '.record_engine_sequence_id())')

        # Select the clip via real click, then anchor focus on the
        # timeline so F dispatches to the right scope.
        self.click_clip(clip.id)
        self.focus_panel("timeline")

        # Press F — MatchFrame → source_viewer.load_master_clip → focus
        # source_monitor → derived target flips to 'source'.
        self.key("F")

        target = self.eval_str(
            'return require("core.debug_helpers").transport_target()')
        self.assertEqual("source", target, (
            "after F (MatchFrame) on a selected clip, source_viewer must "
            "focus the source_monitor so the derived transport target is "
            f"'source'; got '{target}'. Either the keypress didn't reach "
            "MatchFrame, or load_master_clip skipped focus_panel."))

        src_engine_seq = self.eval_str(
            'return tostring(require("core.debug_helpers")'
            '.source_engine_sequence_id())')
        self.assertNotIn(src_engine_seq, ("nil", ""), (
            "source engine must carry the loaded master after "
            "load_master_clip; got source_engine_sequence_id="
            f"'{src_engine_seq}'"))

        rec_engine_seq_after = self.eval_str(
            'return tostring(require("core.debug_helpers")'
            '.record_engine_sequence_id())')
        self.assertNotEqual(rec_engine_seq_after, src_engine_seq, (
            "record engine must NOT mirror the loaded source master "
            f"('{src_engine_seq}'); record engine loaded='"
            f"{rec_engine_seq_after}', was '{rec_engine_seq_before}'"))

    def test_03_grave_back_to_record_tab_flips_target_to_record(self) -> None:
        # test_02 left a source tab displayed. Grave toggles back to the
        # record tab — derived target must flip back to 'record'.
        kind_before = self.eval_str(
            'return tostring(require("core.debug_helpers").displayed_tab_kind())')
        self.assertEqual("source", kind_before, (
            "test_03 preconditions: test_02 should have left the source "
            f"tab displayed; got displayed_tab_kind='{kind_before}'"))

        self.focus_panel("timeline")
        self.key("Grave")

        kind_after = self.eval_str(
            'return tostring(require("core.debug_helpers").displayed_tab_kind())')
        self.assertEqual("record", kind_after, (
            "after Grave from the source tab, the record tab should be "
            f"displayed; got displayed_tab_kind='{kind_after}'"))

        target = self.eval_str(
            'return require("core.debug_helpers").transport_target()')
        self.assertEqual("record", target, (
            "with the record tab displayed and source monitor not "
            "focused, derived transport target should be 'record'; got "
            f"'{target}'"))

if __name__ == "__main__":
    unittest.main()
