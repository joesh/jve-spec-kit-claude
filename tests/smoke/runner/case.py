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

import unittest
from pathlib import Path
from typing import ClassVar, Optional

from tests.smoke.runner.jve_runner import (
    Fixtures, JVERunner, JVERunnerError, JVEEvalError,
)


class JVESmokeCase(unittest.TestCase):
    """Base class. Subclasses get a shared long-lived JVE."""

    # Class-level: one process for the whole subclass.
    _runner: ClassVar[Optional[JVERunner]] = None
    _fixtures: ClassVar[Optional[Fixtures]] = None

    # Per-test (set in setUp).
    runner: JVERunner  # alias for type-checking convenience

    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        cls._fixtures = Fixtures()
        # Launch JVE without a startup project; the welcome screen is fine —
        # setUp opens a fresh Anamnesis copy before every test.
        cls._runner = JVERunner(
            stdout_log=Path("/tmp/jve_smoke") / f"{cls.__name__}.log")
        cls._runner.start()
        cls._runner.foreground()

    @classmethod
    def tearDownClass(cls) -> None:
        if cls._runner is not None:
            try:
                cls._runner.shutdown()
            finally:
                cls._runner = None
        super().tearDownClass()

    def setUp(self) -> None:
        super().setUp()
        assert self._runner is not None, "setUpClass did not run"
        self.runner = self._runner
        # Per-test fresh project copy. Foreground again in case a prior
        # test stole focus (osascript dialogs, modals, etc.).
        jvp = self._fixtures.fresh_copy(self.id())
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
        """Force keyboard focus to the named panel by name.

        Reaches into the panel_manager to set the active scope without
        relying on a real mouse click landing on the panel's widget.
        Use sparingly — Smoke tests should prefer real focus shifts —
        but it's the right tool when the test is targeting a key, not
        the focus mechanism.
        """
        self.eval(
            f"require('ui.focus_manager').set_focus_scope('{panel_id}')")

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
