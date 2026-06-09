"""
Spec 023 — Color-menu bridge commands dispatch cleanly through the real
menu path AND reach their FR-023 completion surface.

Pins FR-023's "user-invocable through menu / shortcut / programmatic"
PLUS the completion-contract teeth that prevent the next regression
from false-greening this gate. Two assertions per menu pick:

  1. No forbidden marker (LUA CALLBACK ERROR / handler-failure /
     raw assertion) lands in the suite-log slice. Catches the
     historical bug (schema validator hard-failing on a missing
     `on_complete` arg the menu can't supply).

  2. The per-op `bridge_completion_count` advanced by at least one.
     Catches the bug "no Lua error in the log slice" alone CAN'T
     catch: a future regression that pcall-swallows the async tail
     before it reaches `bridge_completion.notify`. That would leave
     no error marker — the user sees nothing happen and the smoke
     reports green. The counter delta makes "the async tail
     actually reached notify()" load-bearing.

The bridge commands' deeper async behaviour (helper spawn, Resolve
handshake, the specific structured error code returned) is out of
scope here — Resolve is not expected to be running during smoke.
A `helper_unavailable` outcome surfaced via signal + counter
increment is a PASS for this smoke; the menu wiring did its job.

The four menu items exercised:
    Color > Send Sequence to Resolve...
    Color > Connect to Resolve Project
    Color > Sync Grades from Resolve
    Color > Sync Edits from Resolve

Three of the four are sequence-scoped and gated by an active sequence
(menu_system.lua PER_SEQUENCE_COMMAND_NAMES). The Anamnesis template
boots with a sequence loaded into the record tab, so the gate passes
without extra setup beyond `ensure_record_tab()`.

Forbidden markers mirror `test_keymap_dispatch_no_crash.py` — same
boxed banner from the C++ Lua-callback shim, same handler-failure
surface from signals.lua. If a future Color command's menu picks
schedules an async error through a different path that doesn't print
one of these, add the new marker here AND in the L2 dispatch test so
both gates stay aligned.
"""

import time
import unittest
from pathlib import Path

from tests.live.runner.case import JVESmokeCase

FORBIDDEN_MARKERS: tuple[bytes, ...] = (
    b"LUA CALLBACK ERROR",
    b"ERROR: Handler failure",
    b"ERROR: assertion failed",
)

# Each menu pick can schedule deferred work via single_shot_timer; give
# Poll ceiling for the bridge_completion counter to tick after a menu pick.
# Replaces an earlier fixed 0.30s sleep that was both wasteful on a fast
# local run AND too short for a real-Resolve handshake (where the verb
# roundtrip + helper_supervisor.ensure_client can exceed 300ms easily).
# Poll-with-ceiling means: snap fast when the counter advances, and surface
# a clean timeout error if it doesn't — instead of false-failing on the
# wrong axis. 6s covers helper_supervisor's 5s CONNECT_TIMEOUT_MS plus a
# little slack for the notify path to land.
BRIDGE_COUNTER_POLL_TIMEOUT_S = 6.0

BRIDGE_MENU_ITEMS: tuple[str, ...] = (
    "Color > Send Sequence to Resolve...",
    "Color > Connect to Resolve Project",
    "Color > Sync Grades from Resolve",
    "Color > Sync Edits from Resolve",
)


class TestBridgeMenuDispatch(JVESmokeCase):
    """Each Color-menu bridge command's menu pick lands cleanly — no
    LUA CALLBACK ERROR, no handler-failure log line.

    One method per menu item so a single broken command surfaces as
    one named failure rather than aborting the loop and masking the
    rest. Methods share the per-class anamnesis copy by design (see
    SMOKE_TEST_AUTHORING.md); no menu pick mutates anything that would
    poison a sibling method's baseline — Connect writes only to
    resolve_bridge_link, the others either author a side-file or fail
    at helper-unavailable before touching any model state.
    """

    def setUp(self) -> None:
        super().setUp()
        # Sequence-scope items (SendToResolve, SyncGrades*, SyncEdits*)
        # are greyed out unless an active sequence exists. The template
        # has one bound at the record tab; this just confirms.
        self.ensure_record_tab()

        # Force-load the four bridge command modules so their
        # register_op calls fire (and the completion counter is
        # initialized to 0) BEFORE this method's `snap_before` reads
        # it. The codebase loads command modules lazily on first
        # dispatch (`command_registry.load_command_module`), so without
        # this warmup, `bridge_completion_count("X")` on a fresh JVE
        # session would assert "op 'X' not registered" — the
        # fail-fast guard in bridge_completion.lua firing correctly,
        # just at the wrong audience. Idempotent: `require` is cached.
        self.eval('require("core.commands.send_to_resolve")')
        self.eval('require("core.commands.connect_to_resolve_project")')
        self.eval('require("core.commands.sync_grades_from_resolve")')
        self.eval('require("core.commands.sync_edits_from_resolve")')

    # ── log scraping helpers (mirrors test_keymap_dispatch_no_crash) ──

    def _suite_log_path(self) -> Path:
        return Path("/tmp/jve_smoke") / "suite.log"

    def _suite_log_size(self) -> int:
        p = self._suite_log_path()
        return p.stat().st_size if p.exists() else 0

    def _suite_log_slice(self, start: int) -> bytes:
        p = self._suite_log_path()
        assert p.exists(), f"suite log missing: {p}"
        with p.open("rb") as fh:
            fh.seek(start)
            return fh.read()

    def _scan_forbidden(self, blob: bytes) -> list[bytes]:
        return [m for m in FORBIDDEN_MARKERS if m in blob]

    # ── the assertion shape, factored so per-item methods stay thin ──

    def _bridge_count(self, op_name: str) -> int:
        return self.eval_int(
            f"return require('core.debug_helpers')"
            f".bridge_completion_count('{op_name}')")

    def _assert_menu_pick_clean(self, menu_path: str, op_name: str) -> None:
        count_before = self._bridge_count(op_name)
        before = self._suite_log_size()
        try:
            self.menu_pick(menu_path)
        except Exception as e:
            # menu_pick itself failed (AppleScript path miss, JVE not
            # frontmost, menu not built). Fail with maximum context so
            # the reader knows the issue is upstream of the bridge
            # command — the menu item literally couldn't be clicked.
            self.fail(
                f"menu_pick({menu_path!r}) raised before reaching the "
                f"command: {type(e).__name__}: {e}. Either the menu "
                f"path doesn't match menus.xml, JVE is not frontmost, "
                f"or the menu hasn't been built yet (check that the "
                f"anamnesis template opens successfully — see "
                f"suite.log).")
        # Poll the per-op completion counter instead of sleeping a fixed
        # margin. The existing post-loop assertion (below) surfaces the
        # "counter never advanced" case with full log context, so on
        # timeout we just fall through.
        poll_deadline = time.monotonic() + BRIDGE_COUNTER_POLL_TIMEOUT_S
        while time.monotonic() < poll_deadline:
            if self._bridge_count(op_name) > count_before:
                break
            time.sleep(0.05)
        new_bytes = self._suite_log_slice(before)
        markers_hit = self._scan_forbidden(new_bytes)
        if markers_hit:
            excerpt = new_bytes.decode("utf-8", errors="replace")
            if len(excerpt) > 2500:
                excerpt = excerpt[:2500] + "\n... (truncated)"
            marker_names = ", ".join(m.decode() for m in markers_hit)
            self.fail(
                f"{menu_path!r}: forbidden marker(s) in suite-log slice "
                f"after menu pick [{marker_names}].\n"
                f"This is FR-023 dispatch broken: the menu entry exists "
                f"but the command crashes at the schema validator (or "
                f"deeper) before the async surface can do anything "
                f"useful. The user clicked, JVE printed a stack trace, "
                f"nothing happened.\n"
                f"------- new log slice -------\n"
                f"{excerpt}\n"
                f"-----------------------------")

        # Positive completion assertion: the async tail (or the
        # register-side pcall) must have reached bridge_completion.notify.
        # Without this, a future regression that silently swallows the
        # completion path would false-green via "no log marker."
        count_after = self._bridge_count(op_name)
        if count_after <= count_before:
            excerpt = new_bytes.decode("utf-8", errors="replace")
            if len(excerpt) > 2500:
                excerpt = excerpt[:2500] + "\n... (truncated)"
            self.fail(
                f"{menu_path!r}: no LUA CALLBACK ERROR but the FR-023 "
                f"completion counter for {op_name} did not advance "
                f"({count_before} → {count_after}). The async tail did "
                f"NOT reach bridge_completion.notify — somewhere along "
                f"the path, a code branch returned without going through "
                f"the unified completion surface. The user sees nothing "
                f"happen; the *_completed signal never fires; toast / "
                f"dialog / subscriber stay frozen.\n"
                f"------- new log slice -------\n"
                f"{excerpt}\n"
                f"-----------------------------")

    # ── one method per menu item (named for stable alphabetical order) ─

    def test_01_color_connect_to_resolve_project(self) -> None:
        self._assert_menu_pick_clean(
            "Color > Connect to Resolve Project",
            "ConnectToResolveProject")

    def test_02_color_send_sequence_to_resolve(self) -> None:
        self._assert_menu_pick_clean(
            "Color > Send Sequence to Resolve...",
            "SendToResolve")

    def test_03_color_sync_grades_from_resolve(self) -> None:
        self._assert_menu_pick_clean(
            "Color > Sync Grades from Resolve",
            "SyncGradesFromResolve")

    def test_04_color_sync_edits_from_resolve(self) -> None:
        self._assert_menu_pick_clean(
            "Color > Sync Edits from Resolve",
            "SyncEditsFromResolve")


if __name__ == "__main__":
    unittest.main()
