# Research: Keyboard Architecture Refactor

**Feature**: 004-keyboard-architecture-refactor
**Date**: 2026-03-29

## Root Cause Analysis

### The ShortcutOverride Problem
- `GlobalKeyFilter::eventFilter()` unconditionally accepts ALL `QEvent::ShortcutOverride` events (signal_bindings.cpp line 75-77)
- This prevents Qt's shortcut resolution from ever running
- QShortcut objects would never fire their `activated()` signal
- QLineEdit's built-in text protection (claiming ShortcutOverride for alphanumeric keys) is overridden
- **Fix**: Only claim ShortcutOverride for keys the residual handler will process

### The Monolithic Handler Problem
- `keyboard_shortcuts.lua` handles ALL key events: Tab, Escape, Return, arrows, single-key shortcuts, modifier shortcuts, text input bypass
- 8 special-case if-blocks before registry dispatch
- Context matching duplicated in Lua (should be Qt's job)
- **Fix**: QShortcut handles context matching; Lua handler reduced to 5 special cases

## Qt Shortcut Context System

### Decision: WidgetWithChildrenShortcut for panel-scoped
- `Qt::WidgetWithChildrenShortcut` — shortcut active when parent widget or any child has focus
- Maps perfectly to `@timeline`, `@project_browser`, etc.
- Qt auto-prefers more-specific context when ambiguous

### Decision: WindowShortcut for global
- `Qt::WindowShortcut` — active when any widget in the window has focus
- Maps to shortcuts with no `@context` suffix

### Decision: QLineEdit native text protection
- QLineEdit accepts ShortcutOverride for alphanumeric, space, arrows, backspace, delete
- QLineEdit also claims Cmd+A/C/V/X/Z
- No custom text-input bypass needed — Qt handles it

## Special Cases That Stay in Lua

| Key | Why it can't be a QShortcut |
|-----|----------------------------|
| Left/Right arrows | Need timer management for arrow repeat (start/stop on press/release) |
| F9/F10 | Need to gather context from project_browser before dispatching Insert/Overwrite |
| Comma/Period | Need to inspect selected edges vs clips to decide Nudge vs RippleEdit |
| E | Need to gather edge context for ExtendEdit |
| Escape | Multi-stage priority cascade (fullscreen > timecode > text > drag) |

These 5 cases use a residual Lua handler. ShortcutOverride is only claimed for these specific keys.

## Menu Shortcut Display

- Currently uses `QAction::setShortcut()` for display text only
- QAction shortcuts never fire (ShortcutOverride intercepted)
- After refactor: can continue using QAction::setShortcut for display
- Alternative: remove QAction::setShortcut, use QShortcut objects directly (Qt shows shortcut in menu automatically when QShortcut parent is the same widget)
- **Decision**: Keep current display approach. Less risk.
