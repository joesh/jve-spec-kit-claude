"""
Source viewer publishes selections into selection_hub under the
``source_monitor`` panel so the Inspector renders the right schema
(timeline-typed for staged master loads, clip-typed for live-bound).
Origin: tests/integration/test_source_viewer_publishes_selection.lua.

Domain behavior pinned:
  * F (MatchFrame) → staged-mode load: selection_hub broadcasts a
    single item under panel "source_monitor" with item_type="timeline"
    carrying the master's sequence_id + project_id.
  * A second F on a different clip's master REPLACES (no accumulation).
  * Shift+F (OpenClipInSourceMonitor) → live-bound load: selection_hub
    broadcasts a single clip-typed item carrying clip_id, project_id,
    and the OWNER sequence_id (not the clip's source sequence_id).

NOTE: the originating Lua test also pinned "unload clears selection".
There is no keyboard-reachable unload primitive in keymaps today (no
binding, no menu entry surfaced through the smoke harness), so the
unload branch is left as a TODO below — the underlying executor path
is the same code, but the smoke-via-real-input rule requires waiting
for a real entry point. See MIGRATION_ANALYSIS.md entry for this
file.

Run:
    python3 -m unittest tests.smoke.cases.test_source_viewer_publishes_selection -v
"""

import unittest

from tests.smoke.runner.case import JVESmokeCase

class TestSourceViewerPublishesSelection(JVESmokeCase):
    """Source viewer publishes typed items into selection_hub."""

    # ── helpers ────────────────────────────────────────────────────────

    def _pick_clip_with_master(self, exclude_master_id: str = "") -> tuple[str, str]:
        """Pick a non-gap timeline clip whose media has at least one
        master sequence available. Returns ``(clip_id, master_seq_id)``.
        Optionally skip any clip whose master matches ``exclude_master_id``.
        """
        info = self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            "local Sequence = require('models.sequence'); "
            "local clips = ts.get_tab_strip():displayed_clips(); "
            "local exclude = '" + exclude_master_id + "'; "
            "for _, c in ipairs(clips) do "
            "  if not c.is_gap and c.media_id then "
            "    local masters = Sequence.list_masters_for_media(c.media_id); "
            "    if masters and #masters > 0 and masters[1].id ~= exclude then "
            "      return string.format('%s|%s', c.id, masters[1].id) "
            "    end "
            "  end "
            "end; "
            "error('no timeline clip with an associated master sequence in fixture')")
        clip_id, master_seq_id = info.strip('"').split("|", 1)
        return clip_id, master_seq_id

    def _pick_interior_clip(self) -> tuple[str, int]:
        """Pick a clip wide enough that parking the playhead 5 frames
        inside it lands unambiguously on that clip. Returns
        ``(clip_id, mid_frame)``."""
        info = self.eval(
            "local clips = require('ui.timeline.timeline_state')"
            ".get_tab_strip():displayed_clips(); "
            "for _, c in ipairs(clips) do "
            "  if not c.is_gap and c.duration >= 10 then "
            "    return string.format('%s|%d', c.id, c.sequence_start + 5) "
            "  end "
            "end; "
            "error('no interior clip with duration >= 10 in fixture')")
        clip_id, mid_str = info.strip('"').split("|", 1)
        return clip_id, int(mid_str)

    def _selection_count_for_source_monitor(self) -> int:
        return self.eval_int(
            "local items = require('ui.selection_hub')"
            ".get_selection('source_monitor'); "
            "return type(items) == 'table' and #items or -1")

    def _source_monitor_item_field(self, index: int, field: str) -> str:
        """Read a field on the i-th item published under source_monitor.
        Returns ``tostring(value)`` to survive eval transport."""
        return self.eval_str(
            "local items = require('ui.selection_hub')"
            ".get_selection('source_monitor'); "
            f"local it = items and items[{index}]; "
            "assert(it, 'no item at index "
            f"{index}" "'); "
            f"return tostring(it.{field})")

    # ── tests ──────────────────────────────────────────────────────────

    def test_01_f_staged_load_publishes_timeline_typed_item(self) -> None:
        """F on a clip with an available master publishes a single
        ``item_type='timeline'`` item under ``source_monitor``."""
        # Pre-state: record tab displayed.
        self.ensure_record_tab()
        proj = self.eval_str(
            "return require('core.command_manager').get_active_project_id()")

        clip_id, master_seq = self._pick_clip_with_master()

        # Real-input setup: click clip to select, focus timeline, press F.
        self.click_clip(clip_id)
        self.focus_panel("timeline")
        self.key("F")

        # Wait for the source tab to take over the display — confirms the
        # staged-mode load actually happened (vs no-op silently).
        self.wait_for(
            "return require('core.debug_helpers').displayed_sequence_id() == "
            f"'{master_seq}'",
            timeout=5.0)

        # Selection_hub must hold exactly one item under "source_monitor".
        count = self._selection_count_for_source_monitor()
        self.assertEqual(1, count, (
            "after F staged-mode load, selection_hub source_monitor "
            f"panel must hold exactly one item; got {count}. If 0, the "
            "publish never fired; if >1, prior selection wasn't replaced."))

        # Item shape: timeline-typed, carrying master seq + project.
        item_type = self._source_monitor_item_field(1, "item_type")
        seq_id = self._source_monitor_item_field(1, "sequence_id")
        proj_id = self._source_monitor_item_field(1, "project_id")
        self.assertEqual("timeline", item_type, (
            f"staged publish item_type must be 'timeline'; got {item_type!r}. "
            "Inspector would render the wrong schema."))
        self.assertEqual(master_seq, seq_id, (
            f"staged publish sequence_id must be the master ({master_seq}); "
            f"got {seq_id!r}."))
        self.assertEqual(proj, proj_id, (
            f"staged publish project_id must be active project ({proj}); "
            f"got {proj_id!r}."))

    def test_02_second_f_replaces_selection_no_accumulation(self) -> None:
        """A second F on a clip whose master differs from the currently-
        loaded source must REPLACE the published item — selection_hub
        source_monitor never accumulates."""
        # Inherits state from test_01 (a source tab is displayed).
        current_source = self.eval_str(
            "return tostring(require('core.debug_helpers').displayed_sequence_id())")

        # Swap back to record tab so the next click lands on record clips.
        self.ensure_record_tab()
        clip_id, new_master = self._pick_clip_with_master(
            exclude_master_id=current_source)

        self.click_clip(clip_id)
        self.focus_panel("timeline")
        self.key("F")

        self.wait_for(
            "return require('core.debug_helpers').displayed_sequence_id() == "
            f"'{new_master}'",
            timeout=5.0)

        # Still exactly one item — replacement, not accumulation.
        count = self._selection_count_for_source_monitor()
        self.assertEqual(1, count, (
            f"second F must REPLACE the source_monitor publish; got {count} "
            "items. >1 means selection_hub is accumulating staged loads."))

        seq_id = self._source_monitor_item_field(1, "sequence_id")
        self.assertEqual(new_master, seq_id, (
            f"second F replaced publish should carry the new master "
            f"({new_master}); got sequence_id={seq_id!r}. Replacement is "
            "broken or the publish is stale."))

    def test_03_shift_f_live_bound_publishes_clip_typed_with_owner(self) -> None:
        """Shift+F on a clip under the playhead enters live-bound mode
        and publishes a clip-typed item whose ``sequence_id`` is the
        OWNER (record) sequence, not the clip's source sequence."""
        # Inherits state — but we need the record tab displayed so the
        # playhead seek lands on the record sequence and Shift+F resolves
        # against the right clip.
        self.ensure_record_tab()

        owner_seq = self.eval_str(
            "local sid = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(type(sid) == 'string' and sid ~= '', "
            "       'record engine has no loaded sequence — fixture broken'); "
            "return sid")
        proj = self.eval_str(
            "return require('core.command_manager').get_active_project_id()")

        clip_id, mid_frame = self._pick_interior_clip()
        self.move_playhead_to(mid_frame)
        self.focus_panel("timeline")
        self.key("Shift+F")

        # Confirm live-bound mode actually engaged before we read the publish.
        self.wait_for(
            "return tostring(require('ui.source_viewer').get_mode()) "
            "== 'live_bound_clip'",
            timeout=5.0)

        count = self._selection_count_for_source_monitor()
        self.assertEqual(1, count, (
            f"after Shift+F live-bound load, source_monitor must hold "
            f"exactly one item; got {count}."))

        item_type = self._source_monitor_item_field(1, "item_type")
        published_clip = self._source_monitor_item_field(1, "clip_id")
        published_seq = self._source_monitor_item_field(1, "sequence_id")
        published_proj = self._source_monitor_item_field(1, "project_id")

        self.assertEqual("clip", item_type, (
            f"live-bound publish item_type must be 'clip'; got {item_type!r}. "
            "Inspector would render the sequence schema instead of the "
            "clip schema."))
        self.assertEqual(clip_id, published_clip, (
            f"live-bound publish must carry clip_id={clip_id}; got "
            f"{published_clip!r}."))
        self.assertEqual(proj, published_proj, (
            f"live-bound publish project_id must match active project "
            f"({proj}); got {published_proj!r}."))
        self.assertEqual(owner_seq, published_seq, (
            f"live-bound publish sequence_id must be the OWNER sequence "
            f"({owner_seq}), NOT the clip's source sequence. Got "
            f"{published_seq!r}. If this is the clip's source sequence, the "
            "publish is leaking source-side identity into a slot the "
            "Inspector treats as owner."))

    # TODO: needs `unload source viewer` primitive — no keyboard
    # binding or menu entry currently surfaced through smokes. The Lua
    # original asserted that source_viewer.unload() clears the
    # source_monitor selection. Add a real-input entry point (binding
    # or menu pick) then re-enable this method.
    @unittest.skip("needs source-viewer unload primitive (no keybinding)")
    def test_04_unload_clears_source_monitor_selection(self) -> None:
        pass

if __name__ == "__main__":
    unittest.main()
