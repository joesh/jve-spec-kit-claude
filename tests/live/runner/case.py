"""
JVESmokeCase — unittest.TestCase base for smoke tests.

Owns one long-lived JVERunner for the entire TestCase subclass (or
TestSuite, via class-attribute sharing) — bring-up amortized across
every test method.

Pattern:

    from tests.live.runner.case import JVESmokeCase

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
from typing import NamedTuple, Optional

from tests.live.runner.jve_runner import (
    Fixtures, JVERunner, JVERunnerError, JVEEvalError,
)


class ArmedClip(NamedTuple):
    """Decoded result of ``debug_helpers.first_armed_video_clip()``.

    Fields mirror the pipe-encoded payload from the Lua side; the wire
    format is positional because the debug-terminal repr cap can't carry
    nested tables. ``Case.first_armed_video_clip()`` is the only place
    that should split the payload — test bodies receive an ArmedClip.
    """
    id: str
    track_id: str
    seq_start: int
    duration: int
    rec_seq: str
    master_seq_id: str


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
        # Start JVE on a throwaway copy of the template, NOT the template
        # itself. JVE writes to its startup project's SQLite WAL as the
        # session runs (selection state, viewport scroll, transient cache
        # flushes); pointing it at template.jvp directly meant the
        # template was getting written to (template.jvp-wal grows to
        # >100MB) and per-class fresh_copy() snapshots were inheriting
        # that drift. Each suite gets a brand-new startup-session file;
        # the template stays pristine for class fresh-copies.
        startup_jvp = _singleton_fixtures.fresh_copy("startup_session")
        _singleton_runner = JVERunner(
            startup_project=startup_jvp,
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
    """Base class. All subclasses share one long-lived JVE for the suite.

    Project lifecycle (revised 2026-05-30 per Joe's directive
    "instead of blank fixtures how about just File/New Project? ...
    group tests that can operate on the same data and not keep clearing
    the project. We WANT to find cross command contamination."):

    Each TestCase class opens ONE fresh copy of the Anamnesis-derived
    template at setUpClass; test methods within the class share that
    project and accumulate state. Cross-command contamination across
    methods is intentional surface — it's exactly the kind of stress
    no clean-state-per-test suite ever exercises.

    Default: methods share state. To opt into a fresh start before a
    specific method, override setUp and call `self._reset_to_template()`.
    """

    # Type-checking annotations for the instance attributes setUp binds.
    # The actual values come from _ensure_runner() — there's no class-level
    # cache because the singleton can be respawned mid-suite (a wedged
    # test's force-shutdown), so a cls._runner would silently go stale.
    runner: JVERunner
    _fixtures: Fixtures

    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        runner, fixtures = _ensure_runner()
        # ONE fresh anamnesis-template copy per TestCase class. All
        # methods in the class operate on this copy in sequence; no
        # per-method reset. Naming the copy after cls.__qualname__
        # keeps the on-disk file traceable to its owning class.
        jvp = fixtures.fresh_copy(f"class__{cls.__qualname__}")
        runner.open_project(jvp)
        runner.foreground()
        # Stash the project + the runner identity so setUp can detect
        # a mid-class respawn (a wedged test that triggered force-
        # shutdown in `_ensure_runner`). Without this, the respawned
        # runner would silently leave the class's remaining methods
        # executing against `startup_session.jvp`, not their class
        # project — undetectable cross-class contamination.
        cls._class_jvp = jvp  # type: ignore[attr-defined]
        cls._setup_runner_seq = runner.instance_seq  # type: ignore[attr-defined]

    # No tearDownClass: the suite-wide runner is owned by atexit. Per-
    # class teardown would kill JVE between TestCase classes — defeats
    # the long-lived design.

    def setUp(self) -> None:
        super().setUp()
        self.runner, self._fixtures = _ensure_runner()
        # Detect mid-class respawn: if `_ensure_runner` returned a
        # different runner than `setUpClass` saw, JVE was force-shut
        # and restarted (its startup project is now the throwaway
        # session copy, not this class's project). Re-open this
        # class's project so remaining methods run against the right
        # data. The respawned runner is then "re-adopted" as the
        # canonical class runner for any later respawn-detection.
        cls = type(self)
        expected_seq = getattr(cls, "_setup_runner_seq", None)
        if expected_seq is not None and self.runner.instance_seq != expected_seq:
            self.runner.open_project(cls._class_jvp)  # type: ignore[attr-defined]
            cls._setup_runner_seq = self.runner.instance_seq  # type: ignore[attr-defined]
        # Re-foreground in case a prior test stole focus (osascript
        # dialogs, modals, the host user clicking elsewhere).
        self.runner.foreground()

    def _reset_to_template(self) -> None:
        """Optional opt-in: open a fresh anamnesis-template copy mid-suite.

        Use sparingly — the design point is shared state. Reach for this
        only when a specific test method genuinely needs a pristine
        baseline (e.g. testing project-open behavior itself, or
        recovering from an intentional destructive test that left the
        project unusable for downstream methods).
        """
        jvp = self._fixtures.fresh_copy(f"reset__{self.id()}")
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

    def key(self, combo: str, expect_command: bool = True) -> None:
        self.runner.key(combo, expect_command=expect_command)

    def click(self, x: int, y: int, double: bool = False) -> None:
        self.runner.click(x, y, double=double)

    def click_clip(self, clip_id: str, right: bool = False, double: bool = False) -> None:
        """Click on a clip in the displayed timeline at its visual center.

        Queries `core.debug_helpers.clip_global_center(clip_id)` for the
        screen coords and posts a real OS click via the runner. This is
        the canonical replacement for `command_manager.execute('SelectClips')`
        in test setUp.

        Asserts loudly if the clip isn't on the displayed sequence (would
        return empty coords) — silent zero-coord clicks would land in
        the menu bar and confuse downstream tests.
        """
        coords = self.eval_str(
            f"return require('core.debug_helpers').clip_global_center('{clip_id}')")
        self.assertNotEqual("", coords, (
            f"click_clip({clip_id!r}): debug_helpers returned empty coords. "
            f"Clip not on the displayed sequence — switch tabs first, or "
            f"the clip_id is stale."))
        gx_s, gy_s = coords.split(",", 1)
        gx, gy = int(gx_s), int(gy_s)
        # Joe contract: a click on a clip provokes SelectClips 1:1. Snap
        # the command counter before clicking and block until it bumps,
        # so the next eval (selection_count, mode-readout, key-press)
        # reads post-command state instead of racing in-flight dispatch.
        snap = self.runner.get_command_count()
        self.runner.click(gx, gy, right=right, double=double)
        self.runner.wait_for_command_after(snap)
        # The barrier only proves SOME command committed — not that the
        # click landed on this specific clip. A miss on the clip body
        # fires DeselectAll (also bumps), and the test would proceed
        # with empty selection and silently fail downstream. Verify the
        # clip is actually selected here so the failure surfaces at the
        # helper, not 3 lines later in a key-doesn't-toggle assertion.
        selected = self.eval_str(
            "local sel = require('ui.timeline.timeline_state').get_selected_clips(); "
            "assert(sel, 'get_selected_clips returned nil — timeline_state not initialized'); "
            "local parts = {}; "
            "for i, c in ipairs(sel) do "
            "  assert(type(c) == 'table' and type(c.id) == 'string', "
            "    'get_selected_clips()[' .. i .. '] missing .id (got ' .. type(c) .. ')'); "
            "  parts[i] = c.id "
            "end; "
            "return table.concat(parts, ',')")
        selected_set = set(s for s in selected.split(",") if s)
        # Real-NLE behavior (Resolve, verified 2026-05-30): clicking an
        # already-selected clip in a multi-selection is a no-op — the
        # press arms a drag of the whole group, the no-drag release leaves
        # the multi-selection intact. So `click_clip` can only assert
        # that the target IS in the resulting selection, NOT that it's
        # the only thing selected. A test that needs exclusive selection
        # of `clip_id` must explicitly deselect first (e.g. Cmd+Shift+A).
        if clip_id not in selected_set:
            diag = self.eval_str(
                f"return require('ui.timeline.timeline_panel')"
                f".get_clip_click_diagnostic('{clip_id}')")
            raise AssertionError(
                f"click_clip({clip_id!r}) at screen ({gx},{gy}): "
                f"clip NOT in selection after click. got {len(selected_set)} "
                f"clip(s) selected; target absent. Either the click missed "
                f"(landed off the clip's body) or hit a different widget. "
                f"Cliclick coords vs widget bounds:\n"
                f"  post-click diagnostic: {diag}\n"
                f"  Compare global_center in diagnostic to the actual click coords "
                f"({gx},{gy}) — divergence means the widget moved between coord "
                f"compute and click send.")

    def click_clip_edge(self, clip_id: str, edge_type: str,
                        trim_type: str) -> None:
        """Click on a clip's edge so the edge_picker selects it as the
        requested trim_type (ripple or roll).

        Resolves the pixel via
        ``timeline_panel.get_clip_edge_global_point_for_test`` which
        picks a cursor offset that lands in the correct picker zone
        (center → roll, outside center → ripple on the clip-body side).
        After the click, asserts the requested edge is actually in
        ``timeline_state.get_selected_edges()`` with the requested
        ``trim_type`` — surfaces picker mismatches at this helper, not
        downstream where a missing edge selection would silently
        produce wrong nudge behaviour.

        For roll, the picker selects edges on BOTH sides of the
        boundary; this asserts ``clip_id``'s edge is among them.
        """
        if edge_type not in ("in", "out"):
            raise ValueError(f"edge_type must be 'in'|'out', got {edge_type!r}")
        if trim_type not in ("ripple", "roll"):
            raise ValueError(f"trim_type must be 'ripple'|'roll', got {trim_type!r}")
        coords = self.eval_str(
            "return require('core.debug_helpers').clip_edge_global_point("
            f"'{clip_id}', '{edge_type}', '{trim_type}')")
        self.assertNotEqual("", coords, (
            f"click_clip_edge({clip_id!r},{edge_type!r},{trim_type!r}): "
            f"debug_helpers returned empty coords."))
        gx_s, gy_s = coords.split(",", 1)
        gx, gy = int(gx_s), int(gy_s)
        snap = self.runner.get_command_count()
        self.runner.click(gx, gy)
        self.runner.wait_for_command_after(snap)

        # Post-condition: the requested edge is in the selection with
        # the requested trim_type. CSV-encode {clip_id|edge_type|trim_type}
        # rows for cheap parsing.
        rows = self.eval_str(
            "local edges = require('ui.timeline.timeline_state')"
            ".get_selected_edges(); "
            "assert(edges, 'get_selected_edges returned nil — timeline_state not initialized'); "
            "local parts = {}; "
            "for i, e in ipairs(edges) do "
            "  parts[i] = tostring(e.clip_id) .. '|' "
            "    .. tostring(e.edge_type) .. '|' "
            "    .. tostring(e.trim_type) "
            "end; "
            "return table.concat(parts, ',')")
        selected = []
        for row in rows.split(","):
            row = row.strip()
            if not row:
                continue
            try:
                cid, etype, ttype = row.split("|", 2)
            except ValueError:
                continue
            selected.append((cid, etype, ttype))
        wanted = (clip_id, edge_type, trim_type)
        if wanted not in selected:
            raise AssertionError(
                f"click_clip_edge({clip_id!r},{edge_type!r},{trim_type!r}) "
                f"at screen ({gx},{gy}): requested edge NOT in selection. "
                f"Got {len(selected)} edge(s): {selected}. The click likely "
                f"landed off the picker's zone — check the boundary pixel "
                f"vs widget bounds, viewport zoom, and any partner-clip "
                f"width constraints raised by the helper.")

    def right_click_clip(self, clip_id: str) -> None:
        self.click_clip(clip_id, right=True)

    def double_click_clip(self, clip_id: str) -> None:
        self.click_clip(clip_id, double=True)

    def type_in_tc_field(self, text: str) -> None:
        """Type a timecode-parser-compatible string into the @timeline
        TC entry field and commit it.

        Sequence: Cmd+3 (focus timeline) → Tab (focus TC field, scoped
        to @timeline) → type ``text`` → Return (commits →
        ApplyTimecodeEntryText → SetPlayhead at the parsed value).

        Lower-level than ``move_playhead_to`` — does NOT post-assert
        the resulting playhead position, so callers can intentionally
        request out-of-range frames to verify clamp behaviour.
        """
        self.key("Cmd+3")
        self.key("Tab")
        self.runner.type_text(text)
        self.key("Return")

    def move_playhead_to(self, frame: int) -> None:
        """Seek the playhead to an absolute frame using real keyboard input
        through the timecode entry field.

        Wraps ``type_in_tc_field(f"{frame}f")`` and asserts the
        post-condition that the playhead actually landed at ``frame``.

        For requests that expect a clamp (frame < start_tc, frame >
        sequence end), call ``type_in_tc_field`` directly and assert
        the clamped position yourself.

        No snap interaction — TC parser feeds SetPlayhead directly with
        the typed value. No ruler click — so no pixel→time math, no
        magnetic snap to worry about.
        """
        read_playhead = (
            "return require('core.debug_helpers').playhead()")
        before = self.eval_int(read_playhead)
        self.type_in_tc_field(f"{frame}f")
        actual = self.eval_int(read_playhead)
        assert actual == frame, (
            f"move_playhead_to({frame}): typed-TC seek landed playhead at "
            f"frame {actual} (delta={actual - frame}; pre was {before}). "
            f"Sequence: Cmd+3 → Tab → '{frame}f' → Return. If actual == "
            f"before, the typed input never committed (Tab didn't focus "
            f"TC field, or Return didn't fire apply_timecode_entry_text). "
            f"If actual != before but != frame, TC parser rejected the "
            f"input (check {frame}f format vs timecode_input.parse). "
            f"If clamp was expected (out-of-range frame), use "
            f"type_in_tc_field() directly instead.")

    def ensure_record_tab(self) -> None:
        """If a source tab is currently displayed, press grave to swap
        back to the record tab. No-op when record is already displayed."""
        kind = self.eval_str(
            'local k = require("core.debug_helpers").displayed_tab_kind(); '
            'return tostring(k or "")')
        if kind != "record":
            self.key("Grave")

    def wait_for(self, lua_predicate: str, timeout: float = 5.0) -> None:
        """Convenience proxy to self.runner.wait_for."""
        self.runner.wait_for(lua_predicate, timeout=timeout)

    def first_armed_video_clip(self, min_frames: int = 48) -> ArmedClip:
        """Probe the displayed record sequence for the first non-gap clip
        on an armed (autoselect=1, locked=0) video track whose duration
        exceeds ``min_frames``. Returns the decoded ``ArmedClip``; raises
        AssertionError if no clip matches.

        The Lua side encodes its result as a pipe-delimited string (the
        debug-terminal repr cap can't carry tables) — this helper is the
        single seam that splits the payload. Test bodies receive a typed
        record, not a positional split.
        """
        raw = self.eval_str(
            f"return require('core.debug_helpers')"
            f".first_armed_video_clip({min_frames})")
        assert raw, (
            f"first_armed_video_clip({min_frames}): fixture has no armed "
            f"video clip with body > {min_frames} frames")
        parts = raw.split("|", 5)
        assert len(parts) == 6, (
            f"first_armed_video_clip: expected 6 pipe-delimited fields, "
            f"got {len(parts)} ({raw!r}) — debug_helpers payload format "
            f"changed; update ArmedClip in tests/live/runner/case.py")
        return ArmedClip(
            id=parts[0],
            track_id=parts[1],
            seq_start=int(parts[2]),
            duration=int(parts[3]),
            rec_seq=parts[4],
            master_seq_id=parts[5],
        )

    def densest_armed_video_clip(self, min_frames: int = 48) -> ArmedClip:
        """Variant of ``first_armed_video_clip`` biased toward concurrent
        video load. Picks the armed-track clip whose midpoint sits in
        the densest overlap region (most other armed video clips active
        at the same frame). Used by playback smokes that want to stress
        the GPU compositor instead of measuring an idle stretch.
        """
        raw = self.eval_str(
            f"return require('core.debug_helpers')"
            f".densest_armed_video_clip({min_frames})")
        assert raw, (
            f"densest_armed_video_clip({min_frames}): fixture has no armed "
            f"video clip with body > {min_frames} frames")
        parts = raw.split("|", 5)
        assert len(parts) == 6, (
            f"densest_armed_video_clip: expected 6 pipe-delimited fields, "
            f"got {len(parts)} ({raw!r})")
        return ArmedClip(
            id=parts[0],
            track_id=parts[1],
            seq_start=int(parts[2]),
            duration=int(parts[3]),
            rec_seq=parts[4],
            master_seq_id=parts[5],
        )

    def fetch_str_array(self, producer_lua: str, key: str,
                        chunk_size: int = 5) -> list:
        """Fetch a Lua string array of arbitrary length without hitting
        the debug-terminal 256-char repr cap. See ``fetch_int_array``
        for contract; differs only in chunk_size default (strings are
        wider — 5 × 50-char "uuid:start:end" rows = ~250 chars).
        Strings must not contain commas (CSV-safe is the caller's
        responsibility — UUIDs and ints are fine)."""
        n = self.eval_int(producer_lua)
        if n <= 0:
            return []
        out: list = []
        helper = "require('core.debug_helpers').array_chunk"
        for start in range(1, n + 1, chunk_size):
            end = min(start + chunk_size - 1, n)
            chunk = self.eval_str(
                f"return {helper}('{key}', {start}, {end})")
            if chunk:
                out.extend(x for x in chunk.split(",") if x)
        assert len(out) == n, (
            f"fetch_str_array: expected {n} items, got {len(out)} — "
            f"chunking dropped items (key={key!r}, "
            f"chunk_size={chunk_size})")
        return out

    def fetch_int_array(self, producer_lua: str, key: str,
                        chunk_size: int = 20) -> list:
        """Fetch a sortable Lua int array of arbitrary length without
        hitting the debug-terminal repr cap (256 chars per response,
        per spec.md FR-005).

        Contract — ``producer_lua`` is a Lua snippet that calls a
        ``stash_*`` producer in ``core.debug_helpers``. The producer
        stashes its sorted int array into a module-local table under a
        stable ``key`` and returns its length. Example:
            "return require('core.debug_helpers').stash_edit_points_on_displayed_sequence()"
            (stashes under ``"edit_points"``)

        chunk_size is the items-per-fetch budget; default 20 = ~240
        chars of CSV (11-digit ints + commas), well inside the 256 cap.

        Per spec phase1-test-overhaul.md §"State queries beyond the
        cap" — this is the documented chunked-fetch pattern.
        """
        n = self.eval_int(producer_lua)
        if n <= 0:
            return []
        out: list[int] = []
        helper = "require('core.debug_helpers').array_chunk"
        for start in range(1, n + 1, chunk_size):
            end = min(start + chunk_size - 1, n)
            chunk = self.eval_str(
                f"return {helper}('{key}', {start}, {end})")
            if chunk:
                out.extend(int(x) for x in chunk.split(",") if x)
        assert len(out) == n, (
            f"fetch_int_array: expected {n} items, got {len(out)} — "
            f"chunking dropped items (key={key!r}, "
            f"chunk_size={chunk_size})")
        return out

    def menu_pick(self, path: str) -> None:
        """Convenience proxy to self.runner.menu_pick."""
        self.runner.menu_pick(path)

    def pick_file_in_open_dialog(self, path: str, timeout: float = 8.0) -> None:
        """Convenience proxy to self.runner.pick_file_in_open_dialog."""
        self.runner.pick_file_in_open_dialog(path, timeout=timeout)

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
