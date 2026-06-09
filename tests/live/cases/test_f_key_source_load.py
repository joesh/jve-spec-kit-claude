"""
F-key (MatchFrame) loads a clip's master into the source viewer as a
displayed-only tab swap — the active edit-target sequence is unchanged,
and the open-tab strip contains at most ONE source tab at a time
(singleton). A second F on a different clip replaces the prior source
tab rather than accumulating tabs.

Origin: tests/binding/test_015_f_key_source_load.lua. The Lua version
called source_viewer.load_master_clip() directly; this smoke drives the
behavior through a real F keystroke per MIGRATION_ANALYSIS.md (note:
"smoke rewrite — drive F-key via keyboard not direct call").

Behavior pinned (domain-level):
  - After F on a selected timeline clip: the displayed tab is a source
    tab while the active edit-target sequence is unchanged.
  - The tab strip holds exactly one source tab — pressing F on a
    second clip with a different master swaps, not stacks.
  - The record sequence's persisted playhead is not corrupted by the
    source-tab visit.

Run:
    python3 -m unittest tests.live.cases.test_f_key_source_load -v
"""

import unittest

from tests.live.runner.case import JVESmokeCase

class TestFKeySourceLoad(JVESmokeCase):
    """F-key MatchFrame loads master as a displayed-only source tab."""

    def _pick_clip_with_master(self, exclude_clip_id: str = "") -> tuple[str, str]:
        """Return (clip_id, master_sequence_id) for a non-gap clip on the
        displayed record sequence whose underlying media has a master
        sequence available. Optionally skip a previously-picked clip so
        the second pick lands on a different master.

        Returned values are domain identifiers used purely for picking
        the clip to click and for verifying displayed-sequence id after
        the F press."""
        info = self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            "local Sequence = require('models.sequence'); "
            "local Media = require('models.media'); "
            "local clips = ts.get_tab_strip():displayed_clips(); "
            "local exclude = '" + exclude_clip_id + "'; "
            "local seen_masters = {}; "
            "for _, c in ipairs(clips) do "
            "  if not c.is_gap and c.id ~= exclude and c.media_id then "
            "    local masters = Sequence.list_masters_for_media(c.media_id); "
            "    if masters and #masters > 0 then "
            "      local m = masters[1]; "
            "      if not seen_masters[m.id] then "
            "        return string.format('%s|%s', c.id, m.id) "
            "      end "
            "    end "
            "  end "
            "end; "
            "error('no timeline clip in the fixture has an associated master sequence')")
        clip_id, master_seq_id = info.strip('"').split("|", 1)
        return clip_id, master_seq_id

    def test_01_f_loads_master_as_source_tab_without_changing_active(self) -> None:
        # Pre-F snapshot: record tab displayed, active sequence is the
        # record sequence, source tab not yet open.
        pre_active = self.eval_str(
            "return tostring(require('core.debug_helpers').active_sequence_id())")
        pre_displayed = self.eval_str(
            "return tostring(require('core.debug_helpers').displayed_sequence_id())")
        self.assertEqual(pre_active, pre_displayed,
            f"pre-F precondition: displayed should equal active (record tab). "
            f"active={pre_active} displayed={pre_displayed}")
        pre_kind = self.eval_str(
            "return tostring(require('core.debug_helpers').displayed_tab_kind())")
        self.assertEqual("record", pre_kind,
            f"pre-F precondition: displayed_tab_kind should be 'record'; got {pre_kind!r}")

        clip_id, master_seq_id = self._pick_clip_with_master()

        # Select the clip via a real click on its visual center, then
        # anchor focus on the timeline so F is dispatched against the
        # right scope.
        self.click_clip(clip_id)
        self.focus_panel("timeline")
        self.assertEvalEqual("timeline",
            'return require("ui.focus_manager").get_focused_panel()',
            msg="focus did not anchor on timeline before F press")

        # Real OS keystroke — F is MatchFrame in keymaps/default.jvekeys.
        self.key("F")

        # Post-F: displayed swapped to the master (FR-005 — displayed-only
        # swap). active edit-target is unchanged.
        post_displayed = self.eval_str(
            "return tostring(require('core.debug_helpers').displayed_sequence_id())")
        self.assertEqual(master_seq_id, post_displayed, (
            f"F was expected to display the master ({master_seq_id}); "
            f"displayed is {post_displayed}. Either F didn't reach "
            f"MatchFrame (check suite.log for LUA CALLBACK ERROR) or "
            f"the displayed-tab swap regressed."))

        post_active = self.eval_str(
            "return tostring(require('core.debug_helpers').active_sequence_id())")
        self.assertEqual(pre_active, post_active, (
            f"FR-005 violation: F changed the active edit-target sequence. "
            f"pre={pre_active} post={post_active}. Source tab must be a "
            f"display-only swap; active must remain on the record sequence."))

        post_kind = self.eval_str(
            "return tostring(require('core.debug_helpers').displayed_tab_kind())")
        self.assertEqual("source", post_kind,
            f"after F, displayed_tab_kind should be 'source'; got {post_kind!r}")

        # Record sequence's persisted playhead must not be corrupted by
        # the source-tab visit. The Lua original caught a regression
        # where the record playhead ended up at >1M frames.
        rec_playhead = self.eval_int(
            f"return require('models.sequence').load('{pre_active}').playhead_position")
        self.assertLess(rec_playhead, 1000000, (
            f"record sequence playhead got corrupted by source-tab visit: "
            f"{rec_playhead} frames (>1M). Source viewer must not write "
            f"through to the record sequence's persisted playhead."))

    def test_02_second_f_replaces_source_tab_not_stacks(self) -> None:
        # Inherits the source-tab-displayed state from test_01.
        pre_tab_count = self.eval_int(
            "return require('core.debug_helpers').open_tabs_count()")

        # Pick a clip whose master differs from the one currently shown.
        current_source = self.eval_str(
            "return tostring(require('core.debug_helpers').displayed_sequence_id())")
        clip_id, new_master = self._pick_clip_with_master(exclude_clip_id="")
        if new_master == current_source:
            # First pick happened to land on the same master — try again
            # explicitly excluding any clip whose master is the current.
            info = self.eval(
                "local ts = require('ui.timeline.timeline_state'); "
                "local Sequence = require('models.sequence'); "
                "local clips = ts.get_tab_strip():displayed_clips(); "
                f"local current = '{current_source}'; "
                "for _, c in ipairs(clips) do "
                "  if not c.is_gap and c.media_id then "
                "    local masters = Sequence.list_masters_for_media(c.media_id); "
                "    if masters and #masters > 0 and masters[1].id ~= current then "
                "      return string.format('%s|%s', c.id, masters[1].id) "
                "    end "
                "  end "
                "end; "
                "error('fixture has no second clip with a different master — '"
                "      'cannot exercise source-tab replacement')")
            clip_id, new_master = info.strip('"').split("|", 1)

        # First, swap back to the record tab so the click lands on the
        # record-timeline clip, not on the currently-displayed source
        # tab's content.
        self.ensure_record_tab()
        self.click_clip(clip_id)
        self.focus_panel("timeline")

        self.key("F")

        post_tab_count = self.eval_int(
            "return require('core.debug_helpers').open_tabs_count()")
        self.assertEqual(pre_tab_count, post_tab_count, (
            f"FR-001 singleton violation: second F added a tab instead of "
            f"replacing the prior source tab. tab_count before={pre_tab_count} "
            f"after={post_tab_count}. Only one source tab may be open at a time."))

        post_displayed = self.eval_str(
            "return tostring(require('core.debug_helpers').displayed_sequence_id())")
        self.assertEqual(new_master, post_displayed, (
            f"after second F, displayed should be the new master "
            f"({new_master}); got {post_displayed}. The source tab did not "
            f"swap to the second clip's master."))

if __name__ == "__main__":
    unittest.main()
