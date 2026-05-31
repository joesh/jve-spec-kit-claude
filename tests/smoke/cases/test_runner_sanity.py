"""
runner sanity smoke — proves the long-lived JVE + socket + key delivery
chain works end-to-end without needing the Anamnesis template fixture.

Runs entirely against the welcome-screen state (no project loaded).
This is the test you run first on a fresh checkout to verify that
spec 020's primitive + the Python runner are wired correctly. Once
this passes, the rest of the smoke suite (which DOES need the
Anamnesis template) is unblocked.

Run:
    python3 -m unittest tests.smoke.cases.test_runner_sanity -v
"""

import os
import unittest
from pathlib import Path

# Allow direct invocation (`python3 path/to/this.py`) without env tweaking.
from tests.smoke.runner.jve_runner import (  # noqa: E402
    JVERunner, JVEEvalError, JVERunnerError,
)

class TestRunnerSanity(unittest.TestCase):
    """Bypasses JVESmokeCase — no per-test OpenProject. Just the runner."""

    @classmethod
    def setUpClass(cls) -> None:
        Path("/tmp/jve_smoke").mkdir(exist_ok=True)
        cls.runner = JVERunner(
            socket_path="/tmp/jve_smoke_sanity.sock",
            stdout_log=Path("/tmp/jve_smoke/sanity.log"),
        )
        cls.runner.start()

    @classmethod
    def tearDownClass(cls) -> None:
        if getattr(cls, "runner", None) is not None:
            cls.runner.shutdown()

    # ─── wire protocol ─────────────────────────────────────────────────

    def test_expression_eval(self) -> None:
        self.assertEqual(self.runner.eval("return 1 + 1"), "2")

    def test_statement_then_return(self) -> None:
        self.assertEqual(self.runner.eval("x = 5; return x * 2"), "10")

    def test_lua_version(self) -> None:
        # debug_terminal's repr quotes the string.
        self.assertEqual(self.runner.eval("return _VERSION"), '"Lua 5.1"')

    def test_module_require_returns_table(self) -> None:
        self.assertEqual(
            self.runner.eval('return type(require("core.command_manager"))'),
            '"table"')

    def test_parse_error_surfaces(self) -> None:
        with self.assertRaises(JVEEvalError) as cm:
            self.runner.eval("return @@")
        self.assertIn("unexpected symbol", cm.exception.lua_message)

    def test_runtime_error_surfaces(self) -> None:
        with self.assertRaises(JVEEvalError) as cm:
            self.runner.eval('error("nope")')
        self.assertIn("nope", cm.exception.lua_message)

    def test_empty_input(self) -> None:
        self.assertEqual(self.runner.eval(""), "")
        # Server stays responsive after an empty line.
        self.assertEqual(self.runner.eval("return 7"), "7")

    def test_string_repr_unescape(self) -> None:
        # Verify the runner's repr-string unescape matches the C++ side's
        # escape table (debug_terminal.cpp::appendEscaped).
        self.assertEqual(
            self.runner.eval_str('return "line1\\nline2\\ttab\\\\back"'),
            "line1\nline2\ttab\\back")

    def test_int_helper(self) -> None:
        self.assertEqual(self.runner.eval_int("return 42"), 42)
        self.assertEqual(self.runner.eval_int("return -7"), -7)

    def test_bool_helper(self) -> None:
        self.assertTrue(self.runner.eval_bool("return 1 == 1"))
        self.assertFalse(self.runner.eval_bool("return 1 == 2"))

    # ─── runner state ──────────────────────────────────────────────────

    def test_is_alive(self) -> None:
        self.assertTrue(self.runner.is_alive())

    def test_eval_after_eval(self) -> None:
        # Wire framing survives many round-trips.
        for i in range(50):
            self.assertEqual(self.runner.eval_int(f"return {i} * 2"), i * 2)

if __name__ == "__main__":
    unittest.main()
