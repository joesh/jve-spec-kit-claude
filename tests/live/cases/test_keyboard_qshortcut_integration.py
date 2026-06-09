"""
Keyboard QShortcut wiring — meta-smoke pinning the TOML→QShortcut
registry build and the residual-key dispatch path.

Pins the same domain behavior as the original
``tests/integration/test_keyboard_qshortcut_integration.lua``: at app
launch the TOML keymap produces a populated QShortcut registry whose
handler globals are all present; residual keys (arrow keys) reach the
Lua handler and do their user-visible thing (playhead moves); a
TOML-bound key (Grave, exercised by the sibling smoke
``test_keymap_grave_toggles_tab``) round-trips through the dispatch
chain.

Scope-narrowed from the source Lua test: the original drove
``keyboard_shortcuts.handle_key`` directly with synthetic Qt key
dicts to probe residual-vs-QShortcut routing, text-input bypass, and
Tab→ToggleTimecodeFocus. Those are implementation-level pokes that
require either a focused QLineEdit (no primitive yet) or
introspection of QShortcut::activated firing (no primitive yet). The
parts that survive as domain-observable through real OS input are
preserved here; the rest are flagged TODO at the bottom of this file.

Run:
    python3 -m unittest tests.live.cases.test_keyboard_qshortcut_integration -v
"""

import unittest

from tests.live.runner.case import JVESmokeCase

class TestKeyboardQShortcutIntegration(JVESmokeCase):
    """Meta-checks on the QShortcut registry + residual-key dispatch."""

    def test_01_registry_has_many_shortcuts_with_handler_globals(self) -> None:
        # Read-only introspection: the QShortcut registry must be built
        # at launch from the TOML keymap. If empty / sparse, the whole
        # keyboard surface is dead and every keypress smoke downstream
        # will mysteriously no-op.
        count = self.eval_int(
            "local r = require('core.keyboard_shortcut_registry'); "
            "return r.active_shortcuts and #r.active_shortcuts or 0")
        self.assertGreater(count, 50, (
            f"QShortcut registry has only {count} entries — expected "
            f">50 from default.jvekeys. Either create_qt_shortcuts was "
            f"never called or the TOML parse failed silently. Every "
            f"keypress-driven smoke will spuriously pass-then-fail."))

        # Every registered shortcut must have a global handler function
        # — that's the bridge Qt's QShortcut::activated signal binds to.
        # A missing global is a silent dead-key (TSO 2026-05-20 class).
        missing = self.eval_int(
            "local r = require('core.keyboard_shortcut_registry'); "
            "local n = 0; "
            "for _, e in ipairs(r.active_shortcuts) do "
            "  if not e.handler_name "
            "     or type(_G[e.handler_name]) ~= 'function' then "
            "    n = n + 1 "
            "  end "
            "end; "
            "return n")
        self.assertEqual(0, missing, (
            f"{missing} QShortcut entries have no live handler global. "
            f"Those keys will fire QShortcut::activated and call into "
            f"nothing — a silent dead-key. Check "
            f"keyboard_shortcut_registry.create_qt_shortcuts for the "
            f"_G[handler_name] = fn registration step."))

    def test_02_shift_z_binding_exists_for_timeline_scope(self) -> None:
        # Pin that the TOML keymap actually parsed Shift+Z @timeline
        # into a registry binding. Original test pre-checked this before
        # calling registry.handle_key_event. Read-only — no mutation.
        has_binding = self.eval_bool(
            "local r = require('core.keyboard_shortcut_registry'); "
            "local s = r.parse_shortcut('Shift+Z'); "
            "local key = string.format('%d_%d', s.key, s.modifiers); "
            "local b = r.keybindings[key]; "
            "return b ~= nil and #b > 0")
        self.assertTrue(has_binding, (
            "Shift+Z has no entry in keyboard_shortcut_registry."
            "keybindings — TimelineZoomFit @timeline binding never made "
            "it from default.jvekeys into the dispatch table. Either "
            "the TOML section was renamed or parse_shortcut's key/mod "
            "normalization drifted."))

    def test_03_right_arrow_advances_playhead_in_timeline(self) -> None:
        # Right arrow is a "residual" key — not bound through QShortcut
        # but routed via the GlobalKeyFilter → keyboard_shortcuts.handle_key
        # path so the arrow-repeat timer can manage held-key behavior.
        # User-visible effect: playhead advances by one frame per press.
        # If this fails the residual path is broken.
        self.focus_panel("timeline")
        self.assertEvalEqual("timeline",
            'return require("ui.focus_manager").get_focused_panel()',
            msg="setUp: focus did not anchor on timeline")

        before = self.eval_int(
            "local p = require('core.debug_helpers').playhead(); "
            "assert(p, 'fixture precondition: displayed sequence has no "
            "playhead — anamnesis template should always have a record "
            "sequence loaded into the record engine'); "
            "return p")

        self.key("Right")
        after = self.eval_int(
            "local p = require('core.debug_helpers').playhead(); "
            "assert(p, 'displayed sequence lost its playhead after Right "
            "arrow — sequence was torn down by the keypress, which is a "
            "much bigger bug than a non-advancing playhead'); "
            "return p")
        self.assertGreater(after, before, (
            f"Right arrow in timeline expected to advance playhead "
            f"(was {before}, got {after}). Residual-key dispatch path "
            f"is broken — GlobalKeyFilter is not forwarding the Right "
            f"arrow press to keyboard_shortcuts.handle_key, or the "
            f"arrow_repeat seed is no-op."))

    # ------------------------------------------------------------------
    # TODOs — slices of the original test that need primitives we don't
    # yet have. Each is a single-method skip so the suite still records
    # the gap. Do NOT delete without re-checking MIGRATION_ANALYSIS.md.
    # ------------------------------------------------------------------

    @unittest.skip("needs focused-QLineEdit primitive — see PRIMITIVES.md gap")
    def test_04_text_input_bypass_for_residual_keys(self) -> None:
        # Original test #7: focused text input should swallow Left arrow
        # / Comma / printable letters so the user can edit text instead
        # of those firing residual-key actions. Needs a primitive that
        # focuses an actual QLineEdit (e.g. the timecode entry field)
        # and a way to fire a key and observe that no command ran —
        # neither exists today.
        pass

    @unittest.skip("needs ToggleTimecodeFocus observable — see PRIMITIVES.md gap")
    def test_05_tab_in_timeline_routes_to_toggle_timecode_focus(self) -> None:
        # Original test #6: Tab in @timeline must dispatch through the
        # Lua handler (so the TOML-bound ToggleTimecodeFocus runs)
        # rather than Qt's dialog-style focusNextPrevChild. The
        # command's side effect is moving Qt-level focus into the
        # timecode QLineEdit; debug_helpers has no query for that yet
        # (focused_panel() reports panels, not embedded widgets).
        pass

    @unittest.skip("needs source-viewer-loaded fixture state — see MIGRATION_ANALYSIS.md")
    def test_06_f10_overwrite_routes_via_qshortcut_not_residual(self) -> None:
        # Original test #8: F10 is TOML-bound (Overwrite). Verifying it
        # round-trips through QShortcut requires media loaded in the
        # source viewer + a record sequence ready to receive the edit,
        # then observing a new clip on the record sequence. Possible to
        # script but materially larger than the rest of this file;
        # belongs in a dedicated overwrite smoke.
        pass

if __name__ == "__main__":
    unittest.main()
