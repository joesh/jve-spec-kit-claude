"""
keymap_exempt — explicit, reviewed list of keymap bindings that don't
need (or can't safely have) a behavioral smoke test right now.

Two independent axes per binding:

  * ``l1`` (coverage gate) — when set, the L1 coverage audit
    (``coverage.audit_keymap``) skips this binding. The string value is
    the **reason** surfaced to a future reader. Bindings without an
    L1 entry MUST have a per-binding L3 smoke that mentions the combo
    string, or ``make smoke-coverage`` fails the build.

  * ``l2`` (press-all dispatch test) — when set, the L2 press-all
    test (``tests/smoke/cases/test_keymap_dispatch_no_crash.py``)
    skips this binding. The string value is the reason. Bindings
    without an L2 entry get fired in the batch: focus the scope,
    press the key, then verify BOTH (a) no fresh
    ``LUA CALLBACK ERROR`` appeared in the editor log, AND (b) the
    QShortcut handler fire counter advanced. (b) was added
    2026-05-25 — without it L2 false-greens on bindings the key
    never reached (wrong frontmost, accessibility lapsed, scope
    mismatch). See memory/todo_l2_silent_pass_hole.md.

Spec 020 Phase 1 / commands.md "Cmd+B keyboard adapter" is the
worked example for what an L3 behavioral test looks like. Picking
off entries here as L3 cases land is the long-term reduction path.

Key tuple = (combo, scopes) where ``scopes`` is a tuple matching
``KeymapBinding.scopes`` (empty tuple = global).
"""

from typing import Optional


EXEMPT: dict[tuple[str, tuple[str, ...]], dict[str, str]] = {
    # ── Application / dialog openers ─────────────────────────────────────
    ("Cmd+Q", ()): {
        "l1": "Quit — L3 would need a process-respawn pattern; defer",
        "l2": "Quits JVE; L2 batch can't recover",
    },
    ("Cmd+N", ()): {
        "l1": "NewProject opens a dialog; L3 needs modal handling",
        "l2": "Opens modal dialog",
    },
    ("Cmd+O", ()): {
        "l1": "OpenProject opens a file picker; L3 needs file-picker handling",
        "l2": "Opens native file picker",
    },
    ("Cmd+Shift+S", ()): {
        "l1": "SaveProjectAs opens a file picker; L3 needs file-picker handling",
        "l2": "Opens native file picker",
    },
    ("Cmd+I", ()): {
        "l1": "ImportMedia opens a file picker; L3 needs file-picker handling",
        "l2": "Opens native file picker",
    },
    ("Cmd+Shift+R", ()): {
        "l1": "ShowRelinkDialog opens a Qt dialog; L3 needs modal handling",
        "l2": "Opens modal Qt dialog",
    },
    ("Cmd+Alt+K", ()): {
        "l1": "ShowKeyboardCustomization opens a Qt dialog; L3 needs modal handling",
        "l2": "Opens modal Qt dialog",
    },
    ("F1", ()): {
        "l1": "OpenUserManual launches the system browser; out of scope for in-process L3",
        "l2": "Launches external browser",
    },
    ("F12", ()): {
        "l1": "ReportBug launches external email/issue tracker; out of scope",
        "l2": "Launches external app",
    },
    ("Cmd+F", ()): {
        "l1": "Find opens a Qt dialog; L3 needs modal handling",
        "l2": "Opens modal Qt dialog",
    },
    ("Ctrl+G", ("timeline",)): {
        "l1": "GoToTimecode enters a modal TC-entry mode (Tab cycles); L3 needs Esc-recovery",
        "l2": "Enters modal TC-entry; subsequent presses would land in TC widget",
    },
    ("Cmd+Option+F", ()): {
        "l1": "RevealInFilesystem opens Finder; out of scope for in-process L3",
        "l2": "Opens Finder window",
    },
    ("Cmd+Shift+F", ()): {
        "l1": "ToggleFullscreenView changes display mode — L3 risk of OS-level focus trap",
        "l2": "OS-level full-screen transition",
    },
    ("F2", ("project_browser",)): {
        "l1": "StartRename enters inline rename mode; L3 needs Esc-recovery",
        "l2": "Enters modal inline rename; subsequent keys go to text edit",
    },

    # ── Shuttle (starts playback at non-zero rate) ───────────────────────
    ("J", ("timeline", "source_monitor", "timeline_monitor")): {
        "l1": "ShuttleReverse — L3 pending (needs play+stop dance)",
        "l2": "Starts playback at -1×; would leave engine playing across iterations",
    },
    ("L", ("timeline", "source_monitor", "timeline_monitor")): {
        "l1": "ShuttleForward — L3 pending (needs play+stop dance)",
        "l2": "Starts playback at +1×; would leave engine playing across iterations",
    },

    # ── Toggles into modal-ish UI states ─────────────────────────────────
    ("Tab", ("timeline",)): {
        "l1": "ToggleTimecodeFocus — L3 pending (focus-state assertion)",
        "l2": "Shifts focus into TC widget; subsequent keys go there",
    },

    # ── L3-pending only (L2-safe; no L2 exemption) ──────────────────────
    # These bindings get pressed by L2 (dispatch-no-crash gate) but
    # still need a per-binding behavioral L3 test. The "l1" entry
    # documents what L3 should assert when written.
    ("Cmd+S", ()): {
        "l1": "SaveProject — L3 should assert .jvp mtime advanced + sqlite valid",
        "l2": "Cat A (unimplemented): no SaveProject executor registered. "
              "SQLite/WAL auto-commits every mutation, so there's no "
              "discrete save op yet; the binding is aspirational. L2 "
              "would log 'No executor registered for command type: "
              "SaveProject' on every press.",
    },
    # Cmd+Z / Cmd+Shift+Z covered by test_keymap_undo_redo.py
    ("Cmd+X", ("timeline",)): {
        "l1": "Cut — L3 should assert selection moved to clipboard + removed from timeline",
    },
    ("Cmd+C", ("timeline",)): {"l1": "Copy — L3 should assert clipboard payload matches selection"},
    ("Cmd+V", ("timeline",)): {
        "l1": "Paste — L3 should assert clipboard contents land at playhead",
    },
    # Shift+F12 (ToggleProfiler) covered by test_keymap_shift_f12_toggle_profiler.py
    ("Space", ("timeline", "source_monitor", "timeline_monitor")): {
        "l1": "TogglePlay — L3 pending; blocked on macOS keypress-focus "
              "env issue (osascript not delivering to JVE). Cat B fix "
              "landed; spec FR-027b documents the contract.",
        "l2": "TogglePlay starts playback which monopolises the Lua "
              "thread; the press-all loop's per-press Undo can't get a "
              "slot to respond and times out the socket eval. Press is "
              "safe (Cat B fix), but unwind isn't compatible with the "
              "batch loop — needs an explicit stop in the unwind path.",
    },
    ("K", ("timeline", "source_monitor", "timeline_monitor")): {
        "l1": "ShuttleStop — L3 should assert engine pause state",
    },
    ("Home", ("timeline", "source_monitor", "timeline_monitor")): {
        "l1": "GoToStart — L3 should assert playhead at sequence start_timecode_frame",
    },
    ("End", ("timeline", "source_monitor", "timeline_monitor")): {
        "l1": "GoToEnd — L3 should assert playhead at last edit",
    },
    ("Up", ("timeline", "source_monitor", "timeline_monitor")): {
        "l1": "GoToPrevEdit — L3 should assert playhead snapped to prior edit point",
    },
    ("Down", ("timeline", "source_monitor", "timeline_monitor")): {
        "l1": "GoToNextEdit — L3 should assert playhead snapped to next edit point",
    },
    # Alt+I / Alt+O / Alt+X covered by test_keymap_alt_i_o_x_clear_marks.py
    # X (MarkClipExtent) covered by test_keymap_x_mark_clip_extent.py.
    # Cmd+A / Cmd+Shift+A covered by test_keymap_cmd_a_shift_a_selection.py
    # Delete / Backspace (lift) covered by test_keymap_delete_lift.py
    # (L2 exemption removed after the on_model_changed controller-guard
    # fix landed 2026-05-22). Shift+Delete / Shift+Backspace (ripple)
    # still L1-pending — see L3 backlog.
    ("Shift+Delete", ()): {
        "l1": "DeleteSelection ripple — L3 should assert ripple-close behavior",
    },
    ("Shift+Backspace", ()): {
        "l1": "DeleteSelection ripple — L3 same as Shift+Delete (alias)",
    },
    # Cmd+Shift+BracketLeft (TrimHead) + Cmd+Shift+BracketRight (TrimTail)
    # covered by test_keymap_cmd_shift_bracket_trim_head_tail.py.
    # L2 dispatch passes with the seeded clip+playhead-inside-clip state.
    # D (ToggleClipEnabled) covered by test_keymap_d_toggles_clip_enabled.py
    # F (MatchFrame) covered by test_keymap_f_match_frame.py
    ("Alt+F", ()): {
        "l1": "FindMasterClipInBrowser — L3 should assert browser selection landed on master",
    },
    # Cmd+L / Cmd+Shift+L: keymap rebound 2026-05-22 to
    # LinkSelectedClips / UnlinkSelectedClips adapters (Cat G fix).
    # L2 no longer exempt — adapters resolve params from selection so
    # the dispatch is clean. L1 still pending behavioral L3 smoke.
    ("Cmd+L", ("timeline",)): {
        "l1": "LinkSelectedClips — L3 should assert clip_links row(s) "
              "added for the selected clips' new link group",
    },
    ("Cmd+Shift+L", ("timeline",)): {
        "l1": "UnlinkSelectedClips — L3 should assert each selected "
              "clip's clip_links row removed (one undo group)",
    },
    ("Cmd+Delete", ("timeline",)): {
        "l1": "CloseGap — L3 should assert selected gap's right-neighbor shifted left",
        "l2": "Silent-pass under osascript keystroke delivery — macOS "
              "swallows Cmd+Delete (system 'move to trash' affinity) "
              "before it reaches JVE's QShortcut. Verified via fire-"
              "counter detector. Real key-down on physical hardware "
              "works; L2's synthesized delivery doesn't. Belongs in a "
              "bespoke L3 driving via CGEventPost or direct dispatch.",
    },
    ("F9", ()): {
        "l1": "Insert — L3 should assert source clip inserted at playhead, downstream ripples",
    },
    ("F10", ()): {
        "l1": "Overwrite — L3 should assert source clip overwrote at playhead, no ripple",
    },
    # Shift+Z (TimelineZoomFit), Cmd+Equal (TimelineZoomIn) covered by
    # test_keymap_timeline_zoom.py
    ("Shift+Cmd+Equal", ("timeline",)): {
        "l1": "TimelineZoomInAtMouse — L3 should assert zoom anchored on mouse pos",
        "l2": "Requires tracked pointer-frame (set on mouse move over the "
              "timeline). L2 batch never moves the mouse, so the command "
              "asserts 'no pointer frame tracked'. Belongs in a bespoke "
              "L3 that drives a synthetic pointer move first.",
    },
    # Cmd+Minus (TimelineZoomOut) covered by test_keymap_timeline_zoom.py
    ("Shift+Cmd+Minus", ("timeline",)): {
        "l1": "TimelineZoomOutAtMouse — L3 should assert zoom anchored on mouse pos",
        "l2": "Requires tracked pointer-frame; same as Shift+Cmd+Equal "
              "(TimelineZoomInAtMouse) — L2 batch can't provide one.",
    },
    # N (ToggleSnapping) covered by test_keymap_n_toggles_snapping.py
    ("Q", ("timeline",)): {
        "l1": "SelectTool — L3 should assert tool-state = SELECT",
        "l2": "Cat A (unimplemented tool command): "
              "see todo_l2_dispatch_findings.md",
    },
    ("W", ("timeline",)): {
        "l1": "TrackSelectTool — L3 should assert tool-state = TRACK_SELECT",
        "l2": "Cat A (unimplemented tool command): "
              "see todo_l2_dispatch_findings.md",
    },
    ("R", ("timeline",)): {
        "l1": "RippleTool — L3 should assert tool-state = RIPPLE",
        "l2": "Cat A (unimplemented tool command): "
              "see todo_l2_dispatch_findings.md",
    },
    ("T", ("timeline",)): {
        "l1": "RollTool — L3 should assert tool-state = ROLL",
        "l2": "Cat A (unimplemented tool command): "
              "see todo_l2_dispatch_findings.md",
    },
    ("Cmd+Equal", ("source_monitor",)): {
        "l1": "SourceZoomIn — L3 should assert source viewer zoom in",
    },
    ("Shift+Cmd+Equal", ("source_monitor",)): {
        "l1": "SourceZoomIn (shifted variant) — L3 should assert source viewer zoom in",
    },
    ("Cmd+Minus", ("source_monitor",)): {
        "l1": "SourceZoomOut — L3 should assert source viewer zoom out",
    },
    ("Shift+Z", ("source_monitor",)): {
        "l1": "SourceZoomFit — L3 should assert source viewer fit",
    },
    # Cmd+1/2/3/4 covered by test_keymap_cmd_1234_select_panel.py
    ("Tilde", ()): {
        "l1": "ToggleMaximizePanel — L3 should assert focused panel maximized/restored",
    },
    ("Cmd+G", ()): {
        "l1": "FindNext — L3 should assert next-match focus after a prior Find",
    },
    ("Cmd+Shift+G", ()): {
        "l1": "FindPrevious — L3 should assert prev-match focus after a prior Find",
    },
    # Cmd+Shift+N: keymap rebound 2026-05-22 to NewBinHere adapter
    # (Cat G fix). L2 no longer exempt — adapter generates UUID
    # before dispatching NewBin.
    ("Cmd+Shift+N", ("project_browser",)): {
        "l1": "NewBinHere — L3 should assert a bin row added to the "
              "browser hierarchy",
    },

    # ── L2-only exemptions (L3 already present; L2 batch context fails) ─
    # Bindings below have a behavioral L3 smoke test that passes in
    # isolation. L2's alphabetical batch with re-seed between presses
    # still can't fully isolate them — the failure mode is L2-test
    # limitation, not a real product bug. Each entry points to the
    # relevant L3 file so future Claudes can cross-check.
    ("Cmd+B", ("timeline",)): {
        "l2": "L3 covers behavior (test_keymap_cmd_b_blades_at_playhead.py); "
              "L2 batch context misses some adapter precondition "
              "(traceable via Cat D refusal — see todo_l2_dispatch_findings.md). "
              "Not exempted from L1.",
    },
    ("Shift+F", ()): {
        "l2": "L3 covers behavior (test_shift_f_parks_playhead_at_clip_source_in.py "
              "+ test_keymap_shift_f_opens_clip_in_source_viewer.py); "
              "L2 batch context misses source-viewer ready state. "
              "Not exempted from L1.",
    },
    ("Grave", ("timeline", "source_monitor", "timeline_monitor")): {
        "l2": "L3 covers behavior (test_keymap_grave_toggles_tab.py); "
              "L2 batch context can fail on tab-state preconditions. "
              "Not exempted from L1.",
    },
    # Tilde: runner Tilde→Shift+Grave alias landed 2026-05-22 (Cat E fix).
    # L2 no longer exempt.
    ("Tilde", ()): {
        "l1": "ToggleMaximizePanel — L3 pending",
    },
}


# ── Command-class L2 exemption ─────────────────────────────────────────
# Some commands open a dialog / picker / external app NO MATTER WHICH
# KEY invokes them. Listing every keybinding that maps to such a command
# in EXEMPT above is fragile (one-key-equals-one-entry) and incomplete
# (e.g., Cmd+G/Cmd+Shift+G → FindNext/FindPrevious behave like Cmd+F
# when no prior search exists — they also open the Find dialog). The
# right unit of exemption is the COMMAND, not the keystroke.
#
# Any binding whose ``command_name`` is in L2_EXEMPT_COMMANDS is skipped
# by L2 (in addition to the per-(combo, scope) EXEMPT entries above).
# Keep this list small and class-justified — every entry costs L2
# coverage. Reason strings are surfaced in the L2 skip log.
L2_EXEMPT_COMMANDS: dict[str, str] = {
    # Opens a Qt dialog or native picker — modal, L2 batch can't recover
    # if the dialog steals focus mid-loop.
    "Find":                     "Opens modal Qt Find dialog",
    "FindNext":                 "Opens Find dialog when no prior search",
    "FindPrevious":             "Opens Find dialog when no prior search",
    "NewProject":               "Opens new-project dialog",
    "OpenProject":              "Opens native file picker",
    "SaveProjectAs":            "Opens native file picker",
    "ImportMedia":              "Opens native file picker",
    "ShowRelinkDialog":         "Opens modal Qt relink dialog",
    "ShowKeyboardCustomization": "Opens modal Qt keyboard-customization dialog",
    # Launches external app — escapes JVE entirely.
    "OpenUserManual":           "Launches system browser",
    "ReportBug":                "Launches external email/issue tracker",
    "RevealInFilesystem":       "Opens Finder window",
    # OS-level transition — JVE blocks the L2 loop while macOS animates.
    "ToggleFullscreenView":     "OS-level full-screen transition",
    # Modal inline / TC-entry modes — subsequent keys land in a text widget,
    # not in JVE's QShortcut layer.
    "StartRename":              "Enters modal inline rename",
    "GoToTimecode":             "Enters modal TC-entry",
    "ToggleTimecodeFocus":      "Shifts focus into TC widget",
    # Quits the app — L2 batch can't recover.
    "Quit":                     "Quits JVE",
    # Starts playback at non-zero rate — leaves engine playing across iterations.
    "ShuttleReverse":           "Starts playback at -1×",
    "ShuttleForward":           "Starts playback at +1×",
    "TogglePlay":               "Monopolises the Lua thread; "
                                "per-press Undo can't get a slot",
}


def _key(binding) -> tuple[str, tuple[str, ...]]:
    return (binding.combo, tuple(binding.scopes))


def _command_name(binding) -> str:
    """Pull the command name off a KeymapBinding. Asserts the attribute
    is present — silently missing would mean class exemption skipped
    for that binding without any signal (NSF violation)."""
    # The attribute is `.command` (per coverage.KeymapBinding); the
    # command string in default.jvekeys may carry args / scope tokens
    # already stripped by the parser, but the command name is the first
    # whitespace-separated token. Bare access — let AttributeError fire
    # if the contract drifts so we notice immediately.
    raw = binding.command
    return raw.split()[0] if raw else raw


def l1_exempt_reason(binding) -> Optional[str]:
    """L1 coverage-gate exemption reason, or None if the binding is
    expected to have a per-binding L3 smoke."""
    e = EXEMPT.get(_key(binding))
    if e is None:
        return None
    return e.get("l1")


def l2_skip_reason(binding) -> Optional[str]:
    """L2 press-all skip reason, or None if the binding is L2-safe.

    Two-tier lookup: per-(combo, scope) entry in EXEMPT wins; falls
    through to per-command-class entry in L2_EXEMPT_COMMANDS. The
    class layer was added 2026-05-25 because Cmd+F-style entries
    silently leaked their commands' behavior through alternate keys
    (Cmd+G/Cmd+Shift+G opening the same Find dialog), polluting Joe's
    foreground app during smoke runs."""
    e = EXEMPT.get(_key(binding))
    if e is not None and "l2" in e:
        return e["l2"]
    class_reason = L2_EXEMPT_COMMANDS.get(_command_name(binding))
    if class_reason is not None:
        return f"command-class L2 exempt — {class_reason}"
    return None
