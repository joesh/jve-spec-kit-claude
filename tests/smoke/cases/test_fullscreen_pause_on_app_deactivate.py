"""
Fullscreen viewer pauses when JVE loses frontmost status and restores
when JVE re-activates.

User-visible problem this guards: the borderless top-most fullscreen
window stays glued to every other desktop while the user Cmd-Tabs to
Resolve for a color A/B — the user can't see the comparison reference.
The intended behavior is: fullscreen disappears the moment JVE is no
longer frontmost, and pops back automatically when the user Cmd-Tabs
back to JVE.

Domain-level assertions: after activating another app,
``fullscreen_viewer.is_active()`` is false. After re-activating JVE,
``is_active()`` is true again AND ``get_current_view_id()`` matches
the viewer that was fullscreen before deactivation (so the user sees
the SAME viewer they had open, not a default fall-back).

Skipped under JVE_SMOKE_IN_VM — the guest desktop has no second app
to switch to, and the runner's foreground() short-circuits there.

Run:
    python3 -m unittest tests.smoke.cases.test_fullscreen_pause_on_app_deactivate -v
"""

import os
import subprocess
import time
import unittest

from tests.smoke.runner.case import JVESmokeCase


def _activate_finder() -> None:
    """Bring Finder frontmost — drops JVE from frontmost status.

    Finder is always running on macOS, so this is the most reliable
    way to provoke applicationStateChanged on JVE without depending on
    any developer-specific app being installed.
    """
    subprocess.run(
        ["osascript", "-e", 'tell application "Finder" to activate'],
        capture_output=True, timeout=5, check=True)


class TestFullscreenPauseOnAppDeactivate(JVESmokeCase):
    """Cmd+Shift+F → other app frontmost → JVE frontmost again."""

    @unittest.skipIf(
        bool(os.environ.get("JVE_SMOKE_IN_VM")),
        "JVE_SMOKE_IN_VM: no second app available to steal focus from JVE")
    def test_fullscreen_pauses_on_deactivate_and_restores_on_activate(self) -> None:
        # Anchor focus on the timeline so ToggleFullscreenView picks
        # timeline_monitor (the focused-viewer dispatch).
        self.focus_panel("timeline")

        # Enter fullscreen via the real keybinding. Domain assertion:
        # is_active flips to true.
        self.key("Cmd+Shift+F")
        self.assertEvalEqual(
            True,
            "return require('ui.fullscreen_viewer').is_active()",
            msg=("Cmd+Shift+F did not enter fullscreen — either the key "
                 "didn't reach ToggleFullscreenView, or fullscreen_viewer."
                 "enter() failed silently."))
        view_before = self.eval_str(
            "return require('ui.fullscreen_viewer').get_current_view_id() or ''")
        self.assertEqual(
            view_before, "timeline_monitor",
            msg=("ToggleFullscreenView dispatched on wrong viewer — "
                 "focused panel was timeline but fullscreen reports "
                 f"{view_before!r}. Expected 'timeline_monitor'."))

        try:
            # Drop JVE from frontmost by activating Finder.
            _activate_finder()
            # applicationStateChanged is async — let Qt's event loop
            # tick before sampling. 200 ms is comfortably above the
            # single-shot timer JVE uses to defer the handler.
            time.sleep(0.2)

            self.assertEvalEqual(
                False,
                "return require('ui.fullscreen_viewer').is_active()",
                msg=("Fullscreen still active after Finder took "
                     "frontmost — the SET_APP_STATE_HANDLER deactivate "
                     "branch didn't fire (or didn't call M.exit())."))

            # Bring JVE back to the front via the runner's standard
            # foreground hook — same path the user takes (Cmd-Tab /
            # Dock click).
            self.runner.foreground()
            time.sleep(0.2)

            self.assertEvalEqual(
                True,
                "return require('ui.fullscreen_viewer').is_active()",
                msg=("Fullscreen did NOT auto-restore on re-activate — "
                     "_paused_view_id was either not captured on "
                     "deactivate, or the activate branch failed to "
                     "consume it."))
            view_after = self.eval_str(
                "return require('ui.fullscreen_viewer')."
                "get_current_view_id() or ''")
            self.assertEqual(
                view_after, view_before,
                msg=("Fullscreen restored on the wrong viewer: was "
                     f"{view_before!r} before deactivate, came back as "
                     f"{view_after!r}. The activate branch should reuse "
                     "_paused_view_id, not pick a default."))
        finally:
            # Leave fullscreen off so the next test doesn't inherit a
            # borderless on-top window. is_active() may already be false
            # if a prior assertion already exited; the call is idempotent.
            self.eval("require('ui.fullscreen_viewer').exit()")


if __name__ == "__main__":
    unittest.main()
