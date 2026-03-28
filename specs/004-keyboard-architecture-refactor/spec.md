# Feature Specification: Keyboard Architecture Refactor

**Feature Branch**: `004-keyboard-architecture-refactor`
**Created**: 2026-03-28
**Status**: Draft
**Input**: Migrate from monolithic Lua application-level event filter to Qt's shortcut context system.

---

## User Scenarios & Testing

### Primary User Story
A developer or editor using JVE expects standard desktop keyboard behavior: Tab cycles within the active panel, Return activates the focused button, Escape dismisses modal states, and keyboard shortcuts fire only in the correct panel context. Currently, a monolithic Lua event filter intercepts all keys at the application level, bypassing Qt's native focus and shortcut resolution. This causes Tab to escape panels, Return to trigger wrong commands, and per-panel shortcuts to require hacks.

### Acceptance Scenarios

#### Tab Focus Containment
1. **Given** the browser panel has focus with the find bar visible, **When** the user presses Tab, **Then** focus cycles through find field → arrows → combo → All → tree → find field (wraps within browser panel, never escapes to timeline or inspector).
2. **Given** the timeline panel has focus, **When** the user presses Tab, **Then** focus toggles between the timecode entry and the timeline view (existing behavior preserved).
3. **Given** Shift+Tab is pressed, **Then** focus cycles in reverse order within the same panel.

#### Return/Enter on Widgets
4. **Given** a QPushButton has keyboard focus in any panel, **When** the user presses Return, **Then** the button activates (same as clicking it).
5. **Given** a QLineEdit has focus and the panel has a default button set, **When** Return is pressed, **Then** the panel's default button activates.
6. **Given** a QComboBox has focus, **When** Return is pressed, **Then** the dropdown opens.
7. **Given** the browser find field has focus, **When** Return is pressed, **Then** Find Next activates (the panel's default button).

#### Panel-Scoped Shortcuts
8. **Given** the browser panel has focus, **When** the user presses a browser-only shortcut (e.g., F2 for Rename), **Then** the command fires.
9. **Given** the timeline panel has focus, **When** the user presses the same key, **Then** the browser-only shortcut does NOT fire.
10. **Given** a global shortcut (e.g., Cmd+Z for Undo), **When** pressed from any panel, **Then** the command fires regardless of which panel has focus.

#### Text Input Protection
11. **Given** a QLineEdit has focus, **When** the user types alphanumeric keys, **Then** the characters go to the text field (not intercepted by shortcuts).
12. **Given** a QLineEdit has focus, **When** Cmd+A is pressed, **Then** Select All operates on the text field, not the timeline.
13. **Given** a QLineEdit has focus and there's a global Cmd+Z, **When** Cmd+Z is pressed, **Then** it undoes text editing in the field (Qt native), not the timeline command.

#### Escape
14. **Given** fullscreen view is active, **When** Escape is pressed, **Then** fullscreen exits (highest priority, global).
15. **Given** the find bar is visible, **When** Escape is pressed, **Then** the find bar hides.
16. **Given** a drag operation is in progress, **When** Escape is pressed, **Then** the drag cancels.

#### Backward Compatibility
17. **Given** the existing `default.jvekeys` TOML file, **When** the app starts, **Then** all existing shortcuts work identically to before the refactor.
18. **Given** a user has customized keybindings, **When** upgrading, **Then** their customizations are preserved.

### Edge Cases
- Multiple panels claim the same key (e.g., Return) — the panel with focus wins.
- Key pressed while no panel has focus — global shortcuts still fire.
- Modifier-only keys (Shift, Cmd, etc.) — ignored as before.
- Auto-repeat keys (held down) — existing behavior preserved for arrow nudge, playback shuttle.
- Text input in timeline timecode entry — existing Tab/Return/Escape behavior preserved.
- Keyboard customization dialog — must show correct shortcut display text.

---

## Requirements

### Functional Requirements

#### Qt Shortcut Integration
- **FR-001**: The application MUST stop claiming all `ShortcutOverride` events. Qt's shortcut resolution MUST be allowed to operate for keys that have `QShortcut` objects registered.
- **FR-002**: Panel-scoped shortcuts (`@context` suffix in TOML) MUST be implemented as `QShortcut` with `Qt::WidgetWithChildrenShortcut` context, parented to the panel's container widget.
- **FR-003**: Global shortcuts (no context suffix) MUST be implemented as `QShortcut` with `Qt::WindowShortcut` context.
- **FR-004**: When a panel-scoped and global shortcut match the same key, Qt MUST automatically prefer the panel-scoped shortcut when the panel has focus.

#### Tab Containment
- **FR-010**: Each panel's container widget MUST contain Tab/Shift+Tab focus within its focusable children (wrapping at boundaries).
- **FR-011**: Tab containment MUST be implemented via `focusNextPrevChild()` override on the panel container (the Qt-standard mechanism).
- **FR-012**: Tab order within each panel MUST follow widget creation order by default, overridable via `setTabOrder()`.

#### Return/Enter Handling
- **FR-020**: Each panel MUST support a "default button" that activates when Return is pressed in a non-button widget.
- **FR-021**: Return on a focused QPushButton MUST activate that button via Qt's native behavior.
- **FR-022**: Return on a focused QLineEdit MUST activate the panel's default button.
- **FR-023**: Return on a focused QComboBox MUST open the dropdown.

#### Text Input Protection
- **FR-030**: When a text input widget has focus, modifier-key shortcuts (Cmd+A, Cmd+C, Cmd+V, Cmd+Z, Cmd+X) MUST go to the text widget, not to global commands.
- **FR-031**: Alphanumeric keys MUST always go to the focused text widget, never to command dispatch.

#### Minimal Global Filter
- **FR-040**: The application-level event filter MUST be reduced to handle ONLY truly global concerns: Escape for fullscreen exit and drag cancel.
- **FR-041**: All other key dispatch MUST go through Qt's `QShortcut` system.

#### TOML Compatibility
- **FR-050**: The `default.jvekeys` TOML format MUST be preserved with no user-facing changes.
- **FR-051**: The `@context` suffix MUST map to `WidgetWithChildrenShortcut` on the corresponding panel container.
- **FR-052**: Shortcuts MUST be re-parseable at runtime for the keyboard customization UI.

### Key Entities
- **Panel Container**: Top-level QWidget for each panel. Owns `focusNextPrevChild` override, `QShortcut` objects, and default button.
- **Shortcut Context**: Maps `@context` suffix to a panel container widget and `Qt::WidgetWithChildrenShortcut`.
- **Default Button**: Per-panel QPushButton that activates on Return when a non-button widget has focus.
- **Global Filter**: Minimal application-level event filter for Escape and drag cancel only.

---

## Review & Acceptance Checklist

### Content Quality
- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

### Requirement Completeness
- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

---

## Execution Status

- [x] User description parsed
- [x] Key concepts extracted
- [x] Ambiguities marked
- [x] User scenarios defined
- [x] Requirements generated
- [x] Entities identified
- [x] Review checklist passed

---
