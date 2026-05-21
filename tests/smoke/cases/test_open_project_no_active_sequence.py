"""
Phase A regression — OpenProject must not crash on a .jvp without saved tab info.

``post_open_init``'s docstring promises ``sequence=nil`` is supported
("feature-010 no-active-sequence state — when the project carries no
``last_open_sequence_id``, ``Sequence.resolve_initial_for_project`` returns
``nil`` and the function must open blank"). The branches at the top of the
function honour that, but the trailing lines (``log.event`` +
``peak_cache.init_for_project`` + return-value construction) deref
``sequence`` unconditionally and crash.

Symptom in production: editor crashes on opening any .jvp that doesn't
carry tab state — surfaced today by the smoke runner against the
freshly-built Anamnesis template before this fix landed.

Domain assertion: drive OpenProject through the real command surface
against a project whose settings JSON is missing
``last_open_sequence_id`` / ``open_sequence_ids``; the command must return
``{success=true}`` (and the editor's panels must remain alive afterwards).

We construct the fixture in-test rather than ship a permanent .jvp:
clone the Anamnesis template, strip the two tab-state keys via sqlite3.

Run:
    python3 -m unittest tests.smoke.cases.test_open_project_no_active_sequence -v
"""

import json
import sqlite3
import shutil
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase


class TestOpenProjectNoActiveSequence(JVESmokeCase):
    """OpenProject must accept a project with no last_open_sequence_id."""

    def test_open_jvp_without_tab_state_succeeds(self) -> None:
        # Build a sibling .jvp from the template, then null its tab-state keys.
        src = self._fixtures.template_path
        dst = self._fixtures.scratch_root / f"no_tab__{self.id().replace('.', '_')}.jvp"
        for suffix in ("", "-wal", "-shm"):
            p = Path(str(dst) + suffix)
            if p.exists():
                p.unlink()
        shutil.copy(src, dst)

        # Strip the tab keys.
        conn = sqlite3.connect(str(dst))
        try:
            row = conn.execute("SELECT id, settings FROM projects").fetchone()
            self.assertIsNotNone(row, "fixture has no projects row")
            project_id, settings_json = row
            settings = json.loads(settings_json)
            settings.pop("last_open_sequence_id", None)
            settings.pop("open_sequence_ids", None)
            conn.execute(
                "UPDATE projects SET settings = ? WHERE id = ?",
                (json.dumps(settings), project_id))
            conn.commit()
        finally:
            conn.close()

        # Sanity: confirm the keys really are gone.
        verify = sqlite3.connect(str(dst))
        try:
            v_row = verify.execute("SELECT settings FROM projects").fetchone()
            v_settings = json.loads(v_row[0])
            self.assertNotIn("last_open_sequence_id", v_settings,
                "test setup: last_open_sequence_id should have been stripped")
            self.assertNotIn("open_sequence_ids", v_settings,
                "test setup: open_sequence_ids should have been stripped")
        finally:
            verify.close()

        # Drive OpenProject through the real command. With the bug, this
        # raises inside post_open_init's trailing block (sequence deref).
        # With the fix, it returns success and leaves the editor live.
        dst_lua = str(dst).replace("'", "\\'")
        ok = self.eval_bool(
            "local r = require('core.command_manager').execute('OpenProject', "
            f"{{ project_path = '{dst_lua}' }}); "
            "return r ~= nil and r.success == true")
        self.assertTrue(ok,
            "OpenProject on a tab-state-less .jvp must return {success=true} "
            "— the trailing block in post_open_init (open_project.lua ~line "
            "361) likely deref'd a nil sequence.")

        # Independent liveness check: a follow-up no-op socket round-trip
        # must succeed. If the OpenProject crashed JVE, this would fail
        # with a socket error before our assertion can run.
        self.assertEqual(2, self.eval_int("return 1 + 1"),
            "JVE socket dead after OpenProject — likely crashed")


if __name__ == "__main__":
    unittest.main()
