
# Implementation Plan: Keyboard Architecture Refactor

**Branch**: `004-keyboard-architecture-refactor` | **Date**: 2026-03-29 | **Spec**: `specs/004-keyboard-architecture-refactor/spec.md`

## Summary
Migrate keyboard dispatch from monolithic Lua application-level event filter to Qt's `QShortcut` system with `WidgetWithChildrenShortcut` for panel-scoped bindings and `WindowShortcut` for globals. Panels get `focusNextPrevChild()` for Tab containment and default button support for Return. Lua stays as command executor — QShortcut fires signal → Lua → command_manager.execute().

## Technical Context
**Language/Version**: C++ (Qt6) + Lua (LuaJIT)
**Primary Dependencies**: Qt6 QShortcut, QKeySequence, QWidget::focusNextPrevChild
**Storage**: TOML keybindings (`keymaps/default.jvekeys`)
**Testing**: LuaJIT test harness + `--test` mode integration tests
**Target Platform**: macOS (Darwin)
**Project Type**: Single desktop application
**Performance Goals**: Zero latency impact — QShortcut resolution is O(1)
**Constraints**: Must preserve all existing shortcuts, TOML format, keyboard customization UI
**Scale**: ~80 keybindings (33 global, ~48 panel-scoped), 5 panel contexts

## Constitution Check

**I. Modular Architecture**: ✅ QShortcut per-panel is modular. Each panel owns its shortcuts.
**II. Command-Driven Interface**: ✅ All shortcuts still dispatch through command_manager.
**III. Test-First Development**: ✅ TDD for C++ bindings and Lua integration.
**IV. Documentation-Driven Specifications**: ✅ Full spec with 19 scenarios.
**V. Template-Based Consistency**: ✅ Follows existing C++ binding pattern.
**VI. Fail-Fast Assert Policy**: ✅ Invalid key sequences assert.
**VII. No Fallbacks or Default Values**: ✅ No fallback dispatch.
**VIII. No Backward Compatibility**: ✅ Old dispatch removed, not kept alongside.

## Project Structure

### Source Code (changes)
```
src/
├── lua/
│   ├── core/
│   │   ├── keyboard_shortcuts.lua       # GUTTED — reduced to Escape + arrow repeat only
│   │   ├── keyboard_shortcut_registry.lua # MODIFIED — creates QShortcuts instead of Lua lookup table
│   │   └── keyboard_constants.lua       # UNCHANGED
│   ├── qt_bindings/
│   │   ├── signal_bindings.cpp          # MODIFIED — GlobalKeyFilter simplified, PanelFocusTrap kept
│   │   └── shortcut_bindings.cpp        # NEW — QShortcut create/connect/set bindings
│   └── ui/
│       ├── view.lua                     # MODIFIED — add focus containment registration
│       ├── layout.lua                   # MODIFIED — register panel containers for shortcuts
│       ├── project_browser.lua          # MODIFIED — register panel + default button
│       └── timeline/
│           └── timeline_panel.lua       # MODIFIED — register panel + Tab behavior
├── qt_bindings.cpp                      # MODIFIED — register new shortcut bindings
└── qt_bindings.h                        # MODIFIED — declare new functions

keymaps/
└── default.jvekeys                      # UNCHANGED (TOML format preserved)
```

## Phase 0: Research — Complete

### Decision: QShortcut + Lua hybrid
- **Chosen**: QShortcut handles key/context resolution, Lua handles command execution
- **Rationale**: Qt's built-in ambiguity resolution (WidgetWithChildrenShortcut vs WindowShortcut) eliminates all special-case context matching. QLineEdit's ShortcutOverride eliminates text-input bypass.
- **Alternatives rejected**: Full C++ dispatch (loses Lua flexibility), pure Lua with event filter hacks (current broken approach)

### Decision: Stop claiming ShortcutOverride
- **Chosen**: Remove unconditional ShortcutOverride accept from GlobalKeyFilter
- **Rationale**: This is the root cause. Qt can't resolve shortcuts if the filter claims all keys first.
- **Risk**: Menu QAction shortcuts might start firing. Mitigated by not setting action shortcuts (display text only via separate mechanism).

### Decision: focusNextPrevChild for Tab
- **Chosen**: C++ override on panel containers
- **Rationale**: Qt-standard mechanism. Tab wraps within panel automatically.

### Decision: PanelFocusTrap for Return/default button
- **Chosen**: Event filter on panel container handles Return → default button
- **Rationale**: Qt doesn't have default button outside QDialog. Event filter is the standard workaround.

### Special cases that stay in Lua
- **Arrow repeat management** (Left/Right with timer) — too intertwined with playback state
- **F9/F10/Comma/Period/E** — need context gathering (selected clips/edges) before dispatch
- **Escape** — multi-stage priority (fullscreen > timecode > text > drag)
- These become a small residual handler, not the monolithic filter

## Phase 1: Design

### C++ Bindings Needed

```cpp
// shortcut_bindings.cpp

// Create QShortcut on a parent widget with key sequence
// Args: parent_widget, key_sequence_string, context ("window"|"widget_children")
// Returns: shortcut userdata
int lua_create_shortcut(lua_State* L);

// Connect QShortcut::activated to a Lua global function name
// Args: shortcut, handler_name
int lua_connect_shortcut(lua_State* L);

// Delete/disable a shortcut
int lua_set_shortcut_enabled(lua_State* L);

// Set focus containment on a widget (focusNextPrevChild override)
// Args: container_widget
int lua_set_focus_containment(lua_State* L);

// Set panel default button (Return activates it from non-button widgets)
// Args: container_widget, button_widget
int lua_set_panel_default_button(lua_State* L);  // ALREADY EXISTS
```

### Migration Path

**Step 1**: Add C++ QShortcut bindings (create, connect, enable/disable)
**Step 2**: Add focusNextPrevChild C++ binding
**Step 3**: Modify keyboard_shortcut_registry to create QShortcuts from TOML
**Step 4**: Modify GlobalKeyFilter to stop claiming ShortcutOverride (except for keys handled by residual Lua handler)
**Step 5**: Gut keyboard_shortcuts.lua to residual handler only
**Step 6**: Register panel containers in layout.lua
**Step 7**: Verify all 80 shortcuts still work

### Residual Lua Handler (keyboard_shortcuts.lua after refactor)
```
handle_key(event):
  if Escape → fullscreen/timecode/text/drag cascade
  if Left/Right → arrow repeat management
  if F9/F10 → context gather + Insert/Overwrite
  if Comma/Period → context gather + Nudge/RippleEdit
  if E → context gather + ExtendEdit
  return false  // everything else handled by QShortcut
```

ShortcutOverride is only claimed for these specific residual keys.

## Phase 2: Task Planning Approach

**Task Generation Strategy**:
- C++ bindings first (QShortcut, focusNextPrevChild)
- Then registry migration (TOML → QShortcut creation)
- Then GlobalKeyFilter simplification
- Then keyboard_shortcuts.lua gutting
- Then panel registration + integration
- Each step testable independently

**Ordering**:
- TDD: tests before implementation
- Dependency: C++ bindings → registry → filter → handler → integration
- Each step: verify all existing shortcuts still work

**Estimated Output**: 12-15 tasks

## Complexity Tracking
*No deviations from constitution.*

## Progress Tracking

**Phase Status**:
- [x] Phase 0: Research complete
- [x] Phase 1: Design complete
- [x] Phase 2: Task planning complete (describe approach only)
- [ ] Phase 3: Tasks generated (/tasks command)
- [ ] Phase 4: Implementation complete
- [ ] Phase 5: Validation passed

**Gate Status**:
- [x] Initial Constitution Check: PASS
- [x] Post-Design Constitution Check: PASS
- [x] All NEEDS CLARIFICATION resolved
- [x] Complexity deviations documented

---
*Based on Constitution v2.0.0*
