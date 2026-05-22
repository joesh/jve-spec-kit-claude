"""
019 FR-003: Shift+F (OpenClipInSourceMonitor) must park the source-side
playhead at the loaded clip's source_in.

Manual repro (2026-05-21): "Shift+F doesn't necessarily end up with the
playhead in the right place." Symptom intermittent — sometimes lands at
clip.source_in, sometimes at the master source sequence's persisted
playhead_position (whatever the last operation on the master left
there).

source_viewer.load_clip's sequence today is:
  1. update_effective_source_live(clip)
  2. source:load_sequence(clip.sequence_id)   ← SequenceMonitor seeks
                                                  engine to master row's
                                                  saved playhead_position
  3. transport.bind_role_to_sequence("source", clip.sequence_id)
  4. source:seek_to_frame(clip.source_in)     ← intended final position

If anything between steps 2 and 4 reads the engine position and persists
it back, or if step 3 resets the engine in a way that overrides step 4,
the playhead ends up at the master's stale playhead_position instead of
the clip's source_in.

This test pins the contract: after load_clip, the playhead position
recorded on the master source sequence (which is what get_position()
reads / writes through) must equal clip.source_in, regardless of what
the master's previous playhead_position was.

Run:
    python3 -m unittest tests.smoke.cases.test_shift_f_parks_playhead_at_clip_source_in -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestShiftFParksPlayheadAtClipSourceIn(JVESmokeCase):
    """load_clip must seek source engine to clip.source_in, not master's row."""

    def test_load_clip_seeks_to_clip_source_in_regardless_of_master_playhead(self) -> None:
        # Find a clip with a non-zero source_in so the test distinguishes
        # source_in from "master's saved playhead = 0" by accident.
        info = self.eval(
            "local clips = require('ui.timeline.timeline_state').get_clips(); "
            "for _, c in ipairs(clips) do "
            "  if not c.is_gap "
            "     and type(c.source_in) == 'number' "
            "     and c.source_in > 10 "
            "     and type(c.source_out) == 'number' "
            "     and c.source_out > c.source_in + 1 then "
            "    return string.format('%s|%d|%s', c.id, c.source_in, c.sequence_id) "
            "  end "
            "end; "
            "error('no media clip with source_in > 10 in fixture')")
        clip_id, src_in_str, source_seq_id = info.strip('"').split('|', 2)
        expected_playhead = int(src_in_str)

        # Pollute the master source sequence's playhead_position with a
        # value far from clip.source_in. If load_clip's final seek
        # doesn't override this, the playhead ends up here.
        bogus_playhead = expected_playhead + 5000
        self.eval(
            f"local s = require('models.sequence').load('{source_seq_id}'); "
            f"s.playhead_position = {bogus_playhead}; "
            "assert(s:save())")

        # Load clip via OpenClipInSourceMonitor (the command Shift+F
        # actually dispatches), not source_viewer.load_clip directly —
        # tests the full keymap-equivalent path including command_manager.
        self.eval(
            "require('core.command_manager').execute('OpenClipInSourceMonitor', "
            f"{{ clip_id='{clip_id}', "
            "project_id=require('core.command_manager').get_active_project_id() })")

        self.assertEqual("live_bound_clip", self.eval_str(
            "return tostring(require('ui.source_viewer').get_mode())"),
            "setUp: load didn't enter live_bound_clip mode")

        # The source monitor's engine position is the runtime source of
        # truth for "where is the source-side playhead". Read it
        # directly — that's what the user sees on the source viewer.
        def engine_position() -> int:
            return self.eval_int(
                "local sm = require('ui.panel_manager')"
                ".get_sequence_monitor('source_monitor'); "
                "assert(sm and sm.engine, 'no source monitor engine'); "
                "return sm.engine:get_position()")

        actual_engine = engine_position()
        self.assertEqual(expected_playhead, actual_engine, (
            f"After OpenClipInSourceMonitor on clip {clip_id} "
            f"(source_in={expected_playhead}), source monitor's engine "
            f"position expected {expected_playhead}; got {actual_engine}. "
            f"Master source seq's pre-load playhead_position was "
            f"{bogus_playhead} — if the engine lands there instead, "
            f"some path in load_clip overrides the final seek_to_frame."))

        # ── Scenario 2: move source playhead away from clip.source_in,
        #    then re-load the same clip. Final position must still be
        #    clip.source_in (load_clip parks unconditionally, FR-003).
        moved_to = expected_playhead + 30
        self.eval(
            "local sm = require('ui.panel_manager')"
            ".get_sequence_monitor('source_monitor'); "
            f"sm.engine:seek({moved_to})")
        self.assertEqual(moved_to, engine_position(),
            "setUp: engine seek to moved position didn't land")

        self.eval(
            "require('core.command_manager').execute('OpenClipInSourceMonitor', "
            f"{{ clip_id='{clip_id}', "
            "project_id=require('core.command_manager').get_active_project_id() })")
        after_reload = engine_position()
        self.assertEqual(expected_playhead, after_reload, (
            f"Re-loading the same clip {clip_id} after the source-side "
            f"playhead was moved to {moved_to} expected to snap back to "
            f"clip.source_in={expected_playhead}; got {after_reload}. "
            f"load_clip's seek_to_frame must override the prior position."))

        # ── Scenario 3 (Joe's manual repro 2026-05-21): Shift+F, toggle
        #    source/record tab, move record playhead, Shift+F again.
        #    This is the exact flow where the bug intermittently shows.
        record_seq_id = self.eval_str(
            "return require('core.playback.transport').record_engine.loaded_sequence_id")

        # Step a: load clip live.
        self.eval(
            "require('core.command_manager').execute('OpenClipInSourceMonitor', "
            f"{{ clip_id='{clip_id}', "
            "project_id=require('core.command_manager').get_active_project_id() })")
        # Step b: toggle source/record tab (`).
        self.eval(
            "require('core.command_manager').execute('ToggleSourceRecordTab', "
            "{ project_id=require('core.command_manager').get_active_project_id() })")
        # Step c: move the RECORD playhead (the timeline-side one) away
        # from wherever it was. This is what the user does when they
        # navigate to a different point on the timeline.
        move_to = self.eval_int(
            f"return require('models.sequence').load('{record_seq_id}').start_timecode_frame + 100")
        self.eval(
            "require('core.command_manager').execute('SetPlayhead', "
            f"{{ sequence_id='{record_seq_id}', "
            "project_id=require('core.command_manager').get_active_project_id(), "
            f"playhead_position={move_to} }})")
        # Step d: Shift+F the same clip again.
        self.eval(
            "require('core.command_manager').execute('OpenClipInSourceMonitor', "
            f"{{ clip_id='{clip_id}', "
            "project_id=require('core.command_manager').get_active_project_id() })")
        after_joe_flow = engine_position()
        self.assertEqual(expected_playhead, after_joe_flow, (
            f"Joe's repro (Shift+F, toggle tab, move record playhead, "
            f"Shift+F again on clip {clip_id}, source_in={expected_playhead}): "
            f"expected source-monitor engine to land at "
            f"{expected_playhead}; got {after_joe_flow}. The record-side "
            f"playhead was moved to {move_to} between loads — if the "
            f"source engine got that value instead of clip.source_in, "
            f"some path crosses the source/record engine boundary "
            f"during load_clip."))


if __name__ == "__main__":
    unittest.main()
