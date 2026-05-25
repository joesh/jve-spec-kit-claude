"""
JVESmokeCase — unittest.TestCase base for smoke tests.

Owns one long-lived JVERunner for the entire TestCase subclass (or
TestSuite, via class-attribute sharing) — bring-up amortized across
every test method.

Pattern:

    from tests.smoke.runner.case import JVESmokeCase

    class TestKeymap_I_SourceMonitor(JVESmokeCase):
        def test_i_key_trims_loaded_clip_in(self):
            self.focus_source_monitor()
            self.eval('require("ui.source_viewer").load_clip("clip-id")')
            self.key("I")
            new_in = self.eval_int('return require("models.clip").load("clip-id").source_in')
            self.assertEqual(new_in, expected_in)

Lifecycle:
    setUpClass    → launch JVE once
    setUp         → open a fresh Anamnesis copy
    tearDownClass → shut JVE down

Failure isolation:
    If three consecutive evals time out OR JVE exits, the runner is
    respawned automatically and the current test is marked failed.
"""

import atexit
import unittest
from pathlib import Path
from typing import ClassVar, Optional

from tests.smoke.runner.jve_runner import (
    Fixtures, JVERunner, JVERunnerError, JVEEvalError,
)


# Module-level singleton: one JVE for the entire suite run, not per
# TestCase class. Per spec 020 phase1-test-overhaul.md: "One long-lived
# JVE serves the entire smoke suite; no per-test process spawn for the
# common case." Lazy-started on first setUpClass; shut down via atexit.
_singleton_runner: Optional[JVERunner] = None
_singleton_fixtures: Optional[Fixtures] = None


def _ensure_runner() -> tuple[JVERunner, Fixtures]:
    """Start the singleton JVE on first call; return cached refs after.

    Also respawns when the previously-cached runner has died (eval
    timeout in a prior test triggered force-shutdown). Without this,
    a single wedged test would cascade-error every subsequent test in
    the suite because the dead singleton stayed cached forever.

    Launches JVE with the Anamnesis template as the startup project so
    layout.lua takes the at-launch (open_and_init_project) path instead
    of the welcome-dialog branch. Welcome blocks the main Lua thread
    waiting for user action, which never comes in a headless test ―
    everything in layout.lua *after* the welcome loop (panel widgets,
    timeline_panel, the sequence_monitors record/source bind) never
    runs, and per-test OpenProject swaps then bind transport but can't
    chain through timeline_panel.load_sequence to bind record_engine.
    Starting with the template skips welcome entirely.
    """
    global _singleton_runner, _singleton_fixtures
    if _singleton_runner is not None and not _singleton_runner.is_alive():
        # Wedged in a prior test; drop the corpse so we respawn below.
        _singleton_runner = None
    if _singleton_runner is None:
        if _singleton_fixtures is None:
            _singleton_fixtures = Fixtures()
            atexit.register(_singleton_shutdown)
        _singleton_runner = JVERunner(
            startup_project=Path("/tmp/jve_smoke/template.jvp"),
            stdout_log=Path("/tmp/jve_smoke") / "suite.log")
        _singleton_runner.start()
        _singleton_runner.foreground()
    return _singleton_runner, _singleton_fixtures


def _singleton_shutdown() -> None:
    """atexit hook: tear down the suite-wide JVE on interpreter exit."""
    global _singleton_runner
    if _singleton_runner is not None:
        try:
            _singleton_runner.shutdown()
        finally:
            _singleton_runner = None


class JVESmokeCase(unittest.TestCase):
    """Base class. All subclasses share one long-lived JVE for the suite."""

    # Class-level aliases to the singleton, populated in setUpClass so
    # test methods can use self._runner / self._fixtures as before.
    _runner: ClassVar[Optional[JVERunner]] = None
    _fixtures: ClassVar[Optional[Fixtures]] = None

    runner: JVERunner  # alias for type-checking convenience

    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        # Touch the singleton early so first-class bring-up cost lands
        # in setUpClass instead of the first setUp. The singleton itself
        # is re-fetched per setUp — if a prior test wedged JVE, the
        # singleton was respawned and the cls-cached pointer is stale.
        _ensure_runner()

    # No tearDownClass: the suite-wide runner is owned by atexit. Per-
    # class teardown would kill JVE between TestCase classes — defeats
    # the long-lived design.

    def setUp(self) -> None:
        super().setUp()
        # Always re-resolve the runner: _ensure_runner returns the
        # current live singleton, respawning if the prior test killed
        # it via eval-timeout force-shutdown.
        self.runner, self._fixtures_inst = _ensure_runner()
        # Per-test fresh project copy. Foreground again in case a prior
        # test stole focus (osascript dialogs, modals, etc.).
        jvp = self._fixtures_inst.fresh_copy(self.id())
        self.runner.open_project(jvp)
        self.runner.foreground()

    # ─── convenience proxies (so test bodies don't say self.runner.X) ──

    def eval(self, lua: str) -> str:
        return self.runner.eval(lua)

    def eval_int(self, lua: str) -> int:
        return self.runner.eval_int(lua)

    def eval_str(self, lua: str) -> str:
        return self.runner.eval_str(lua)

    def eval_bool(self, lua: str) -> bool:
        return self.runner.eval_bool(lua)

    def key(self, combo: str) -> None:
        self.runner.key(combo)

    def click(self, x: int, y: int, double: bool = False) -> None:
        self.runner.click(x, y, double=double)

    def focus_panel(self, panel_id: str) -> None:
        """Force keyboard focus to the named panel by id.

        Calls focus_manager.focus_panel directly. Use sparingly —
        Smoke tests should prefer real focus shifts via mouse click —
        but it's the right tool when the test is targeting a key, not
        the focus mechanism itself.
        """
        self.eval(
            f"require('ui.focus_manager').focus_panel('{panel_id}')")

    # ─── assertion helpers ─────────────────────────────────────────────

    def assertEvalEqual(self, expected, lua: str, msg: Optional[str] = None) -> None:
        """Assert that ``self.eval(lua)`` parses to ``expected``.

        Type-dispatches on ``expected`` to pick the right parser
        (int/bool/str). Avoid raw assertEqual on self.eval() strings —
        the repr quoting confuses string comparisons.
        """
        if isinstance(expected, bool):
            self.assertEqual(self.eval_bool(lua), expected, msg=msg)
        elif isinstance(expected, int):
            self.assertEqual(self.eval_int(lua), expected, msg=msg)
        elif isinstance(expected, str):
            self.assertEqual(self.eval_str(lua), expected, msg=msg)
        else:
            raise TypeError(
                f"assertEvalEqual: unsupported expected type {type(expected).__name__}")
