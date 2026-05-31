"""
``Shift+F12`` (ToggleProfiler) — start or stop the LuaJIT sampling
profiler.

Per ``core/lua_profiler.lua``: press starts profiling; another press
stops + writes a sampling report to disk.

Domain-level assertion: press flips ``lua_profiler.is_running()``
symmetrically: false→true→false.

Run:
    python3 -m unittest tests.smoke.cases.test_keymap_shift_f12_toggle_profiler -v
"""

import unittest

from tests.smoke.runner.case import JVESmokeCase

class TestShiftF12TogglesProfiler(JVESmokeCase):

    def _running(self) -> bool:
        return self.eval_bool(
            "return require('core.lua_profiler').is_running()")

    def test_shift_f12_starts_then_stops_profiler(self) -> None:
        # Anchor on timeline — Shift+F12 is global scope so focus
        # doesn't matter for dispatch, but a known focus stabilises
        # the press across the suite.
        self.focus_panel("timeline")

        # Ensure starting-from-stopped baseline. The runner's
        # singleton JVE may have left the profiler running from a
        # prior test in the suite.
        if self._running():
            self.key("Shift+F12")
            self.assertFalse(self._running(),
                "setup: could not stop a pre-running profiler")

        self.key("Shift+F12")
        self.assertTrue(self._running(), (
            "after first Shift+F12: profiler should be running. "
            "Still stopped means the keypress didn't reach ToggleProfiler "
            "or M.start() refused."))

        self.key("Shift+F12")
        self.assertFalse(self._running(), (
            "after second Shift+F12: profiler should be stopped "
            "(toggle returns to baseline). Still running means M.stop() "
            "didn't fire."))

if __name__ == "__main__":
    unittest.main()
