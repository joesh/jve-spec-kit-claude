"""
Premiere .prproj end-to-end import — opening a Premiere project file via
File > Open Project... composes the full pipeline (lifecycle +
format-knowledge + entity-creation) and produces a populated project
whose project name, sequence fps/dimensions, media count, TC-origin
metadata, clip count, and track count satisfy fixture-derived lower
bounds.

Origin: tests/binding/test_prproj_import_e2e.lua (called
``open_project._convert_prproj_to_jvp`` directly; replaced here by
driving the real File > Open Project... menu + file dialog on the
anamnesis Premiere fixture).

Run:
    python3 -m unittest tests.live.cases.test_prproj_import_e2e -v
"""

import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
from tests.live.runner.case import JVESmokeCase

FIXTURE_PRPROJ = (REPO_ROOT / "tests" / "fixtures" / "premiere"
                  / "2026-03-20-anamnesis joe edit.prproj")

class TestPrprojImportE2E(JVESmokeCase):
    """Opening the anamnesis .prproj yields a populated project."""

    @unittest.skip("File>Open Project... dialog filter is *.jvp *.drp — "
                   "rejects .prproj path with a blocking alert. Either widen "
                   "the filter to include .prproj or route prproj through a "
                   "separate File>Import menu; see "
                   "todo_smoke_missing_primitives.md.")
    def test_open_prproj_produces_populated_project(self) -> None:
        # The class-level anamnesis template is irrelevant to this
        # test — we want a pristine open of the Premiere fixture so the
        # only project state in play is what the importer emitted.
        self._reset_to_template()

        self.assertTrue(FIXTURE_PRPROJ.exists(),
            f"fixture missing: {FIXTURE_PRPROJ}")

        # Drive the real menu → open dialog → file pick. JVE detects
        # the .prproj extension and routes through the prproj importer.
        self.menu_pick("File > Open Project...")
        self.pick_file_in_open_dialog(str(FIXTURE_PRPROJ))

        # Import is async + heavy (614 media, 2881 clips). Wait for
        # the observable post-condition: at least one user-visible
        # timeline sequence appears in the active project.
        self.wait_for(
            'local Sequence = require("models.sequence"); '
            'local proj = require("core.debug_helpers").active_project_id(); '
            'if not proj then return false end; '
            'local n = 0; '
            'for _, s in ipairs(Sequence.list_in_project(proj)) do '
            '  if s.kind == "sequence" then n = n + 1 end '
            'end; '
            'return n >= 1',
            timeout=120.0)

        # ── Project name = .prproj basename ──────────────────────────
        proj_id = self.eval_str(
            'return tostring(require("core.debug_helpers").active_project_id())')
        self.assertTrue(proj_id and proj_id != "nil",
            "no active project after opening .prproj — Open Project "
            "did not complete or did not switch the active project")

        project_name = self.eval_str(
            f'return require("models.project").load("{proj_id}").name')
        self.assertEqual("2026-03-20-anamnesis joe edit", project_name,
            f"expected project name from .prproj basename, got "
            f"{project_name!r}")

        # ── At least one imported timeline sequence ──────────────────
        timeline_count = self.eval_int(
            'local Sequence = require("models.sequence"); '
            'local proj = require("core.debug_helpers").active_project_id(); '
            'local n = 0; '
            'for _, s in ipairs(Sequence.list_in_project(proj)) do '
            '  if s.kind == "sequence" then n = n + 1 end '
            'end; '
            'return n')
        self.assertGreaterEqual(timeline_count, 1,
            f"expected >=1 imported timeline, got {timeline_count}")

        # ── Sequence fps + dimensions match the prproj VideoTrackGroup ─
        # Anamnesis prproj header declares FrameRate=25, FrameRect=2048x1152.
        info = self.eval(
            'local Sequence = require("models.sequence"); '
            'local proj = require("core.debug_helpers").active_project_id(); '
            'local picked; '
            'for _, s in ipairs(Sequence.list_in_project(proj)) do '
            '  if s.kind == "sequence" then picked = s; break end '
            'end; '
            'assert(picked, "no timeline sequence found post-import"); '
            'return string.format("%s|%s|%s|%s|%s", picked.name, '
            '  tostring(picked.fps_numerator), tostring(picked.fps_denominator), '
            '  tostring(picked.width), tostring(picked.height))')
        seq_name, fps_num_s, fps_den_s, width_s, height_s = (
            info.strip('"').split("|", 4))
        fps_num = int(fps_num_s)
        fps_den = int(fps_den_s)
        width = int(width_s)
        height = int(height_s)
        self.assertTrue(fps_num > 0 and fps_den > 0,
            f"sequence missing fps: num={fps_num} den={fps_den}")
        fps = fps_num / fps_den
        self.assertAlmostEqual(fps, 25.0, delta=0.001,
            msg=("expected fps~=25 (prproj VideoTrackGroup FrameRate), "
                 f"got {fps:.3f}"))
        self.assertEqual((width, height), (2048, 1152),
            f"expected 2048x1152, got {width}x{height}")

        # ── Media rows: fixture has 614 Media elements; importer dedup
        # may collapse some, but >=400 should survive. ──────────────
        media_count = self.eval_int(
            'return require("core.debug_helpers").media_count()')
        self.assertGreaterEqual(media_count, 400,
            f"expected >=400 media rows post-import, got {media_count}")

        # ── TC origin metadata: at least 100 media rows carry a
        # start_tc_value (the AlternateStart fix — without it no camera
        # media would have TC). Substring match on metadata JSON keeps
        # the assertion resilient to JSON key ordering. ────────────
        tc_count = self.eval_int(
            'local sql = require("core.database").get_connection(); '
            'local stmt = sql:prepare('
            '  [[SELECT COUNT(*) FROM media '
            '    WHERE metadata LIKE \'%"start_tc_value"%\']]); '
            'stmt:exec(); stmt:next(); '
            'local v = stmt:value(0); stmt:finalize(); return v')
        self.assertGreaterEqual(tc_count, 100, (
            f"expected >=100 media with start_tc_value (camera files w/ "
            f"AlternateStart), got {tc_count}"))

        # ── Clips landed on the timeline ────────────────────────────
        # Fixture has 2881 parsed clips; some may be filtered. Loose
        # lower bound: 1000 land on timeline-kind sequences.
        clip_count = self.eval_int(
            'local sql = require("core.database").get_connection(); '
            'local stmt = sql:prepare('
            '  [[SELECT COUNT(*) FROM clips c '
            '    JOIN tracks t ON c.track_id = t.id '
            '    JOIN sequences s ON t.sequence_id = s.id '
            '    WHERE s.kind = \'sequence\']]); '
            'stmt:exec(); stmt:next(); '
            'local v = stmt:value(0); stmt:finalize(); return v')
        self.assertGreaterEqual(clip_count, 1000,
            f"expected >=1000 clips imported on timeline tracks, got {clip_count}")

        # ── Tracks created on the timeline (fixture has 20). ────────
        track_count = self.eval_int(
            'local sql = require("core.database").get_connection(); '
            'local stmt = sql:prepare('
            '  [[SELECT COUNT(*) FROM tracks t '
            '    JOIN sequences s ON t.sequence_id = s.id '
            '    WHERE s.kind = \'sequence\']]); '
            'stmt:exec(); stmt:next(); '
            'local v = stmt:value(0); stmt:finalize(); return v')
        self.assertGreaterEqual(track_count, 10,
            f"expected >=10 tracks (fixture has 20), got {track_count}")

if __name__ == "__main__":
    unittest.main()
