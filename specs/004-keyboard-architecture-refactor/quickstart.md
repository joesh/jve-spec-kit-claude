# Quickstart: Keyboard Architecture Refactor

**Feature**: 004-keyboard-architecture-refactor

## Validation Scenarios

### 1. Tab Containment

```
Test 1.1 — Browser panel Tab wraps:
  Open find bar (Cmd+F in browser)
  Press Tab repeatedly
  Assert: focus cycles find_edit → ← → → → match_label → combo → All → tree → find_edit
  Assert: focus never reaches timeline or inspector panels

Test 1.2 — Timeline panel Tab preserved:
  Focus timeline
  Press Tab
  Assert: focus toggles between timecode entry and timeline view

Test 1.3 — Shift+Tab reverses:
  Same as 1.1 but in reverse order
```

### 2. Return/Enter

```
Test 2.1 — Return on QPushButton:
  Tab to a button in the find bar
  Press Return
  Assert: button activates (animateClick visual + action)

Test 2.2 — Return in QLineEdit triggers default button:
  Type text in find field
  Press Return
  Assert: Find Next activates (the panel's default button)
  Assert: focus stays in find field

Test 2.3 — Return on QComboBox:
  Tab to the attribute combobox
  Press Return
  Assert: dropdown opens

Test 2.4 — Return doesn't trigger ActivateBrowserSelection:
  Focus find field, press Return
  Assert: no ActivateBrowserSelection command fires
```

### 3. Panel-Scoped Shortcuts

```
Test 3.1 — Browser shortcut only in browser:
  Focus browser
  Press F2
  Assert: RenameItem fires

Test 3.2 — Browser shortcut doesn't fire from timeline:
  Focus timeline
  Press F2
  Assert: no RenameItem command

Test 3.3 — Global shortcut from any panel:
  Focus browser, press Cmd+Z
  Assert: Undo fires
  Focus timeline, press Cmd+Z
  Assert: Undo fires

Test 3.4 — Context priority:
  If same key bound globally and to panel, panel wins when focused
```

### 4. Text Input Protection

```
Test 4.1 — Typing in QLineEdit:
  Focus find field
  Type "hello"
  Assert: text appears in field
  Assert: no H/E/L/O shortcuts fire

Test 4.2 — Cmd+A in QLineEdit:
  Focus find field with text
  Press Cmd+A
  Assert: text selected in field (not SelectAll timeline command)

Test 4.3 — Cmd+Z in QLineEdit:
  Type text, then press Cmd+Z
  Assert: text undo in field (not timeline Undo)

Test 4.4 — Single-key shortcuts suppressed in text:
  Focus find field
  Press Space
  Assert: space character typed (not TogglePlay)
  Press J
  Assert: j typed (not ShuttleReverse)
```

### 5. Escape

```
Test 5.1 — Fullscreen exit (highest priority):
  Enter fullscreen, press Escape
  Assert: fullscreen exits

Test 5.2 — Find bar hide:
  Open find bar, press Escape
  Assert: find bar hides

Test 5.3 — QLineEdit restore:
  Type in find field, press Escape
  Assert: text restored to pre-edit state

Test 5.4 — Drag cancel:
  Start drag, press Escape
  Assert: drag cancelled
```

### 6. Backward Compatibility

```
Test 6.1 — All TOML shortcuts work:
  Load default.jvekeys
  For each binding, verify command fires in correct context

Test 6.2 — JKL shuttle:
  Press J/K/L in timeline
  Assert: shuttle behavior preserved (including K held state)

Test 6.3 — Arrow nudge:
  Select clip, press Left/Right
  Assert: nudge with repeat timer preserved

Test 6.4 — Comma/Period context:
  Select edge, press Comma
  Assert: RippleEdit fires (not Nudge)
  Select clip (no edge), press Comma
  Assert: Nudge fires
```

### 7. Performance

```
Test 7.1 — No latency regression:
  Measure time from key press to command execution
  Assert: no measurable difference from current system
```
