# Tasks: Keyboard Architecture Refactor

**Input**: Design documents from `/specs/004-keyboard-architecture-refactor/`
**Prerequisites**: plan.md, research.md, quickstart.md

## Phase 3.1: Setup — C++ Bindings

- [ ] T001 Implement `src/lua/qt_bindings/shortcut_bindings.cpp`: New file with C++ bindings for QShortcut. Functions: `lua_create_shortcut(parent_widget, key_sequence_string, context_string)` — creates QShortcut with `Qt::WindowShortcut` (context="window") or `Qt::WidgetWithChildrenShortcut` (context="widget_children"), returns shortcut userdata. `lua_connect_shortcut(shortcut, handler_name)` — connects `QShortcut::activated` signal to a Lua global function. `lua_set_shortcut_enabled(shortcut, bool)` — enables/disables. `lua_delete_shortcut(shortcut)` — deletes. Register all in `qt_bindings.cpp` as globals: `qt_create_shortcut`, `qt_connect_shortcut`, `qt_set_shortcut_enabled`, `qt_delete_shortcut`. Add declarations to `qt_bindings.h`. `make -j4` to verify C++ compiles.

- [ ] T002 Implement `focusNextPrevChild` override binding in `src/lua/qt_bindings/signal_bindings.cpp`: Add C++ class `FocusContainmentWidget` that overrides `focusNextPrevChild()` to wrap Tab within a panel's focusable children. Expose as `lua_set_focus_containment(container_widget)` — installs the override via event filter (same pattern as PanelFocusTrap but ONLY for Tab). Register as `qt_set_focus_containment` global. The existing `PanelFocusTrap` class already has this logic — refactor to separate Tab containment from Return handling. `make -j4`.

## Phase 3.2: Tests (TDD)

- [ ] T003 [P] Write `tests/test_keyboard_shortcuts_refactor.lua`: Test that the registry creates QShortcut objects from TOML bindings. Mock `qt_create_shortcut` and `qt_connect_shortcut` globals. Parse `default.jvekeys`, call the new registry init, verify: (a) global shortcuts created with context="window", (b) panel-scoped shortcuts created with context="widget_children", (c) correct parent widget passed for each context, (d) handler connected for each shortcut. Test all 5 context types: timeline, source_monitor, timeline_monitor, project_browser, global. Must FAIL initially.

- [ ] T004 [P] Write `tests/test_keyboard_residual_handler.lua`: Test the residual Lua handler (keyboard_shortcuts.lua after gutting). Verify: (a) Escape cascade: fullscreen > timecode > text > drag, (b) Left/Right arrow repeat timer starts/stops, (c) F9/F10 gather context from project_browser, (d) Comma/Period dispatch Nudge vs RippleEdit based on selection, (e) E gathers edge context for ExtendEdit, (f) all other keys return false (not handled). Must FAIL initially.

## Phase 3.3: Core Implementation

- [ ] T003 Modify `src/lua/core/keyboard_shortcut_registry.lua`: Add `create_qt_shortcuts(panel_containers)` function. Takes a table mapping context names to container widgets: `{timeline=timeline_panel.container, project_browser=browser.container, ...}`. For each TOML binding: parse key combo + context + command. Create QShortcut via `qt_create_shortcut(parent, key_sequence, context_type)`. Connect to a Lua handler that calls `command_manager.execute_ui(command_name, params)`. Store shortcuts for later cleanup/rebinding. Skip keys in the residual set (Left, Right, F9, F10, Comma, Period, E, Escape). Keep `handle_key_event()` for the residual handler to call. Run test_keyboard_shortcuts_refactor.lua — PASS. `make -j4`.

- [ ] T004 Modify `src/lua/qt_bindings/signal_bindings.cpp` — GlobalKeyFilter: Change `ShortcutOverride` handling. Instead of accepting ALL ShortcutOverride events, only accept for residual keys (Left, Right, F9, F10, Comma, Period, E, Escape, Tab). All other ShortcutOverride events pass through to Qt's normal resolution. This is the critical change — QShortcuts start firing after this. `make -j4`.

- [ ] T005 Modify `src/lua/core/keyboard_shortcuts.lua` — Gut to residual handler: Remove the text input bypass (Qt handles it). Remove the registry dispatch call. Remove the Return/Enter special case. Remove the Tab cycling for non-timeline panels (focusNextPrevChild handles it). Keep: Escape cascade, Left/Right arrow repeat, F9/F10 context gather, Comma/Period context gather, E edge gather. Keep: key release handler for K held state + arrow repeat cancel. The handler now returns false for any key not in its residual set. Run test_keyboard_residual_handler.lua — PASS. `make -j4`.

## Phase 3.4: Panel Integration

- [ ] T006 Modify `src/lua/ui/layout.lua`: After panel creation, call `keyboard_shortcut_registry.create_qt_shortcuts()` with panel container map: `{timeline=timeline_panel_mod.container, project_browser=project_browser_mod.container, source_monitor=source_monitor_widget, timeline_monitor=timeline_monitor_widget}`. Call `qt_set_focus_containment()` on each panel container. `make -j4`.

- [ ] T007 Modify `src/lua/ui/project_browser.lua`: Register default button for Return handling — `qt_set_panel_default_button(M.container, next_btn)` when find bar is visible. Remove the `qt_cycle_panel_focus` call and `__browser_find_return` handler (focusNextPrevChild handles Tab, PanelFocusTrap handles Return). `make -j4`.

- [ ] T008 Modify `src/lua/ui/timeline/timeline_panel.lua`: Keep existing Tab behavior (timecode toggle) by NOT installing generic focusNextPrevChild on timeline — timeline's Tab is special-cased in the residual handler. `make -j4`.

## Phase 3.5: Cleanup

- [ ] T009 Remove dead code: Delete the `focus_is_text_input` check from keyboard_shortcuts.lua. Delete the `Return/Enter on button` check. Delete `qt_cycle_panel_focus` calls. Remove unused imports. Clean up any `-- luacheck: globals` declarations for removed globals. `make -j4`.

- [ ] T010 Update menu shortcut display: Verify `menu_system.lua` `update_shortcut_display()` still works — QAction::setShortcut for display text should be unaffected since we didn't change that path. Run app and verify menu items show shortcuts. `make -j4`.

## Phase 3.6: Validation

- [ ] T011 [P] Run full quickstart validation: Execute all 24 scenarios from quickstart.md via `--test` mode. Tab containment, Return on widgets, panel-scoped shortcuts, text input protection, Escape handling, backward compatibility. Document failures, fix, re-run.

- [ ] T012 [P] Run `make -j4` full validation: All existing tests pass (no regressions). Zero luacheck warnings. All new test files pass.

- [ ] T013 Smoke test all 80 keybindings: Load app, systematically test every shortcut in `default.jvekeys` across all panel contexts. Verify no regressions.

## Dependencies
```
T001 (C++ shortcut bindings) ── no deps
T002 (focusNextPrevChild) ──── no deps
T003-T004 (tests) ──────────── no deps (TDD)
T005 (registry migration) ──── depends on T001
T006 (GlobalKeyFilter) ─────── depends on T005 (shortcuts must exist before filter change)
T007 (gut handler) ─────────── depends on T006 (filter must be simplified first)
T008 (layout integration) ──── depends on T002, T005
T009 (browser integration) ─── depends on T008
T010 (timeline integration) ── depends on T008
T011 (cleanup) ─────────────── depends on T007, T009, T010
T012 (menu display) ────────── depends on T006
T013-T015 (validation) ─────── depend on all above
```

## Parallel Execution Examples
```
# Phase 3.1 — C++ bindings are independent:
T001: shortcut_bindings.cpp
T002: focusNextPrevChild binding

# Phase 3.2 — Tests are independent:
T003: test_keyboard_shortcuts_refactor.lua
T004: test_keyboard_residual_handler.lua

# Phase 3.6 — Validation is independent:
T011: quickstart validation
T012: full build validation
```

## Validation Checklist
- [ ] All 80 TOML shortcuts fire correctly in their context
- [ ] Tab wraps within each panel
- [ ] Return activates focused button / default button
- [ ] Text input in QLineEdit not intercepted by shortcuts
- [ ] Escape cascade preserved
- [ ] Arrow repeat preserved
- [ ] JKL shuttle preserved
- [ ] Context gathering (F9/F10/Comma/Period/E) preserved
- [ ] Menu shortcut display preserved
- [ ] Zero luacheck warnings
- [ ] All existing tests pass
