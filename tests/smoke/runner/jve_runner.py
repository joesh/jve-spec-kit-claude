"""
jve_runner — long-lived JVEEditor driver for the smoke test suite.

See specs/020-debug-terminal/phase1-test-overhaul.md.

Lifecycle:
    runner = JVERunner(socket_path=..., binary=...)
    runner.start()           # launch JVE + connect socket + foreground
    runner.open_project(jvp_path)
    runner.eval('...')
    runner.key('cmd+z')
    runner.click(x, y)
    runner.shutdown()

Wire protocol (matches spec 020 FR-004..007):
    Client sends:  "<lua chunk>\n"
    Server sends:  "<formatted return values>\njve> "
                or "ERROR: <msg>\njve> "
                or just "jve> " for empty statements
The runner reads until the trailing "jve> " prompt.
"""

import os
import shutil
import socket
import subprocess
import time
from pathlib import Path
from typing import Optional


# ─── Configuration ──────────────────────────────────────────────────────────


REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_BINARY = REPO_ROOT / "build" / "bin" / "JVEEditor.app" / "Contents" / "MacOS" / "JVEEditor"
DEFAULT_SOCKET = "/tmp/jve_smoke.sock"
EVAL_TIMEOUT_S = float(os.environ.get("JVE_SMOKE_EVAL_TIMEOUT", "5"))
STARTUP_TIMEOUT_S = float(os.environ.get("JVE_SMOKE_STARTUP_TIMEOUT", "20"))
PROMPT = b"jve> "


class JVERunnerError(RuntimeError):
    """Raised on any unrecoverable runner-level fault (timeout, crash, protocol)."""


class JVEEvalError(RuntimeError):
    """Raised when a Lua eval returns an ``ERROR:`` line. Carries the message."""
    def __init__(self, lua_message: str, chunk: str):
        super().__init__(f"{lua_message}\n  while evaluating: {chunk}")
        self.lua_message = lua_message
        self.chunk = chunk


# ─── Process lifecycle ──────────────────────────────────────────────────────


class JVERunner:
    """Single instance owns one JVEEditor process + one socket client."""

    def __init__(
        self,
        socket_path: str = DEFAULT_SOCKET,
        binary: Optional[Path] = None,
        startup_project: Optional[Path] = None,
        env: Optional[dict] = None,
        stdout_log: Optional[Path] = None,
    ):
        self.socket_path = socket_path
        self.binary = Path(binary) if binary else DEFAULT_BINARY
        self.startup_project = Path(startup_project) if startup_project else None
        self.env = env
        self.stdout_log = stdout_log or Path("/tmp/jve_smoke_run.log")
        self._proc: Optional[subprocess.Popen] = None
        self._sock: Optional[socket.socket] = None
        self._read_buf = bytearray()
        self._log_fh = None  # opened by start(), closed by shutdown()

    # ─── start / shutdown ──────────────────────────────────────────────

    def start(self) -> None:
        """Launch JVE, wait for the socket file, connect, drain initial prompt."""
        if self._proc is not None:
            raise JVERunnerError("JVERunner.start: already started")
        if not self.binary.exists():
            raise JVERunnerError(
                f"JVERunner.start: binary not found at {self.binary} — "
                f"build with `cd build && make JVEEditor -j4`")

        # Stale socket from a prior crashed run — JVE itself unlinks before
        # bind, but cleaning here too is cheap insurance.
        try:
            os.unlink(self.socket_path)
        except FileNotFoundError:
            pass

        args = [str(self.binary), "--control-socket", self.socket_path]
        if self.startup_project is not None:
            args.append(str(self.startup_project))

        self._log_fh = self.stdout_log.open("wb")
        self._proc = subprocess.Popen(
            args, stdout=self._log_fh, stderr=subprocess.STDOUT, env=self.env)

        self._wait_for_socket()
        self._connect()
        self._drain_initial_prompt()

    def shutdown(self) -> None:
        """Close the socket, terminate JVE, unlink the socket file."""
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        if self._proc is not None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._proc.kill()
                self._proc.wait(timeout=2)
            self._proc = None
        try:
            os.unlink(self.socket_path)
        except FileNotFoundError:
            pass
        if self._log_fh is not None:
            self._log_fh.close()
            self._log_fh = None

    def is_alive(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    # ─── socket I/O ────────────────────────────────────────────────────

    def eval(self, lua: str) -> str:
        """Send one Lua chunk, return the formatted reply line (or "" for empty).

        Raises JVEEvalError if the response is ``ERROR: …``. Raises
        JVERunnerError if the socket times out or JVE has died.

        On socket timeout: the runner is now in an unknown state (the
        Lua chunk may still be executing; future reads would mis-frame
        on its delayed reply). We tear down the process so the next
        setUp() must rebuild — fail loud, not silently misread the
        next test's prompts.
        """
        if self._sock is None:
            raise JVERunnerError("JVERunner.eval: not started")
        if not self.is_alive():
            raise JVERunnerError(
                f"JVERunner.eval: JVE process is dead — see {self.stdout_log}")

        # Strip newlines from the chunk so wire framing stays one-line-per-request.
        # Callers wanting multi-statement chunks use semicolons.
        line = lua.replace("\n", " ")
        self._sock.sendall(line.encode("utf-8") + b"\n")

        try:
            reply = self._read_until_prompt()
        except socket.timeout:
            self._force_shutdown_after_timeout()
            raise JVERunnerError(
                f"JVERunner.eval: socket timed out after {EVAL_TIMEOUT_S}s "
                f"waiting for reply to {lua!r}; JVE killed (suite log: "
                f"{self.stdout_log}). Subsequent tests will respawn JVE.")
        if reply.startswith("ERROR: "):
            raise JVEEvalError(reply[len("ERROR: "):], lua)
        return reply

    def _force_shutdown_after_timeout(self) -> None:
        """Kill the wedged JVE and clear all state so a caller-driven
        respawn produces a clean runner. Called only from eval()'s
        timeout path — never on the happy path."""
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        if self._proc is not None:
            self._proc.kill()
            try:
                self._proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
            self._proc = None
        try:
            os.unlink(self.socket_path)
        except FileNotFoundError:
            pass
        if self._log_fh is not None:
            self._log_fh.close()
            self._log_fh = None
        self._read_buf = bytearray()

    def eval_int(self, lua: str) -> int:
        """Convenience: eval and parse as integer."""
        return int(self.eval(lua))

    def eval_str(self, lua: str) -> str:
        """Convenience: eval, strip surrounding quotes from the repr."""
        s = self.eval(lua)
        if s.startswith('"') and s.endswith('"'):
            return _unescape_repr_string(s[1:-1])
        raise JVERunnerError(
            f"eval_str: expected quoted string, got: {s!r}")

    def eval_bool(self, lua: str) -> bool:
        s = self.eval(lua)
        if s == "true":
            return True
        if s == "false":
            return False
        raise JVERunnerError(f"eval_bool: expected true/false, got: {s!r}")

    # ─── higher-level helpers ──────────────────────────────────────────

    def open_project(self, jvp_path: Path) -> None:
        """Reset JVE state by opening a fresh project. Uses the existing
        project_changed cascade so every registered listener tears down."""
        path = str(jvp_path).replace("'", "\\'")
        self.eval(
            "require('core.command_manager').execute('OpenProject', "
            f"{{ project_path = '{path}' }})")

    def foreground(self) -> None:
        """Bring JVE's app to the foreground so OS keypresses route to it.

        Required before any test that drives via real keypresses — Qt's
        QShortcut activation needs a foregrounded application.

        We address the process via System Events + ``unix id``: the
        JVEEditor binary is not a ``.app`` bundle, so
        ``tell application "JVEEditor" to activate`` fails to resolve.
        ``set frontmost of process whose unix id is <pid>`` is the
        ``.app``-less equivalent.

        After activation, tucks the window into the bottom-right corner
        of the main display so the user can keep working visually
        (typing still routes to JVE while a test fires — that's the
        macOS constraint, not something we can hide). Set
        JVE_SMOKE_VISIBLE=1 to skip the tuck and see the full window.
        """
        if self._proc is None:
            raise JVERunnerError("JVERunner.foreground: process not started")
        pid = self._proc.pid
        script = (
            f'tell application "System Events" '
            f'to set frontmost of (first process whose unix id is {pid}) to true'
        )
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True, timeout=5)
        if result.returncode != 0:
            stderr = result.stderr.decode("utf-8", errors="replace").strip()
            raise JVERunnerError(
                f"foreground failed (osascript exit {result.returncode}): {stderr}\n"
                f"  Likely cause: the terminal running these tests lacks\n"
                f"  System Events / Accessibility permission. Grant it in\n"
                f"  System Settings → Privacy & Security → Accessibility.")
        # Brief settle — activation is asynchronous in System Events.
        time.sleep(0.05)
        # Tuck only on the host: hiding the window in the bottom-right
        # corner lets the user keep working in their other apps. In a
        # UTM guest the guest desktop is fully owned by the VM, so
        # tucking is pointless (no "rest of the screen" to keep visible)
        # and just makes JVE harder to see while debugging. Set
        # JVE_SMOKE_IN_VM=1 in the guest's shell config to skip.
        # JVE_SMOKE_VISIBLE=1 also skips (pre-existing flag for full-
        # window visibility on the host).
        if not os.environ.get("JVE_SMOKE_VISIBLE") and not os.environ.get("JVE_SMOKE_IN_VM"):
            self._tuck_window_bottom_right()

    def _tuck_window_bottom_right(self) -> None:
        """Position JVE's frontmost window so only the top-left ~240×120 px
        sits on-screen at the bottom-right of the main display. The rest of
        the window extends off the screen edge (valid on macOS — windows
        can have positive coordinates past the display bound). The title
        bar's drag handle is the visible bit, so the user can grab and
        reposition it manually if they want to see the full UI.
        """
        if self._proc is None:
            return
        pid = self._proc.pid
        # Visible window area at the bottom-right; the rest extends off-
        # screen. AppleScript's "set position" uses the upper-left corner
        # of the window in screen coordinates (origin top-left of main
        # display). For the visible patch to be at the bottom-right, the
        # upper-left corner sits at (screen_w - visible_w, screen_h - visible_h).
        visible_w = int(os.environ.get("JVE_SMOKE_VISIBLE_WIDTH", "240"))
        visible_h = int(os.environ.get("JVE_SMOKE_VISIBLE_HEIGHT", "120"))
        script = f'''
            tell application "Finder" to set screenSize to bounds of window of desktop
            set screenW to item 3 of screenSize
            set screenH to item 4 of screenSize
            set newX to screenW - {visible_w}
            set newY to screenH - {visible_h}
            tell application "System Events"
                tell (first process whose unix id is {pid})
                    if (count of windows) > 0 then
                        set position of window 1 to {{newX, newY}}
                    end if
                end tell
            end tell
        '''
        # Best-effort: window may not exist yet (very early in startup, or
        # post-shutdown). Don't fail the foreground call on tuck failure.
        subprocess.run(["osascript", "-e", script],
                       capture_output=True, timeout=5)

    def key(self, combo: str) -> None:
        """Deliver a single key press via osascript / System Events.

        ``combo`` is the same syntax as keymaps/default.jvekeys —
        ``"I"``, ``"Cmd+Z"``, ``"Shift+F"``, ``"Grave"``. osascript's
        ``keystroke`` posts a real OS-level key event into whichever
        process is frontmost; JVE must be foregrounded before this
        call (foreground() handles it at setUp).

        macOS keystrokes go to the OS-level frontmost app, no
        targeting. Two consequences:

          1. JVE must be frontmost or the keystroke lands in whichever
             app IS — your editor, terminal, Slack. There is no
             reliable in-process atomic grab-press-restore (we tried
             — see commits 766fb954..e4ccd679, reverted 2026-05-25).
          2. If you use the host computer while smoke runs, your own
             keystrokes can land in JVE. Both directions of collision
             are real.

        Recommended hosts: run smoke either (a) on a host where you
        won't touch the keyboard, or (b) inside a UTM macOS guest
        whose keyboard is captured by the VM (Ctrl+Option to release).
        See `specs/020-debug-terminal/phase1-test-overhaul.md` for the
        VM-guest runbook.

        Pre-bundle, JVE was a raw binary at the default Prohibited
        policy and osascript dropped keystrokes on the floor; the
        .app bundle + setActivationPolicy:Regular + activate-
        IgnoringOtherApps in main.cpp register it as a proper
        foreground-policy macOS app so keystrokes route correctly.

        Requires the calling process (Terminal/iTerm/etc.) to have
        Accessibility permission. Without it macOS returns error
        ``1002``; surfaced as ``JVERunnerError`` with the fix location.
        """
        keystroke = _combo_to_osascript_keystroke(combo)
        result = subprocess.run(
            ["osascript", "-e",
             f'tell application "System Events" to {keystroke}'],
            capture_output=True, timeout=5)
        if result.returncode != 0:
            stderr = result.stderr.decode("utf-8", errors="replace").strip()
            raise JVERunnerError(
                f"key({combo!r}) failed (osascript exit {result.returncode}): "
                f"{stderr}\n"
                f"  If the message is 'not allowed to send keystrokes' (1002):\n"
                f"  grant the parent process (Terminal / iTerm / your IDE)\n"
                f"  permission in System Settings → Privacy & Security →\n"
                f"  Accessibility.")
        # Settle — let Qt's event loop pick up the key + dispatch the
        # QShortcut + run the Lua handler before the next eval.
        time.sleep(0.05)

    def click(self, x: int, y: int, double: bool = False) -> None:
        """Mouse click at absolute screen coords via osascript / System Events.

        Note: System Events click coordinates are screen-relative. Tests
        that need widget-relative coords should query JVE via the socket
        for the widget's frame first.
        """
        kind = "double click" if double else "click"
        subprocess.run(
            ["osascript", "-e",
             f'tell application "System Events" to {kind} at {{{x}, {y}}}'],
            check=True, capture_output=True, timeout=5)
        time.sleep(0.05)

    # ─── internals ─────────────────────────────────────────────────────

    def _wait_for_socket(self) -> None:
        deadline = time.monotonic() + STARTUP_TIMEOUT_S
        while time.monotonic() < deadline:
            if os.path.exists(self.socket_path):
                # Sock exists but may not be listening yet; small settle.
                time.sleep(0.05)
                return
            if self._proc is not None and self._proc.poll() is not None:
                raise JVERunnerError(
                    f"JVE exited before socket appeared — see {self.stdout_log}")
            time.sleep(0.1)
        raise JVERunnerError(
            f"JVE did not create socket {self.socket_path} within "
            f"{STARTUP_TIMEOUT_S}s — see {self.stdout_log}")

    def _connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(EVAL_TIMEOUT_S)
        sock.connect(self.socket_path)
        self._sock = sock

    def _drain_initial_prompt(self) -> None:
        # Spec FR-007: server writes "jve> " on connect. No body precedes it.
        self._read_until_prompt(expect_body=False)

    def _read_until_prompt(self, expect_body: bool = True) -> str:
        """Read until the ``"jve> "`` marker. Returns the body (if any).

        Wire protocol (spec 020 FR-005..007):
            • Non-empty body: ``<body>\\njve> ``
            • Empty body / empty input / initial connect: bare ``jve> ``

        So the prompt is always ``"jve> "``. The body is whatever bytes
        preceded it; if those end in ``\\n``, strip it (the framing
        newline). ``expect_body=False`` is used at connect time where
        any non-prompt prefix indicates a protocol error.
        """
        while True:
            idx = self._read_buf.find(PROMPT)
            if idx >= 0:
                body = bytes(self._read_buf[:idx])
                self._read_buf = self._read_buf[idx + len(PROMPT):]
                if body.endswith(b"\n"):
                    body = body[:-1]
                decoded = body.decode("utf-8", errors="replace")
                if not expect_body and decoded:
                    raise JVERunnerError(
                        f"unexpected bytes before initial prompt: {decoded!r}")
                return decoded
            chunk = self._sock.recv(4096)
            if not chunk:
                raise JVERunnerError(
                    f"socket closed mid-response — see {self.stdout_log}")
            self._read_buf += chunk


# ─── helpers ────────────────────────────────────────────────────────────────


# Non-printable keys → macOS virtual key codes (US ANSI layout). Shared
# by the postkey CGEvent path and the click() helper that still uses
# osascript. Letter + digit codes live in _LETTER_DIGIT_CODES below.
_KEY_CODES = {
    "return":     0x24,
    "enter":      0x4C,
    "tab":        0x30,
    "space":      0x31,
    "delete":     0x33,
    "escape":     0x35,
    "left":       0x7B,
    "right":      0x7C,
    "down":       0x7D,
    "up":         0x7E,
    "home":       0x73,
    "end":        0x77,
    "pageup":     0x74,
    "pagedown":   0x79,
    "f1":         0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
    "f5":         0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
    "f9":         0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    "grave":      0x32,   # ` / ~ key
    "comma":      0x2B,
    "period":     0x2F,
    "slash":      0x2C,
    "semicolon":  0x29,
    "apostrophe": 0x27,
    "backslash":  0x2A,
    "bracketleft":  0x21,
    "bracketright": 0x1E,
    "minus":      0x1B,
    "equal":      0x18,
    "backspace":  0x33,
}


# osascript modifier names: command/control/option/shift_down forms
# (translated from keymap "cmd"/"ctrl"/"alt"/etc.).
_MODIFIER_NAMES = {
    "cmd":     "command down",
    "ctrl":    "control down",
    "alt":     "option down",
    "opt":     "option down",
    "shift":   "shift down",
}


def _combo_to_osascript_keystroke(combo: str) -> str:
    """Translate a keymap-format combo (``"Shift+F"``) to an osascript
    fragment. Returns the right-hand side of ``tell application
    "System Events" to ...``, e.g. ``keystroke "f" using {shift down}``
    or ``key code 36``."""
    parts = [p.strip() for p in combo.split("+")]
    if not parts or not parts[-1]:
        raise ValueError(f"empty combo: {combo!r}")
    key = parts[-1]
    mods = [p.lower() for p in parts[:-1]]

    using_clauses = []
    for m in mods:
        if m not in _MODIFIER_NAMES:
            raise ValueError(f"unknown modifier {m!r} in combo {combo!r}")
        using_clauses.append(_MODIFIER_NAMES[m])
    using = ""
    if using_clauses:
        using = " using {" + ", ".join(using_clauses) + "}"

    key_lower = key.lower()
    # Letter or digit: keystroke "x" — case derives from the shift modifier.
    if len(key) == 1 and key.isprintable():
        return f'keystroke "{key.lower()}"{using}'
    # Tilde is the shifted form of Grave on US keyboards. The keymap
    # spells the binding "Tilde" (not "Shift+Grave") because Qt's
    # QKeySequence treats them as distinct codes (Qt::Key_AsciiTilde
    # vs Qt::Key_QuoteLeft+Shift). Auto-add the shift modifier when
    # delivering Tilde via osascript.
    if key_lower == "tilde":
        shift_clause = "shift down"
        if using:
            if shift_clause not in using:
                using = using[:-1] + f", {shift_clause}" + using[-1:]
        else:
            using = " using {" + shift_clause + "}"
        return f'key code {_KEY_CODES["grave"]}{using}'
    # Named key (Grave, Comma, Return, F1, ...): use key code.
    if key_lower in _KEY_CODES:
        return f'key code {_KEY_CODES[key_lower]}{using}'
    raise ValueError(f"unknown key {key!r} in combo {combo!r}")




def _unescape_repr_string(body: str) -> str:
    """Reverse the escapes formatValue applies in debug_terminal.cpp:appendEscaped."""
    out = []
    i = 0
    while i < len(body):
        c = body[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        if i + 1 >= len(body):
            raise ValueError(f"trailing backslash in repr string: {body!r}")
        nxt = body[i + 1]
        if nxt == "n":  out.append("\n"); i += 2
        elif nxt == "r": out.append("\r"); i += 2
        elif nxt == "t": out.append("\t"); i += 2
        elif nxt == "\\": out.append("\\"); i += 2
        elif nxt == '"': out.append('"');  i += 2
        elif nxt == "x":
            if i + 4 > len(body):
                raise ValueError(f"truncated \\xHH in repr string: {body!r}")
            out.append(chr(int(body[i + 2:i + 4], 16)))
            i += 4
        else:
            raise ValueError(f"unknown escape \\{nxt} in repr string: {body!r}")
    return "".join(out)


# ─── fixtures ───────────────────────────────────────────────────────────────


class Fixtures:
    """Anamnesis template management. Build once per suite, copy per test."""

    DRP_FIXTURE = REPO_ROOT / "tests" / "fixtures" / "resolve" / "anamnesis-gold-timeline.drp"

    def __init__(self, scratch_root: Path = Path("/tmp/jve_smoke")):
        self.scratch_root = scratch_root
        self.scratch_root.mkdir(parents=True, exist_ok=True)
        self.template_path = self.scratch_root / "template.jvp"

    def fresh_copy(self, test_id: str) -> Path:
        """Return a writable .jvp copy named after the test id."""
        # Slugify the test id (pytest gives "module.py::Class::test" form).
        slug = test_id.replace("/", "_").replace(":", "_").replace(".", "_")
        dst = self.scratch_root / f"{slug}.jvp"
        for suffix in ("", "-wal", "-shm"):
            p = Path(str(dst) + suffix)
            if p.exists():
                p.unlink()
        if not self.template_path.exists():
            raise JVERunnerError(
                f"Anamnesis template not built — run "
                f"`python3 tests/smoke/runner/build_template.py` first.\n"
                f"  expected at: {self.template_path}")
        shutil.copy(self.template_path, dst)
        return dst
