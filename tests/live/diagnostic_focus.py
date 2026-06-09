#!/usr/bin/env python3
"""Diagnostic: probe the JVE foreground/focus problem that blocks L3
keypress smokes. Symptom (TSO 2026-05-22+):

    runner.foreground() returns exit=0 (osascript reports success).
    osascript then `key("X")` fires.
    But the X never reaches JVE — ghostty (or whatever shell/IDE) stays
    frontmost the whole time and eats the keystroke.

This script reproduces the failure mode and asks System Events
*twice* what's actually frontmost: once before/after foreground(), and
once again after a settle delay. The diff tells us which class of
failure we're hitting:

  (a) the activation never lands (System Events lies that it
      succeeded, or the frontmost ownership is contested),
  (b) the activation lands transiently then immediately flips back
      (another app's NSWorkspace observer steals focus),
  (c) the activation lands but JVE's window itself isn't the key
      window (NSStatusBar item / borderless window / off-screen Qt
      child consuming focus events).

Most likely root cause (a priori): JVEEditor is a raw binary, not a
``.app`` bundle with an Info.plist. macOS treats non-bundled processes
as background-only for windowserver purposes — `set frontmost` on a
``process`` succeeds at the System Events layer but the windowserver
doesn't grant key-window status the way it does for bundled apps.
Subsequent osascript keystrokes route to whatever IS a proper bundled
foreground app (your terminal).

If (a) is confirmed, two paths:
  * bundle jve.app at build time (proper fix; touches CMake +
    needs an Info.plist),
  * switch the runner from osascript keystroke to CGEventPostToPid()
    (workaround; targets JVE's PID directly, bypasses front-app
    routing). NB: CGEventPost-from-self does NOT trigger QShortcuts
    (CLAUDE.md note 2026-05-20); CGEventPostToPid from the *runner*
    process is a different code path and should work.

Run: python3 tests/live/diagnostic_focus.py
Needs Accessibility permission on the parent terminal.
"""
from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

# Allow tests/live import.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from smoke.runner.jve_runner import JVERunner  # noqa: E402


SETTLE_MS = 50
PROBE_INTERVAL_MS = 100
PROBE_COUNT = 10


def frontmost_app_name() -> str:
    """Ask System Events for the unix name of the currently frontmost
    process. Returns the empty string if the AppleScript itself fails
    (Accessibility permission missing, etc.)."""
    script = (
        'tell application "System Events" '
        'to get name of first process whose frontmost is true'
    )
    result = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True, timeout=3, text=True)
    if result.returncode != 0:
        return f"<osascript err {result.returncode}: {result.stderr.strip()}>"
    return result.stdout.strip()


def main() -> int:
    template = "/tmp/jve_smoke/template.jvp"
    if not os.path.exists(template):
        print(f"FAIL: template missing at {template} — "
              f"run `python3 tests/live/runner/build_template.py` first")
        return 1

    print("[1/4] Launching JVE with control socket...")
    runner = JVERunner(
        socket_path="/tmp/jve_smoke/focus_diag.sock",
        startup_project=Path(template),
        stdout_log=Path("/tmp/jve_smoke/focus_diag.log"))
    runner.start()

    print(f"[2/4] Pre-foreground frontmost: {frontmost_app_name()!r}")

    print("[3/4] Calling runner.foreground()...")
    runner.foreground()
    time.sleep(SETTLE_MS / 1000.0)

    print(f"[4/4] Post-foreground frontmost: {frontmost_app_name()!r}")

    print()
    print("─── settling probe (sample every "
          f"{PROBE_INTERVAL_MS}ms × {PROBE_COUNT}) ───")
    for i in range(PROBE_COUNT):
        time.sleep(PROBE_INTERVAL_MS / 1000.0)
        print(f"  +{(i+1) * PROBE_INTERVAL_MS:>4}ms: {frontmost_app_name()!r}")

    print()
    print("─── probe what happens if we press a key now ───")
    print("Pressing 'X' (MarkClipExtent) — watch whether it reaches JVE "
          "or the terminal:")
    runner.key("X")
    time.sleep(SETTLE_MS / 1000.0)
    print(f"  frontmost after key press: {frontmost_app_name()!r}")

    print()
    print("Process is left running for you to inspect. Hit Ctrl+C to exit.")
    print(f"  socket: {runner.socket_path}")
    print(f"  log:    {runner.stdout_log}")
    print(f"  pid:    {runner._proc.pid if runner._proc else '<none>'}")
    try:
        while True:
            time.sleep(60)
    except KeyboardInterrupt:
        pass

    runner.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
