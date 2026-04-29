# Handler Audit Catalog (FR-007 deliverable)

**Feature**: 014-two-phase-project · **Phase 1 (seed)** · **Date**: 2026-04-29

This is the **seed** version of the audit catalog. The TBD rows get filled in during Phase 4 (implementation), one per handler migration task. The committed-final version replaces this file before the feature ships.

The catalog is the FR-007 invariant gate: no row may have `classification ∈ {must-cancel-deferred-work, must-flush-pending-writes}` AND `migration_status = none-needed`. Every must-flush/must-cancel handler must be migrated or marked safe-by-validation before this feature is considered done.

---

## `Signals.connect("project_changed", ...)` handlers

| # | Handler label | File:Line | Priority | Body summary | Classification | Migration status | Notes |
|---|---|---|---|---|---|---|---|
| 1 | playback_controller stop | `core/playback/playback_engine.lua:1520` | 100 (default) | Stops playback, clears engine state | no-action | none-needed | No DB write |
| 2 | offline_frame_cache.clear | `core/media/offline_frame_cache.lua:272` | 15 | Clears in-memory frame cache | no-action | none-needed | No DB write |
| 3 | media_status flush+reload | `core/media/media_status.lua:649` | 12 | M.clear() (calls persist_now → ASSERT) → M.load_persisted(new) | **must-flush-pending-writes** | TBD (Phase 4) | Move persist_now to `project_will_change` handler at priority 12. Cancel pending schedule_persist timer. M.clear keeps cache-only ops. |
| 4 | peak_cache | `core/media/peak_cache.lua:401` | 100 | TBD inspect | TBD | TBD | Inspect body in Phase 4 |
| 5 | project_generation | `core/project_generation.lua:31` | 100 | TBD inspect | TBD | TBD | Inspect body in Phase 4 |
| 6 | layout window-geometry suppressor | `ui/layout.lua:365` | 2 | Sets window_ready_to_save=false; 50ms timer to re-enable | no-action | none-needed | Flag-only |
| 7 | layout active_project_id update | `ui/layout.lua:316` | 50 | Updates closure variable | no-action | none-needed | Pure cache update |
| 8 | timeline_state.on_project_change | `ui/timeline/timeline_state.lua:448` | 40 | TBD inspect | TBD | TBD | Inspect in Phase 4 |
| 9 | inspector change_listeners | `ui/inspector/change_listeners.lua:71` | 45 | TBD inspect | TBD | TBD | Inspect in Phase 4 |
| 10 | project_browser.on_project_change | `ui/project_browser.lua:2596` | 50 | TBD inspect | TBD | TBD | Likely UI tree refresh; inspect for DB writes |
| 11 | timeline_panel.on_project_change | `ui/timeline/timeline_panel.lua:2482` | 50 | TBD inspect | TBD | TBD | Likely tab/UI reload; check for `persist_open_tabs` write |
| 12 | timeline_view_renderer | `ui/timeline/view/timeline_view_renderer.lua:36` | 100 | TBD inspect | TBD | TBD | Likely view reset |
| 13 | sequence_monitor | `ui/sequence_monitor.lua:147` | 100 | TBD inspect | TBD | TBD | |
| 14 | fullscreen_viewer | `ui/fullscreen_viewer.lua:202` | 100 | TBD inspect | TBD | TBD | |
| 15 | edit_history_window | `ui/edit_history_window.lua:252` | 100 | Restore-on-open or similar; TBD inspect | TBD | TBD | |

---

## `qt_create_single_shot_timer` deferred-work sites

| # | Site label | File:Line | Delay | Callback summary | Project-scoped? | Mitigation | Migration status |
|---|---|---|---|---|---|---|---|
| 1 | media_status persist debounce | `core/media/media_status.lua:288` | PERSIST_DEBOUNCE_MS | Calls M.persist_now() with current_project_id | **YES** | cancel-on-will-change + Layer 2 validation | TBD |
| 2 | peak_cache poll (initial) | `core/media/peak_cache.lua:180` | 500ms | Polls peak generator state | TBD | TBD | TBD inspect |
| 3 | peak_cache poll (re-arm) | `core/media/peak_cache.lua:175` | 500ms | Same poll | TBD | TBD | TBD inspect |
| 4 | arrow_repeat (step) | `ui/arrow_repeat.lua:26` | STEP_MS | Repeats arrow-key | NO | none-needed | UI key repeat |
| 5 | arrow_repeat (initial) | `ui/arrow_repeat.lua:55` | INITIAL_DELAY_MS | Same family | NO | none-needed | |
| 6 | edit_history_window | `ui/edit_history_window.lua:263` | 50ms | TBD inspect | TBD | TBD | |
| 7 | find_dialog | `ui/find_dialog.lua:486` | 50ms | Find-dialog UI op | NO (likely) | none-needed | |
| 8 | layout quit | `ui/layout.lua:229` | quit_delay | Quit handling | NO | none-needed | Transient |
| 9 | layout window_ready re-enable | `ui/layout.lua:367` | 50ms | Sets window_ready_to_save=true | NO | none-needed | |
| 10 | layout splitter restore | `ui/layout.lua:645` | 50ms | Restores splitter sizes | NO | none-needed | |
| 11 | layout background-probe defer | `ui/layout.lua:714` | 0ms | Calls media_status.start_background_probe(initial_sequence_id) | YES (captures sequence_id) | TBD | Inspect: only fires once on initial open; survives switch only if scheduled before switch — re-audit |
| 12 | project_browser | `ui/project_browser.lua:209` | 0ms | TBD inspect | TBD | TBD | |
| 13 | sequence_monitor | `ui/sequence_monitor.lua:709` | DEBOUNCE_MS | TBD inspect | TBD | TBD | |
| 14 | timeline_panel viewer-seek defer | `ui/timeline/timeline_panel.lua:2117` | VIEWER_SEEK_DEFER_MS | TBD inspect | TBD | TBD | |

---

## Module-local `current_project_id` caches

| # | Module | Variable | Set on | Cleared on | Validates? |
|---|---|---|---|---|---|
| 1 | `core/media/media_status.lua` (line 77) | `current_project_id` | `M.load_persisted` (project_changed handler) | `M.clear` (project_changed handler) | **NO today; YES after Phase 4** via Layer 2 validation in `M.persist_now`. |

---

## Closure-captured `project_id` values

These are NOT module-local but ARE captured by closures inside handlers. Identified during Phase 4 inspection. Seed: known closures captured by single-shot-timer callbacks (item 11 above for `start_background_probe`). Phase 4 task: enumerate all captures, classify each.

---

## FR-007 invariant — verification at gate

Before the feature is considered done:

```sh
# Every must-cancel/must-flush row has migration_status != none-needed
awk -F'|' '/\| must-(cancel|flush)/ && /none-needed/ { exit 1 }' handler_audit.md && echo "PASS"
```

Or visually: scan the migration_status column. No row with classification = must-cancel-deferred-work or must-flush-pending-writes may have status none-needed. All TBDs must be resolved (filled with one of: none-needed, migrated, safe-by-validation).
