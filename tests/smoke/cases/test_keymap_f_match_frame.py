"""
``F`` (MatchFrame) — load the source viewer with the master sequence
of the clip strictly spanning the record playhead.

User-visible effect: pressing F when parked over a clip on the
timeline loads that clip's source media (master sequence) into the
source viewer, with the source viewer's playhead mapped to the same
source frame visible at the record playhead. Avid/Premiere
convention; canonical "show me where this came from" navigation.

Domain-level assertion: after pressing F, source_viewer's staged
sequence id equals the spanning clip's master sequence id.

Run:
    python3 -m unittest tests.smoke.cases.test_keymap_f_match_frame -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


SEED_OFFSET_INTO_CLIP = 24


class TestFMatchFrame(JVESmokeCase):

    def setUp(self) -> None:
        super().setUp()
        self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            "if ts.get_displayed_tab_kind() ~= 'record' then "
            "  local active = ts.get_active_sequence_id(); "
            "  if active then ts.switch_to_record_tab(active) end "
            "end")

    def test_f_loads_clips_master_into_source_viewer(self) -> None:
        # Pick a clip with sufficient body. We need both its master id
        # (target of the load) and its sequence_start to seed playhead.
        info = self.eval(
            "local ts = require('ui.timeline.timeline_state'); "
            "local rec_seq = require('core.playback.transport')"
            ".record_engine.loaded_sequence_id; "
            "assert(rec_seq, 'record engine has no loaded sequence'); "
            "local picked; "
            "for _, c in ipairs(ts.get_tab_strip():displayed_clips()) do "
            "  if not c.is_gap "
            "     and type(c.duration) == 'number' and c.duration > 48 "
            "     and c.sequence_id and c.sequence_id ~= '' then "
            "    picked = c; break "
            "  end "
            "end; "
            "assert(picked, 'fixture has no clip with a master sequence_id'); "
            "return string.format('%s|%d|%s|%s', "
            "  picked.id, picked.sequence_start, picked.sequence_id, rec_seq)")
        clip_id, seq_start, master_id, rec_seq = info.strip('"').split("|", 3)
        frame = int(seq_start) + SEED_OFFSET_INTO_CLIP

        self.eval(
            "require('core.command_manager').execute('SetPlayhead', "
            f"{{ sequence_id='{rec_seq}', playhead_position={frame} }})")

        self.focus_panel("timeline")
        self.assertEvalEqual("timeline",
            'return require("ui.focus_manager").get_focused_panel()',
            msg="focus did not anchor on timeline before F press")

        self.key("F")

        loaded_master = self.eval_str(
            "return require('ui.source_viewer').get_staged_seq_id() or ''")
        self.assertEqual(master_id, loaded_master, (
            f"after F press with playhead inside clip {clip_id}, source "
            f"viewer should be staged on the clip's master sequence "
            f"({master_id}). Got {loaded_master!r}. MatchFrame either "
            f"picked the wrong clip (resolve_clips_at_playhead) or "
            f"load_master_clip didn't reach get_staged_seq_id."))


if __name__ == "__main__":
    unittest.main()
