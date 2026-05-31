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
DEFAULT_BINARY = REPO_ROOT / "build" / "bin" / "jve.app" / "Contents" / "MacOS" / "jve"
DEFAULT_SOCKET = "/tmp/jve_smoke.sock"
# Default eval timeout. 5s is plenty on the host (warm cache, multi-core),
# but the UTM guest is single-core with cold disk + cold Lua JIT and
# per-test operations (open_project, plus the occasional Qt event-loop
# spin) routinely take longer. 30s in-VM is the empirical floor — 15s
# triggered mid-suite JVE respawns on ~5% of test transitions, which
# poisoned downstream tests with a fresh-JVE that didn't match their
# expected state. JVE_SMOKE_EVAL_TIMEOUT still wins if explicitly set.
_DEFAULT_EVAL_TIMEOUT = "30" if os.environ.get("JVE_SMOKE_IN_VM") else "5"
EVAL_TIMEOUT_S = float(os.environ.get("JVE_SMOKE_EVAL_TIMEOUT", _DEFAULT_EVAL_TIMEOUT))
STARTUP_TIMEOUT_S = float(os.environ.get("JVE_SMOKE_STARTUP_TIMEOUT", "20"))

# cliclick (Homebrew: `brew install cliclick`) replaces osascript for mouse
# clicks. osascript routes through the System Events daemon which blocks
# waiting for the app to ack the click — that ack-wait hangs when JVE is
# mid-command, producing multi-second timeouts. cliclick posts the CGEvent
# directly and returns. /opt/homebrew on Apple Silicon, /usr/local on
# Intel — pick whichever exists. NSF: fail loudly at module-load time if
# neither exists rather than at the first click().
def _resolve_cliclick() -> str:
    override = os.environ.get("JVE_SMOKE_CLICLICK")
    candidates = [override] if override else [
        "/opt/homebrew/bin/cliclick",
        "/usr/local/bin/cliclick",
    ]
    for path in candidates:
        if path and os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    raise RuntimeError(
        "cliclick not found. Install with `brew install cliclick` or set "
        "JVE_SMOKE_CLICLICK to the absolute path. The smoke harness uses "
        "it for OS-level mouse clicks because the osascript path hangs "
        "waiting for System Events to ack-deliver when JVE is mid-command.")

CLICLICK_BINARY = _resolve_cliclick()
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
                f"build with `cd build && make jve -j4`")

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
        self._wait_for_layout_settle()

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
        ``tell application "jve" to activate`` fails to resolve.
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

        # In-VM short-circuit: when JVE_SMOKE_IN_VM is set we know there
        # are no competing apps on the guest desktop, and main.cpp's
        # activateIgnoringOtherApps:YES has already made JVE frontmost
        # at launch. Skipping the osascript path also lets us drive the
        # whole suite over ssh — sshd doesn't have Accessibility
        # permission and never should, so the System Events call would
        # otherwise hard-fail every ssh-launched run.
        if os.environ.get("JVE_SMOKE_IN_VM"):
            return

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

    def key(self, combo: str, expect_command: bool = True) -> None:
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
        snap = self.get_command_count()
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
        # Joe contract: every UI keypress provokes a command 1:1. Block
        # until the command commits before returning, so the next eval
        # reads post-command state. If the press is lost / lands in
        # another app / fires no command, surface that loudly rather
        # than silently racing the next assertion.
        #
        # Opt-out: ``expect_command=False`` for inputs that intentionally
        # don't reach JVE — keystrokes typed INTO a frontmost macOS
        # native dialog (NSOpenPanel "Go to folder" prompt, type the
        # path, Return). The OS dialog consumes the key; JVE never sees
        # it and no command fires. Callers using that path are
        # responsible for their own wait-for-result polling (e.g.,
        # ``pick_file_in_open_dialog`` polls for the dialog to close).
        if expect_command:
            self.wait_for_command_after(snap)

    def click(self, x: int, y: int, double: bool = False, right: bool = False) -> None:
        """Mouse click at absolute screen coords via cliclick (CGEventPost).

        Why cliclick and not ``osascript -e 'tell System Events to click ...'``:
        osascript routes through the System Events daemon, which posts
        the CGEvent and then BLOCKS waiting for the frontmost app to
        acknowledge the click. When JVE is mid-command (which our
        command-completion barrier makes the common case immediately
        after the prior key/click commits), the ack stalls and osascript
        times out. Pre-barrier vm6: 0 osascript timeouts. Post-barrier
        vm10: 72 × 5s timeouts on click = ~360s wasted wall time.

        cliclick uses ``CGEventCreateMouseEvent`` + ``CGEventPost`` —
        the click is dropped into the HID event queue and returns
        immediately. No daemon, no ack-wait, no hang. Latency ~5ms.

        Coordinates are absolute screen coords (same as the osascript
        path was). Both forms use the same screen pixel grid.
        """
        if double:
            verb = "dc"
        elif right:
            verb = "rc"
        else:
            verb = "c"
        subprocess.run(
            [CLICLICK_BINARY, f"{verb}:{x},{y}"],
            check=True, capture_output=True, timeout=5)

    # ─── higher-level user-input helpers ──────────────────────────────

    def type_text(self, s: str) -> None:
        """Type a string via osascript keystroke. Slow (one osascript
        per character); avoid for >100 chars."""
        if not s:
            return
        # Escape backslashes and double-quotes for the AppleScript literal.
        escaped = s.replace("\\", "\\\\").replace('"', '\\"')
        subprocess.run(
            ["osascript", "-e",
             f'tell application "System Events" to keystroke "{escaped}"'],
            check=True, capture_output=True, timeout=10)
        time.sleep(0.05)

    def menu_pick(self, path: str) -> None:
        """Click a menu item via the system menu bar. ``path`` is
        ``"Menu > Submenu > Item"`` syntax matching menus.xml.

        Example: ``runner.menu_pick("File > Import > Resolve Project (.drp)...")``

        Uses osascript to walk the menu bar of the JVE process. Fails
        loudly with the AppleScript error if the menu path doesn't exist
        — typo in the path is the most common cause.
        """
        if self._proc is None:
            raise JVERunnerError("menu_pick: process not started")
        parts = [p.strip() for p in path.split(">")]
        if len(parts) < 2:
            raise ValueError(
                f"menu_pick: path must include at least 'Menu > Item' "
                f"(got {path!r})")
        pid = self._proc.pid
        top, *intermediates, leaf = parts
        # Build the AppleScript menu reference inside-out. macOS Accessibility
        # models a menu like so:
        #   menu bar 1
        #     menu bar item "File"                  <- top-level entry
        #       menu "File"                         <- the dropdown
        #         menu item "Import"                <- a submenu's parent item
        #           menu "Import"                   <- the submenu (same name)
        #             menu item "FCP7 XML..."       <- leaf
        # So each intermediate name appears TWICE: as a menu item inside its
        # parent menu, and as the wrapping menu of the same name. The leaf is
        # `menu item "<leaf>" of menu "<inner>" of menu item "<inner>" of …`.
        menu_chain = []
        for name in intermediates:
            menu_chain.append(f'menu "{name}" of menu item "{name}"')
        menu_chain.append(f'menu "{top}"')
        menu_chain.append(f'menu bar item "{top}" of menu bar 1')
        menu_ref = " of ".join(menu_chain)
        script = (
            f'tell application "System Events" to tell '
            f'(first process whose unix id is {pid}) to '
            f'click menu item "{leaf}" of {menu_ref}'
        )
        result = subprocess.run(
            ["osascript", "-e", script], capture_output=True, timeout=10)
        if result.returncode != 0:
            stderr = result.stderr.decode("utf-8", errors="replace").strip()
            raise JVERunnerError(
                f"menu_pick({path!r}) failed: {stderr}\n"
                f"  Likely cause: typo in menu path, or menu hasn't been\n"
                f"  built yet. Check src/lua/ui/menus.xml for the exact\n"
                f"  menu/item names.")
        # Settle — menu click dispatch + downstream command + UI update.
        time.sleep(0.2)

    def pick_file_in_open_dialog(self, path: str, timeout: float = 8.0) -> None:
        """Drive a frontmost NSOpenPanel via Cmd+Shift+G → type path → Return.

        Must be called RIGHT AFTER triggering an Open / Import menu item
        that opens a file-picker sheet. Polling: waits briefly for the
        sheet to appear (cold app open is slower than warm), then sends
        Cmd+Shift+G (opens the path entry), types the path, presses
        Return to commit, then Return again on the dialog's Open button.

        Tests that don't need a real file dialog should not call this —
        the importer command can be triggered directly via the menu, but
        the dialog must close before any post-import eval will succeed.
        """
        if not path:
            raise ValueError("pick_file_in_open_dialog: path required")
        # Settle: let the sheet attach to the main window.
        time.sleep(0.4)
        # Cmd+Shift+G opens the "Go to folder" prompt.
        # Dialog keys go to NSOpenPanel — JVE never sees them, no
        # command fires. Bypass the command barrier; we poll for the
        # dialog to close below.
        self.key("Cmd+Shift+G", expect_command=False)
        time.sleep(0.2)
        self.type_text(path)
        time.sleep(0.1)
        # Commit path entry.
        self.key("Return", expect_command=False)
        # Empirical: NSOpenPanel needs a noticeable beat after the
        # "Go to folder" prompt dismisses + file selection updates,
        # before the dialog's default-button (Open) is wired to Return.
        # 0.3s raced the prompt-dismiss animation on the VM and the
        # second Return became a no-op, leaving the dialog hung with
        # the right file selected. 0.6s holds.
        time.sleep(0.6)
        # Confirm selection (presses default button = Open). The final
        # Return DOES dismiss the dialog and trigger an importer/open
        # command on the JVE side, but the command may take longer than
        # the 2s barrier (large project loads), so we still skip the
        # barrier here and rely on the post-dialog responsiveness poll.
        self.key("Return", expect_command=False)
        # Wait for dialog to close — there is no signal we can poll
        # cleanly from outside, so block on a settle window. Importers
        # tend to take noticeable wall time; the caller should follow
        # with a wait_for() on the expected post-state.
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            time.sleep(0.1)
            try:
                # If JVE is responsive, the modal sheet is closed.
                self.eval("return 1")
                return
            except (JVERunnerError, JVEEvalError):
                continue
        raise JVERunnerError(
            f"pick_file_in_open_dialog: JVE did not respond within "
            f"{timeout}s after dialog Return — see {self.stdout_log}")

    def get_command_count(self) -> int:
        """Snapshot the top-level command-event counter.

        Each completed user-visible command (SelectClips from a click,
        ToggleClipEnabled from D, Delete, undo via Cmd+Z, etc.) bumps
        this once. Smoke harness uses this to barrier "UI action → command
        done" 1:1 — see ``wait_for_command_after`` below.
        """
        return self.eval_int(
            "return require('core.command_manager').get_top_level_event_count()")

    def wait_for_command_after(self, snap: int, timeout: float = 0.5) -> None:
        """Block until the top-level command-event counter exceeds ``snap``.

        Joe's contract (2026-05-29): every UI action provokes a command
        1:1; once the root command completes, the UI is ready for the
        next action. ``click()`` / ``key()`` call this immediately after
        posting the OS input so the next eval reads post-command state,
        not racing in-flight dispatch.

        Event-driven: a single socket request ``WAIT_BUMP <snap>
        <timeout_ms>`` whose reply is DEFERRED inside JVE until the next
        ``end_command_event``/``undo_interactive``/``redo_interactive``
        bumps the counter past ``snap`` (or a Qt timer fires for
        timeout). JVE's main event loop runs normally during the wait;
        neither side polls or spins. Replies arrive on the same socket
        Python is reading from, so this is one read for one write.

        Raises if no command bumped the counter within ``timeout`` — that
        means the UI action was lost (osascript dropped it, JVE wasn't
        frontmost, click landed off-target) or the action genuinely
        doesn't fire a command (selection on empty area, focus shift).
        Callers that send non-commanding input should not barrier.
        """
        timeout_ms = max(1, int(timeout * 1000))
        # WAIT_BUMP is a dedicated protocol verb (NOT a Lua expression).
        # debug_terminal.cpp::handleLine routes it to handleWaitBump,
        # which checks the counter immediately and either replies
        # ("true,<count>") or defers the reply via a single-shot QTimer
        # and the Lua-side bump callback. Either way exactly one line
        # comes back, the same shape every eval reads.
        reply = self.eval(f"WAIT_BUMP {snap} {timeout_ms}")
        ok_str, _, count_str = reply.partition(",")
        if ok_str != "true":
            raise JVERunnerError(
                f"wait_for_command_after: no command completed within {timeout}s "
                f"after the input (snap={snap}, current={count_str}). "
                f"The keystroke/click was lost OR did not provoke a command. "
                f"If the action is non-commanding, use the raw click/key path.")

    def wait_for(self, lua_predicate: str, timeout: float = 5.0,
                 poll_interval: float = 0.1) -> None:
        """Poll ``eval_bool(lua_predicate)`` until true or timeout.

        Raises JVERunnerError on timeout, with the last predicate value
        captured for diagnosis.
        """
        deadline = time.monotonic() + timeout
        last_val = None
        last_err = None
        while time.monotonic() < deadline:
            try:
                last_val = self.eval_bool(lua_predicate)
                if last_val:
                    return
            except (JVERunnerError, JVEEvalError) as e:
                last_err = e
            time.sleep(poll_interval)
        if last_err is not None:
            raise JVERunnerError(
                f"wait_for: predicate raised within {timeout}s: {last_err}\n"
                f"  predicate: {lua_predicate}")
        raise JVERunnerError(
            f"wait_for: predicate never true within {timeout}s "
            f"(last value: {last_val})\n  predicate: {lua_predicate}")

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

    def _wait_for_layout_settle(self) -> None:
        """Block until the JVE main window has finished its initial layout
        pass. The socket file appears before Qt completes the first paint
        + layout pass — on the VM that gap is ~100 ms during which the
        video panel widget shifts ~48 px down once. A click_clip()
        computed during the pre-jump window lands off the clip after the
        shift, with no clean detection from inside the test.

        Polls `video_widget`'s global Y until two consecutive 50 ms
        samples agree, then returns. Fails loudly on timeout (Qt didn't
        settle within ~3 s — symptom of a deeper layout bug).
        """
        deadline = time.monotonic() + 3.0
        prev_y = None
        stable_samples = 0
        while time.monotonic() < deadline:
            try:
                y = int(self.eval(
                    "local qc = require('core.qt_constants'); "
                    "local tp = require('ui.timeline.timeline_panel'); "
                    "if not tp.video_widget then return -1 end; "
                    "local _, gy = qc.WIDGET.MAP_TO_GLOBAL(tp.video_widget, 0, 0); "
                    "return gy or -1").strip())
            except (JVERunnerError, JVEEvalError):
                time.sleep(0.05)
                continue
            if y >= 0 and y == prev_y:
                stable_samples += 1
                if stable_samples >= 2:
                    return
            else:
                stable_samples = 0
                prev_y = y
            time.sleep(0.05)
        raise JVERunnerError(
            "JVE main window layout did not stabilize within 3 s after "
            "socket connect. video_widget global Y kept changing. Symptom "
            "of a deeper layout bug — see stdout_log.")

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

    def fresh_copy(self, name_or_id: str) -> Path:
        """Return a writable .jvp copy of the Anamnesis template, named ``name_or_id``.

        Per Joe's 2026-05-30 directive, all smokes operate on a copy of
        the anamnesis-derived template (rich real-world project with
        media + clips + sequences). No blank-fixture variant — the
        anamnesis project has plenty of substrate for any test.
        """
        slug = name_or_id.replace("/", "_").replace(":", "_").replace(".", "_")
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
