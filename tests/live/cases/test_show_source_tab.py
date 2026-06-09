"""
Source-tab show/blank contract (015 / T011 origin).

Pins the observable behavior of showing the source tab in the timeline
tab strip — combining the domain content of:
  tests/integration/test_show_source_tab.lua
  tests/integration/test_show_source_tab_empty_blanks_body.lua
(per MIGRATION_ANALYSIS.md note: "combine with below").

Domain behaviors pinned, all driven via real OS input:
  (a) source loaded + show-source action → displayed tab kind is "source".
  (b) NO source loaded + show-source action → displayed body blanks
      (displayed_tab_kind becomes nil / no clips), and the source viewer
      is NOT auto-seeded with a random master. TSO 2026-05-17 retired
      the auto-seed-first-master path; the user chose nothing, so the
      editor shows nothing.
  (c) re-showing the source tab when a source IS loaded is idempotent —
      stays on source.

NOTE: ShowSourceTab itself has no keymap/menu binding (grep
keymaps/default.jvekeys + src/lua — only the executor exists). Its
sibling ToggleSourceRecordTab (bound to ``Grave``) shares the
blank-when-no-source path — see show_source_tab.lua's "matching the
close-last-tab state" comment — so Grave is the only real-OS lever that
exercises this contract end-to-end. The Lua original asserted the
unbound-ShowSourceTab branches via command_manager.execute; the smoke
substrate reaches the same pointer-update path (timeline_state.
switch_to_source_tab / .clear) through Grave.

Coverage NOT carried over (no real-UI path; would require mocks):
  (d) non-undoable — snapshot-row introspection
  (e) assert when panel_manager.source_monitor is unregistered
Both depended on internal package.loaded swaps; they belong in a
binding/unit test if Joe wants them re-pinned, not a smoke.

Run:
    python3 -m unittest tests.live.cases.test_show_source_tab -v
"""

import unittest

from tests.live.runner.case import JVESmokeCase

class TestShowSourceTab(JVESmokeCase):
    """Show/blank source-tab contract via the Grave keybinding."""

    def _pick_clip_with_master(self) -> str:
        """Return the id of a non-gap clip on the displayed record sequence
        whose underlying media has at least one master sequence — the
        precondition for F-key (MatchFrame) to load a source master."""
        info = self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            "local Sequence = require('models.sequence'); "
            "for _, c in ipairs(ts.get_tab_strip():displayed_clips()) do "
            "  if not c.is_gap and c.media_id then "
            "    local masters = Sequence.list_masters_for_media(c.media_id); "
            "    if masters and #masters > 0 then "
            "      return c.id "
            "    end "
            "  end "
            "end; "
            "error('no timeline clip in the fixture has an associated master sequence')")
        return info.strip('"')

    def test_01_grave_with_no_source_loaded_blanks_displayed_body(self) -> None:
        # Pristine fixture: nothing has loaded a source yet, so the
        # source monitor has no master. This is the (b) branch of the
        # original test — Grave-as-show-source from a no-source state
        # must blank the body, not auto-seed.
        self.ensure_record_tab()
        pre_kind = self.eval_str(
            "return tostring(require('core.debug_helpers').displayed_tab_kind())")
        self.assertEqual("record", pre_kind,
            f"setUp: displayed_tab_kind should be 'record' on a fresh "
            f"template; got {pre_kind!r}")

        # Confirm source viewer is genuinely empty — no master, no clip.
        sv_seq = self.eval_str(
            "return tostring(require('core.debug_helpers').source_viewer_sequence_id())")
        sv_clip = self.eval_str(
            "return tostring(require('core.debug_helpers').source_viewer_clip_id())")
        self.assertEqual("nil", sv_seq,
            f"setUp: source viewer should have no loaded master; got {sv_seq!r}")
        self.assertEqual("nil", sv_clip,
            f"setUp: source viewer should have no live-bound clip; got {sv_clip!r}")

        # Press Grave from the timeline scope — ToggleSourceRecordTab
        # with no source loaded takes the same blank-body branch as
        # ShowSourceTab's no-master branch.
        self.focus_panel("timeline")
        self.key("Grave")

        # Body is blanked: displayed_tab_kind goes nil and no clips are
        # rendered. The user chose nothing → the editor shows nothing.
        post_kind = self.eval_str(
            "return tostring(require('core.debug_helpers').displayed_tab_kind())")
        self.assertEqual("nil", post_kind, (
            f"no-source Grave/ShowSourceTab must blank the displayed tab "
            f"pointer; got displayed_tab_kind={post_kind!r}. TSO 2026-05-17 "
            f"retired the auto-seed-masters[1] path — the user picked no "
            f"source, so nothing should be shown."))
        post_clips = self.eval_int(
            "return require('core.debug_helpers').displayed_clips_count()")
        self.assertEqual(0, post_clips, (
            f"no-source blank state should render zero clips; got "
            f"{post_clips}. A non-zero count means something got "
            f"auto-seeded (the fabrication TSO 2026-05-17 banned)."))

        # And the source viewer itself was NOT auto-loaded with a master.
        post_sv_seq = self.eval_str(
            "return tostring(require('core.debug_helpers').source_viewer_sequence_id())")
        self.assertEqual("nil", post_sv_seq, (
            f"no-source Grave/ShowSourceTab must NOT auto-load a master "
            f"into the source monitor; got source_viewer_sequence_id="
            f"{post_sv_seq!r}."))

    def test_02_with_source_loaded_show_source_displays_source_tab(self) -> None:
        # Inherits the blanked state from test_01. Restore a record tab
        # so we can pick a timeline clip to load as a source master.
        # _reset_to_template gives us a clean record-displayed fixture
        # — the (a) branch needs a live source, and the cleanest path
        # is "pick a clip, press F to load its master, then Grave".
        self._reset_to_template()

        clip_id = self._pick_clip_with_master()

        # Select + F to load the clip's master into the source viewer.
        # After F, the displayed tab is already 'source' (see
        # test_f_key_source_load) — that itself satisfies behavior (a):
        # with a source loaded, the source tab is shown.
        self.click_clip(clip_id)
        self.focus_panel("timeline")
        self.key("F")

        kind_after_f = self.eval_str(
            "return tostring(require('core.debug_helpers').displayed_tab_kind())")
        self.assertEqual("source", kind_after_f, (
            f"after F loads a master, displayed_tab_kind should be 'source'; "
            f"got {kind_after_f!r}. If this fails, F-key dispatch broke — "
            f"unrelated to ShowSourceTab; see test_f_key_source_load."))

        # The displayed sequence is the loaded master, not the record
        # sequence — observable proof that the strip is showing source
        # content, the (a) contract.
        displayed_seq = self.eval_str(
            "return tostring(require('core.debug_helpers').displayed_sequence_id())")
        sv_master = self.eval_str(
            "return tostring(require('core.debug_helpers').source_viewer_sequence_id())")
        self.assertEqual(sv_master, displayed_seq, (
            f"source-tab displayed sequence ({displayed_seq}) must match "
            f"the source viewer's loaded master ({sv_master}). Divergence "
            f"means the strip is showing something other than the user's "
            f"chosen source — the (a) invariant of ShowSourceTab."))

    def test_03_re_show_with_same_source_is_idempotent(self) -> None:
        # Inherits source-tab-displayed state from test_02.
        sv_master_before = self.eval_str(
            "return tostring(require('core.debug_helpers').source_viewer_sequence_id())")
        self.assertNotEqual("nil", sv_master_before,
            "setUp: test_02 should have left a source loaded; got nil")

        # Grave back to record, then Grave again to re-show source —
        # the (c) re-open idempotency contract.
        self.focus_panel("timeline")
        self.key("Grave")
        kind_after_first = self.eval_str(
            "return tostring(require('core.debug_helpers').displayed_tab_kind())")
        self.assertEqual("record", kind_after_first, (
            f"first Grave with source loaded should swap displayed back to "
            f"record; got {kind_after_first!r}."))

        self.key("Grave")
        kind_after_second = self.eval_str(
            "return tostring(require('core.debug_helpers').displayed_tab_kind())")
        self.assertEqual("source", kind_after_second, (
            f"second Grave (source still loaded) should re-display source — "
            f"idempotent re-open. got {kind_after_second!r}."))

        sv_master_after = self.eval_str(
            "return tostring(require('core.debug_helpers').source_viewer_sequence_id())")
        self.assertEqual(sv_master_before, sv_master_after, (
            f"re-show must not change which master is loaded. "
            f"before={sv_master_before} after={sv_master_after}. "
            f"Any change means the toggle re-resolved the source instead "
            f"of just re-displaying it."))

        displayed_after = self.eval_str(
            "return tostring(require('core.debug_helpers').displayed_sequence_id())")
        self.assertEqual(sv_master_after, displayed_after, (
            f"re-shown source tab must display the same loaded master "
            f"({sv_master_after}); displayed={displayed_after}."))

if __name__ == "__main__":
    unittest.main()
