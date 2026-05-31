"""
L2 dispatch-doesn't-crash gate — for every keymap binding that isn't
``l2``-exempt in ``tests/smoke/runner/keymap_exempt.py``, focus the
binding's first scope, press the key, and assert the suite log gained
no fresh dispatch-failure markers as a result.

What this catches: two failure classes per binding —

  1. Dispatch crash: the press reached the QShortcut handler but the
     handler threw (Blade-class SPEC required-args miss, command
     SPEC change, command_manager auto-inject regression, etc.).
     Caught via forbidden log markers in the fresh slice.

  2. Silent never-fire: the press did NOT reach the QShortcut
     handler at all (JVE not frontmost, accessibility permission
     lapsed, focus widget nil, scope mismatch, combo never
     registered). Caught via QShortcut-handler fire-counter delta
     (keyboard_shortcut_registry.get_shortcut_fire_count()) — if the
     counter didn't advance for the press AND no crash logged, the
     binding is silently broken. Added 2026-05-25 after sibling
     Claude's instrumentation found L2 false-greening every X/I/O
     press while osascript activation was failing; see
     memory/todo_l2_silent_pass_hole.md.

What this does NOT catch: behavioral correctness of the command
(that's the per-binding L3 smoke's job). A binding that dispatches
cleanly but does the wrong thing passes this test; a separate L3
case is required to pin the intent.

Forbidden log markers (any of these in the new log slice flunks):
  - ``LUA CALLBACK ERROR`` (the boxed banner the C++ shim prints)
  - ``ERROR: Handler failure`` (signals.lua handler-failure surface)
  - ``ERROR: assertion failed`` (raw lua assert via xpcall)

Per-binding output: when a press triggers a forbidden marker, the
failure message names the binding, the scope chosen, and the full new
log slice so the reader can diagnose without digging through
suite.log themselves.

Run:
    python3 -m unittest tests.smoke.cases.test_keymap_dispatch_no_crash -v
"""

import sys
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.smoke.runner.case import JVESmokeCase
from tests.smoke.runner.coverage import list_keymap_bindings
from tests.smoke.runner.keymap_exempt import l2_skip_reason


# Substrings that mark a dispatch-time crash. Match on bytes to skip
# decoding overhead — the log is plain ASCII for these markers.
FORBIDDEN_MARKERS: tuple[bytes, ...] = (
    b"LUA CALLBACK ERROR",
    b"ERROR: Handler failure",
    b"ERROR: assertion failed",
)

# Settle window after a press before reading the log. Runner's
# ``key()`` already sleeps 50ms; we add a small extra margin because
# some dispatches schedule single_shot_timers whose errors land
# asynchronously.
SETTLE_AFTER_PRESS_S = 0.15


class TestKeymapDispatchNoCrash(JVESmokeCase):
    """Every non-l2-exempt binding dispatches without a Lua callback
    error or handler-failure log line."""

    # ── setUp: seed state inside content ──────────────────────────────
    #
    # Without seeded state, most bindings cascade-fail with "command
    # can't operate in a fresh project" — playhead at 0 (outside the
    # 89750+ Anamnesis TC start), no source loaded, no clips selected.
    # That's not the regression class L2 is meant to detect. Seed once
    # per fresh project copy so the press-all loop sees a realistic
    # working state.

    def setUp(self) -> None:
        super().setUp()
        self.ensure_record_tab()
        # Cache the seed clip once per test (the fixture's clip set
        # doesn't shift across the test method). Re-seeded BEFORE each
        # press via _seed_state — alphabetical iteration plus stateful
        # commands (DeselectAll, SetMark, GoToStart, ...) would
        # otherwise drift the realistic-state baseline that L2 needs
        # to isolate each binding's dispatch from state pollution.
        info = self.eval_str(
            "return require('core.debug_helpers').first_armed_video_clip(48)")
        assert info, "fixture has no armed video clip with body"
        parts = info.split("|", 5)
        self._seed_clip_id = parts[0]
        self._seed_rec_seq = parts[4]
        self._seed_frame = int(parts[2]) + 24

    def _seed_state(self) -> None:
        """Restore the per-press baseline: playhead inside the seed
        clip + just that clip selected. Idempotent. Click-on-clip
        tolerates the cached id no longer existing (e.g., after an
        earlier Delete press) — click_clip would fail, so guard with
        clip_exists; the binding under test then dispatches with an
        empty selection, which is itself a valid contract to
        smoke-check."""
        self.move_playhead_to(self._seed_frame)
        still_there = self.eval_bool(
            f"return require('core.debug_helpers').clip_exists('{self._seed_clip_id}')")
        if still_there:
            self.click_clip(self._seed_clip_id)

    def _unwind_press(self) -> None:
        """Press Cmd+Z to roll back any undoable mutation the press
        just made. No-op if the undo stack is empty. Keeps the fixture
        clip-set intact across the loop so later presses see a
        populated timeline."""
        self.key("Cmd+Z")

    # ── log scraping helpers ──────────────────────────────────────────

    def _suite_log_path(self) -> Path:
        # Mirrors tests/smoke/runner/case.py:_ensure_runner().
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

    def _scan_for_forbidden(self, blob: bytes) -> list[bytes]:
        """Return the list of forbidden markers present in ``blob``.
        Empty list = clean."""
        return [m for m in FORBIDDEN_MARKERS if m in blob]

    # ── focus helper ──────────────────────────────────────────────────

    def _focus_for_binding(self, scopes: tuple[str, ...]) -> str:
        """Focus the panel that owns the binding's scope. Global
        bindings get ``timeline`` as the default — the main window's
        QShortcut.ApplicationShortcut context fires regardless, but
        forcing a known focus keeps test state deterministic across
        iterations."""
        if scopes:
            target = scopes[0]
        else:
            target = "timeline"
        self.focus_panel(target)
        return target

    # ── the loop ──────────────────────────────────────────────────────

    def test_every_non_exempt_binding_dispatches_without_crash(self) -> None:
        bindings = list_keymap_bindings()
        # Stable order for diagnosability. Sort by combo+scope so a
        # run-to-run diff of failures lines up.
        bindings.sort(key=lambda b: (b.combo, b.scopes))

        failures: list[str] = []
        pressed_count = 0
        skipped_count = 0
        last_pressed_repr = "<none>"

        for b in bindings:
            skip = l2_skip_reason(b)
            if skip is not None:
                skipped_count += 1
                continue

            # Diagnostic: any subsequent eval-timeout failure can be
            # attributed to THIS press because it's the most recent one
            # to have run. stderr goes to test runner output so the
            # last printed line names the wedge-trigger.
            print(f"[L2] pressing {b!r}", file=sys.stderr, flush=True)

            try:
                # Re-seed BEFORE every press so each binding's dispatch
                # is tested from the same realistic state — playhead
                # inside a clip, that clip selected. Without this,
                # alphabetical iteration drifts state (DeselectAll,
                # GoToStart, mark clears, panel-focus switches) and
                # later bindings hit "no relevant state" rather than
                # the genuine dispatch-time bugs L2 is meant to detect.
                self._seed_state()
                focus = self._focus_for_binding(tuple(b.scopes))
            except Exception as e:
                # focus_panel timed out → JVE is wedged by whatever
                # came before. Fail with maximum context.
                self.fail(
                    f"L2 dispatch gate aborted: JVE became unresponsive "
                    f"BEFORE this press could even focus its scope. The "
                    f"PRIOR press is the suspect.\n"
                    f"  this binding (couldn't press): {b!r}\n"
                    f"  last pressed binding:           {last_pressed_repr}\n"
                    f"  pressed_count so far:           {pressed_count}\n"
                    f"  eval-during-focus error:        "
                    f"{type(e).__name__}: {e}\n"
                    f"Inspect the tail of /tmp/jve_smoke/suite.log for the "
                    f"cascading error pattern that the last-pressed binding "
                    f"set off.")
            before = self._suite_log_size()
            fires_before = self.eval_int(
                "return require('core.keyboard_shortcut_registry')"
                ".get_shortcut_fire_count()")
            try:
                # L2 deliberately hammers EVERY keymap entry — most fire a
                # command, but plenty (focus shifts, modal dismissals,
                # already-at-end navigation) don't. The default barrier
                # would wait 2 s × non-commanding presses = many minutes.
                # We check command activity below via fire_count anyway.
                self.key(b.combo, expect_command=False)
            except Exception as e:
                failures.append(
                    f"  {b!r}: runner.key() raised before press completed: "
                    f"{type(e).__name__}: {e}")
                continue
            last_pressed_repr = repr(b)
            time.sleep(SETTLE_AFTER_PRESS_S)
            new_bytes = self._suite_log_slice(before)
            markers_hit = self._scan_for_forbidden(new_bytes)
            fires_after = self.eval_int(
                "return require('core.keyboard_shortcut_registry')"
                ".get_shortcut_fire_count()")
            pressed_count += 1
            if fires_after == fires_before and not markers_hit:
                # Positive-fire check (silent-pass guard, see
                # memory/todo_l2_silent_pass_hole.md). "No crash log"
                # alone gives false-green on bindings the key never
                # reached — wrong frontmost app, accessibility lapsed,
                # focus widget nil, scope mismatch. Asserting the
                # QShortcut handler's monotonic fire counter advanced
                # is the cheap positive signal that the press actually
                # arrived. If a binding genuinely doesn't route through
                # a QShortcut handler (none today, but possible
                # future), this guard becomes a tripwire and the
                # binding needs an l2-exempt entry.
                failures.append(
                    f"  {b!r} (focus={focus}): silent-pass — no crash "
                    f"marker, but QShortcut handler fire count did not "
                    f"advance ({fires_before} → {fires_after}). The key "
                    f"never reached the handler. Likely causes (rank "
                    f"order): JVE not frontmost (osascript activation "
                    f"failing — check System Settings → Privacy & "
                    f"Security → Automation for the parent terminal); "
                    f"focus widget nil after focus_panel; binding scope "
                    f"mismatch with the focused panel; combo never "
                    f"registered as a QShortcut. See "
                    f"memory/todo_l2_silent_pass_hole.md.")
            # Roll back any undoable mutation the press just made so
            # the next iteration's seed clip and frame remain valid.
            # No-op for non-undoable commands (Cmd+A, Cmd+1, marks
            # commands route to set_marks individually).
            self._unwind_press()
            if markers_hit:
                # Truncate the slice so failure messages stay readable;
                # the boxed LUA CALLBACK ERROR banner is the most useful
                # bit and is always near the top of the new slice.
                excerpt = new_bytes.decode("utf-8", errors="replace")
                if len(excerpt) > 2000:
                    excerpt = excerpt[:2000] + "\n... (truncated)"
                marker_names = ", ".join(m.decode() for m in markers_hit)
                failures.append(
                    f"  {b!r} (focus={focus}): forbidden marker(s) "
                    f"after press [{marker_names}]:\n"
                    f"------- new log slice -------\n"
                    f"{excerpt}\n"
                    f"-----------------------------")

        if failures:
            joined = "\n\n".join(failures)
            self.fail(
                f"L2 dispatch gate: {len(failures)} of {pressed_count} "
                f"pressed binding(s) triggered a dispatch-failure marker "
                f"(out of {len(bindings)} total, {skipped_count} l2-exempt).\n\n"
                f"Per-binding details follow. Each entry names the binding, "
                f"the scope focused for the press, and the new log slice "
                f"that contains the forbidden marker.\n\n"
                f"{joined}\n\n"
                f"How to triage:\n"
                f"  - If the failure is a SPEC required-param miss, the "
                f"binding's command needs either a UI adapter (like "
                f"BladeAtPlayhead, see specs/013-timeline-placements-as/"
                f"contracts/commands.md), an entry in command_manager's "
                f"auto-inject set, or name=value tokens in the keymap.\n"
                f"  - If the failure is a handler-failure in a listener, "
                f"the listener's contract is being violated by this "
                f"command's signal payload.\n"
                f"  - If a binding genuinely can't be smoked here "
                f"(opens a dialog, requires modal recovery), add an "
                f"``l2`` reason to its entry in keymap_exempt.EXEMPT.")


if __name__ == "__main__":
    unittest.main()
