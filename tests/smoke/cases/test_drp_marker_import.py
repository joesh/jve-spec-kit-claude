"""
DRP import persists per-clip markers with exact fidelity.

Pins the domain behavior: when a project is imported from a DRP, the
markers a user placed on a timeline clip in DaVinci Resolve come across —
drawn on that clip with the same frame, color, name, note, duration
(span), and custom_data. Fixture `markers_16color_edge.drp` carries one
marker of each of Resolve's 16 colors plus edge cases (empty note,
empty custom data) on its third clip ("countdown_chirp_30s.mp4");
`.truth.json` records exactly what was entered in Resolve.

Origin: tests/binding/test_drp_marker_import.lua. Drives the real
File > Import > Resolve Project (.drp)... menu path through the file
picker and inspects persisted markers via the ClipMarker model (a
read-only query — no mutation from the test body).

# TODO: needs read-only debug_helpers query for clip_markers rows
#       (e.g. clip_markers_for_clip(clip_id) returning the row list)
#       — see MIGRATION_ANALYSIS.md (Group A). Until then this smoke
#       reads via `models.clip_marker.find_by_clip` in an `eval`,
#       which is read-only (allowed by the authoring rules) but
#       longer than ideal.

Run:
    python3 -m unittest tests.smoke.cases.test_drp_marker_import -v
"""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURE = REPO_ROOT / "tests/fixtures/resolve/markers_16color_edge.drp"
TRUTH = REPO_ROOT / "tests/fixtures/resolve/markers_16color_edge.truth.json"


class TestDRPMarkerImport(JVESmokeCase):
    """DRP import round-trips every marker on the countdown clip."""

    def test_drp_import_persists_per_clip_markers(self) -> None:
        # ---- 1. Import the marker-bearing DRP through the real menu. ----
        self.menu_pick("File > Import > Resolve Project (.drp)...")
        self.pick_file_in_open_dialog(str(FIXTURE))

        # Import is async; wait for media to land. The fixture project
        # carries non-zero media; once those rows appear the importer
        # has finished its sequence/clip/marker writes too.
        self.wait_for(
            "return require('core.debug_helpers').media_count() > 0",
            timeout=30.0)

        # ---- 2. Find the countdown clip (third clip on its sequence). ----
        # Name match mirrors the SQL `LIKE '%countdown%'` from the
        # source Lua test.
        clip_id = self.eval_str(
            "local Clip = require('models.clip'); "
            "local rows = Clip.list_where(\"name LIKE '%countdown%'\"); "
            "assert(rows and #rows > 0, "
            "       'no countdown clip after DRP import — importer dropped clip rows'); "
            "return rows[1].id")

        # ---- 3. Query persisted markers for that clip (read-only). ----
        raw = self.eval_str(
            "local CM = require('models.clip_marker'); "
            "local dkjson = require('dkjson'); "
            f"local list = CM.find_by_clip('{clip_id}'); "
            "assert(list, 'find_by_clip returned nil'); "
            "local out = {}; "
            "for _, m in ipairs(list) do "
            "  assert(m.note ~= nil, "
            "    'marker.note is NULL — empty-string contract violated for marker at frame ' .. tostring(m.frame)); "
            "  assert(m.custom_data ~= nil, "
            "    'marker.custom_data is NULL — empty-string contract violated for marker at frame ' .. tostring(m.frame)); "
            "  out[#out+1] = { frame = m.frame, duration = m.duration, "
            "                  color = m.color, name = m.name, "
            "                  note = m.note, custom_data = m.custom_data } "
            "end; "
            "return dkjson.encode(out)")
        persisted = json.loads(raw)
        by_frame = {m["frame"]: m for m in persisted}

        # ---- 4. Load truth ----
        truth = json.loads(TRUTH.read_text())

        # ---- 5. Assert: every entered marker round-tripped through import. ----
        def check(expected: dict) -> None:
            frame = expected["frame"]
            got = by_frame.get(frame)
            self.assertIsNotNone(got,
                f"no persisted marker at frame {frame} — import dropped it")
            for field, want in (
                ("color", expected["color"]),
                ("name", expected["name"]),
                ("note", expected["note"]),
                ("duration", expected["duration"]),
                ("custom_data", expected.get("customData", "")),
            ):
                self.assertEqual(got[field], want, (
                    f"frame {frame}: {field} = {got[field]!r}, "
                    f"expected {want!r} — DRP marker field did not "
                    f"survive parse+import+persist round trip"))

        for c in truth["colors"]:  # all 16 colors
            check(c)
        edge_added = 0
        for e in truth["edge"]:
            if e.get("added"):
                check(e)
                edge_added += 1

        expected_total = 16 + edge_added
        self.assertEqual(len(persisted), expected_total, (
            f"countdown clip persisted {len(persisted)} markers, "
            f"expected {expected_total} — importer is dropping or "
            f"duplicating markers"))

        # Duration (span) markers: colors are duration 3, edges duration 5.
        spans = sum(1 for m in persisted if m["duration"] > 1)
        self.assertEqual(spans, expected_total, (
            f"expected all {expected_total} markers to be duration "
            f"spans (>1), got {spans} — span/duration field lost in import"))

        # Empty note + empty custom data must persist as "" (not NULL,
        # not dropped). Frame 400 has empty note + non-empty custom_data;
        # frame 420 has empty custom_data + non-empty note.
        empty_note = by_frame.get(400)
        self.assertIsNotNone(empty_note, "empty-note marker (frame 400) missing")
        self.assertEqual(empty_note["note"], "",
            "empty-note marker (frame 400) did not round-trip — note non-empty")
        self.assertEqual(empty_note["custom_data"], "hascd",
            "empty-note marker (frame 400): custom_data lost")

        empty_cd = by_frame.get(420)
        self.assertIsNotNone(empty_cd, "empty-custom-data marker (frame 420) missing")
        self.assertEqual(empty_cd["custom_data"], "",
            "empty-custom-data marker (frame 420) did not round-trip — custom_data non-empty")
        self.assertEqual(empty_cd["note"], "hasnote",
            "empty-custom-data marker (frame 420): note lost")


if __name__ == "__main__":
    unittest.main()
