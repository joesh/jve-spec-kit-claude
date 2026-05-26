# Panel/Tab Architecture — long-term arc

**Status**: vision document. Living. Updated as each phase teaches us things.
**Owner**: Joe.
**Last updated**: 2026-05-26.

## What this document is

A multi-phase architectural arc, not a frozen plan. Each numbered spec in `specs/NNN-*` that implements a phase points back here. Other in-flight work (Inspector, Browser, SourceMonitor) reads this to align with where things are going.

## Why this arc exists

Today the JVE UI is a pile of bespoke panel types — TimelinePanel, InspectorPanel, BrowserPanel, ProjectBrowserPanel, SourceMonitor, SequenceMonitor — each with its own tabs, layout logic, focus handling, and shared-state shape. The shared state often leaks across panels via singletons (`timeline_state`, focus_manager, signal handlers).

The 2026-05-26 BRE silent-no-op investigation (see `specs/022-per-tab-timeline-cache/plan.md`) made one consequence concrete: `timeline_state` carries per-displayed-tab clip cache in a single global slot, but commands target the active tab (which may not be displayed). The result is a class of "command silently runs against the wrong data" bugs. The structural fix is per-tab encapsulation.

Generalizing the structural fix gives us the arc below.

## End state

```
App
├── PanelManager
│   └── panels: [ Panel, Panel, ... ]          -- all same class
└── InteractionState  (drag, focus, last-pointer-in-panel)

Panel  (undifferentiated tab container)
├── tabs: [ TabView, ... ]
├── displayed_tab, active_tab
├── name = active_tab:get_title()              -- derived, not stored
└── tab_strip_widget                            -- pure presentation, child

TabView  (abstract base — interface + listener plumbing + id/kind/title)
└── (subclass-specific state + view widgets)

  SequenceView extends TabView
  ├── sequence_id, clips, tracks, viewport, playhead, selection
  ├── last_pointer_frame
  └── tracks_views: { video: TracksView, audio: TracksView }
                                                -- TracksView wraps the C++
                                                  tracks-drawing widget (today's
                                                  misnamed timeline_view.lua)

  InspectorView extends TabView
  ├── inspectable_kind, inspectable_id
  └── ... section widgets

  BrowserView extends TabView
  ├── root_path (or media-bin id)
  └── ... folder/list widgets

  SourceMonitorView extends TabView
  ├── live_clip_id / staged_sequence_id
  └── ... preview widget
```

Properties this gives us:
- **One Panel class.** No bespoke panel types. Anything that holds tabs is a Panel.
- **Tabs are first-class.** Each TabView owns its own state. Cache lifetime == tab lifetime. No shared global cache to confuse.
- **Movable tabs.** Drag a tab from one panel to another (or to a new window) — the TabView moves; its owning panel changes; the strip widgets update.
- **Self-describing panels.** Panel's title bar reads its active tab's name. No "what kind of panel is this" branching.
- **Uniform PanelManager interface.** `panel:get_tabs()`, `panel:active_tab()`, `panel:displayed_tab()` regardless of what kind of TabViews live inside.
- **One place for cross-panel singletons.** `InteractionState` (drag, focus) is genuinely application-wide and lives at the App level, not on any panel or view.

## Phases (current understanding — revisable)

### Phase 1 — per-tab cache on existing TimelineTab
**Status**: scheduled 2026-05-26 23:00 PDT.
**Spec**: `specs/022-per-tab-timeline-cache/plan.md`.
**Scope**: lift the data cache (clips, tracks, viewport, playhead, selection) off `timeline_state` global onto each `TimelineTab` instance. No renames. No new types.
**Outcome**: BRE silent-no-op bug class goes away by construction. Tab switch becomes pointer swap. Per-tab cache lifetime = tab lifetime. Foundation laid for Phase 2.

### Phase 2 — introduce TabView base + SequenceView (rename TimelineTab)
**Status**: not scheduled.
**Hypothetical spec**: 023-tabview-base.
**Scope**:
- Rename `timeline_view.lua` → `tracks_view.lua` (it's the per-pane C++-widget wrapper, not a "view" in the MVC sense).
- Introduce `TabView` base class (metatable-based prototype inheritance — Lua doesn't do classes natively but the pattern is well-established).
- Rename `TimelineTab` → `SequenceView`, declare it `extends TabView`.
- `SequenceView` continues to hold the per-tab cache from Phase 1; no data restructure.
- Update callsites mechanically.

### Phase 3 — generalize panel ownership
**Status**: not scheduled.
**Hypothetical spec**: 024-panel-class.
**Scope**:
- Rename `TimelinePanel` → `Panel`.
- Move tabs from `TimelineTabStrip` to `Panel` directly. Strip becomes a presentation widget.
- Add `Panel:open_tab(view)` / `Panel:close_tab(view)` / `Panel:get_tabs()` interface.
- Other panels (Inspector, Browser) start the same migration in their own subsequent specs.

### Phase 4 — InspectorView, BrowserView, SourceMonitorView as TabView subclasses
**Status**: not scheduled. Each is its own spec.
**Scope**: per-panel migration to the TabView abstraction. Each panel's existing internal state moves onto its TabView subclass.

### Phase 5 — PanelManager + movable tabs
**Status**: not scheduled.
**Scope**:
- `App` exposes `PanelManager` with uniform panel registration.
- Tab reparenting: drag a TabView from Panel A to Panel B. Listener subscriptions survive reparenting.
- Maybe: detach a Panel into its own window.

## Open questions (resolve as they become relevant)

### Where do per-application singletons live?
Candidates: drag state, focused panel, last-pointer-in-any-panel.
- Class-wide on `SequenceView` (Joe's initial suggestion): convenient, but couples app-level state to one view subclass.
- New `InteractionState` module at App level: cleaner separation, costs a module.
- Mixed: drag goes to App-level (genuinely singleton); last-pointer-frame goes per-SequenceView instance (pointer position is panel-relative and meaningless across panels).

Tentative: mixed (drag at App, per-view things on the view). Confirm during Phase 2 or 3.

### Selection — per-tab or global?
Today: global (`timeline_state.selected_clips`). User switches tabs; selection persists.
Per-tab is more OO-correct but a behavior change (selection no longer follows tab switch).
**Defer until Phase 2**. Most likely answer: per-tab — selection should live with the data it points at.

### Browser tabs — are they Panel tabs?
The Project Browser shows a folder tree. Multiple browser instances could open different folders. Are these "tabs" in our sense or a different abstraction?
**Defer until Phase 4** (BrowserView migration).

### Strip widget — one strip per panel?
If a panel has 3 tabs, one strip widget with 3 buttons. If the user drags a tab out, the strip rerenders. Strip is purely presentational; it subscribes to its owning panel's tab list. **Confirmed direction**.

### Multi-window?
A Panel could live in the main window or in a detached window. PanelManager doesn't care which. Detached-window state needs serialization for session restore. **Defer until Phase 5+ if ever**.

## Where we are now

| Component | Phase 1 state | End state |
|---|---|---|
| `TimelineTab` | exists; lightweight handle | becomes `SequenceView` extends `TabView` |
| `TimelineTabStrip` | owns tabs | becomes a child presentation widget; `Panel` owns tabs |
| `TimelinePanel` | bespoke timeline panel | becomes generic `Panel` |
| `timeline_view.lua` | misnamed per-pane widget wrapper | renamed `tracks_view.lua` |
| `timeline_state` (global) | shared cache for displayed tab | shrinks to almost-nothing; cache moves to TabView instances |
| Other panels (Inspector, Browser, ...) | each their own structure | each becomes `Panel` + their state becomes a TabView subclass |
| `App` | implicit, scattered singletons | explicit `PanelManager` + `InteractionState` |

## Decisions log

- **2026-05-26** — agreed on the end-state shape above (Joe + Claude session). Phase 1 scheduled for autonomous overnight execution.
- **2026-05-26** — Phase 1 explicitly defers all renames and new type introductions; lifts cache onto existing `TimelineTab` only. Reason: keeps the autonomous slot bounded; sets up Phase 2 to be mechanical.

## How to update this doc

- Every time a phase lands: add a "Status: complete" note + a one-line summary of what landed vs what changed during execution.
- Every time an open question is answered: move it from "Open questions" to "Decisions log" with the date + reasoning.
- Every time a future phase changes shape (scope grows, splits, merges): update the Phases section. Reflect the actual current understanding, not the original plan.
- Living doc — do not freeze. Stale arc docs are worse than no arc doc.

## Cross-references

- `specs/022-per-tab-timeline-cache/plan.md` — Phase 1 plan
- `specs/015-source-in-timeline/refactor-plan.md` — introduced the displayed/active tab split that exposed the cache smell
- `memory/todo_test_source_viewer_marks_track_live_clip_mutations.md` — the smoke test that surfaces the bug Phase 1 fixes
