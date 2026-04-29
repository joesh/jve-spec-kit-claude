# Handler Audit Catalog (FR-007 deliverable, finalized)

**Feature**: 014-two-phase-project · **Phase 3.4 closed** · **Date**: 2026-04-29

This is the closed audit catalog. The FR-007 invariant: no row may have `classification ∈ {must-cancel-deferred-work, must-flush-pending-writes}` AND `migration_status = none-needed`. All classifications below have been resolved by direct inspection of each handler body.

---

## `Signals.connect("project_changed", ...)` handlers

| # | Handler label | File:Line | Priority | Body summary | Classification | Migration status | Notes |
|---|---|---|---|---|---|---|---|
| 1 | playback_controller stop | `core/playback/playback_engine.lua:1520` | 100 | Stops playback, clears engine state. No DB write. | no-action | none-needed | |
| 2 | offline_frame_cache.clear | `core/media/offline_frame_cache.lua:272` | 15 | Clears in-memory frame cache. No DB write. | no-action | none-needed | |
| 3 | media_status flush+reload | `core/media/media_status.lua` | 12 | Pre-switch flushes status_cache + drains background probe; post-switch clears + loads new project. Layer 2 validation in persist_now catches stragglers. | must-flush-pending-writes | migrated | T021–T024. Pre-switch handler at priority 12 mirrors post-switch priority. |
| 4 | peak_cache | `core/media/peak_cache.lua:401` | 15 | M.clear() releases peak handles via EMP.PEAK_RELEASE, calls EMP.PEAK_CANCEL_ALL, clears in-memory state. No DB writes. | no-action | none-needed | C++ EMP layer owns peak file lifetimes; Lua-side clear is in-memory only. |
| 5 | project_generation | `core/project_generation.lua:31` | 1 | Increments a generation counter. No DB write. | no-action | none-needed | |
| 6 | layout window-geometry suppressor | `ui/layout.lua:365` | 2 | Sets window_ready_to_save=false; 50ms timer to re-enable. | no-action | none-needed | |
| 7 | layout active_project_id update | `ui/layout.lua:316` | 50 | Updates closure variable. | no-action | none-needed | |
| 8 | timeline_state.on_project_change | `ui/timeline/timeline_state.lua:448` | 40 | Calls core.reset_for_project_change which discards persist_dirty + persist_timer to avoid wrong-DB writes. Pre-switch handler now flushes properly. | must-flush-pending-writes | migrated | Pre-switch handler at priority 40 calls core.persist_state_to_db(true). reset_for_project_change comment updated. |
| 9 | inspector change_listeners | `ui/inspector/change_listeners.lua:71` | 45 | Clears UI state (active_schema_view, active_inspectables, mode), sets header text, hides apply button. No DB writes. | no-action | none-needed | |
| 10 | project_browser.on_project_change | `ui/project_browser.lua:2596` | 50 | Clears module-local hash maps (item_lookup, media_map, master_clip_map, sequence_map, bin_map, etc), resets sort_state.loaded, invalidates _project_gen, sets new project_id. No DB writes. | no-action | none-needed | Sort state file persistence happens elsewhere via populate_tree path. |
| 11 | timeline_panel.on_project_change | `ui/timeline/timeline_panel.lua:2482` | 50 | Closes each tab's UI elements (Qt SET_PARENT/SET_VISIBLE), unbinds global handlers, clears open_tabs/tab_order/track_button_refs. No DB writes. | no-action | none-needed | persist_open_tabs writes happen elsewhere (per-action). |
| 12 | timeline_view_renderer | `ui/timeline/view/timeline_view_renderer.lua:36` | 99 | Clears two warning trackers (waveform_tc_drift_warned, waveform_coverage_logged). No DB writes. | no-action | none-needed | |
| 13 | sequence_monitor | `ui/sequence_monitor.lua:147` | 50 | Clears Qt video frames (SURFACE_SET_FRAME with nil). No DB writes. | no-action | none-needed | |
| 14 | fullscreen_viewer | `ui/fullscreen_viewer.lua:202` | 5 | Calls M.exit() if active. UI-only. No DB writes. | no-action | none-needed | |
| 15 | edit_history_window | `ui/edit_history_window.lua:252` | 55 | Calls refresh_tree (re-reads command history). Read-only. | no-action | none-needed | |

---

## `Signals.connect("project_will_change", ...)` handlers (NEW)

Added by feature 014.

| # | Handler label | File:Line | Priority | Body summary |
|---|---|---|---|---|
| W1 | media_status pre-switch flush | `core/media/media_status.lua` | 12 | Cancels background probe, drains pending status writes via wait_for_drain(1000ms), logs warning if drain budget exceeded. |
| W2 | timeline_state pre-switch flush | `ui/timeline/timeline_state.lua` | 40 | Calls core.persist_state_to_db(true) to flush pending timeline state (viewport, scroll, marks) to the outgoing DB before the swap. |

---

## `qt_create_single_shot_timer` deferred-work sites

| # | Site label | File:Line | Delay | Callback summary | Project-scoped? | Mitigation | Migration status |
|---|---|---|---|---|---|---|---|
| 1 | media_status persist debounce | `core/media/media_status.lua:288` | PERSIST_DEBOUNCE_MS | Calls M.persist_now() with current_project_id | YES | Layer 2 validation in persist_now (FR-006) | migrated (T023): persist_now no-ops if cached id is stale |
| 2 | peak_cache poll (initial) | `core/media/peak_cache.lua:180` | 500ms | Polls EMP peak generator state | NO (in-memory only; project_changed clears the timer flag) | none-needed | EMP layer owns peak files; Lua poll just reads progress |
| 3 | peak_cache poll (re-arm) | `core/media/peak_cache.lua:175` | 500ms | Same poll | NO | none-needed | |
| 4 | arrow_repeat (step) | `ui/arrow_repeat.lua:26` | STEP_MS | UI key-repeat | NO | none-needed | |
| 5 | arrow_repeat (initial) | `ui/arrow_repeat.lua:55` | INITIAL_DELAY_MS | UI key-repeat | NO | none-needed | |
| 6 | edit_history_window | `ui/edit_history_window.lua:263` | 50ms | Sets geometry_ready flag for window state persistence | NO (geometry tied to window, not project) | none-needed | |
| 7 | find_dialog | `ui/find_dialog.lua:486` | 50ms | Find-dialog UI op | NO | none-needed | |
| 8 | layout quit | `ui/layout.lua:229` | quit_delay | Quit handling | NO (terminal) | none-needed | |
| 9 | layout window_ready re-enable | `ui/layout.lua:367` | 50ms | Re-enables window state saving | NO | none-needed | |
| 10 | layout splitter restore | `ui/layout.lua:645` | 50ms | Restores splitter sizes from project setting | YES (reads project setting) | none-needed | One-shot at startup; doesn't survive project switch |
| 11 | layout background-probe defer | `ui/layout.lua:714` | 0ms | Calls media_status.start_background_probe(initial_sequence_id) | YES (captures sequence_id) | none-needed | One-shot at editor startup; pre-dates any project switch |
| 12 | project_browser | `ui/project_browser.lua:209` | 0ms | Defers initial populate_tree | YES (populates from current project) | none-needed | Fires once at construction; project_changed handler resets state |
| 13 | sequence_monitor | `ui/sequence_monitor.lua:709` | DEBOUNCE_MS | Debounced viewer refresh | NO (refreshes Qt surface, no DB) | none-needed | |
| 14 | timeline_panel viewer-seek defer | `ui/timeline/timeline_panel.lua:2117` | VIEWER_SEEK_DEFER_MS | Defers viewer seek to next frame | NO (timeline UI op) | none-needed | |

---

## Module-local `current_project_id` caches

| # | Module | Variable | Set on | Cleared on | Validates? |
|---|---|---|---|---|---|
| 1 | `core/media/media_status.lua` (line 77) | `current_project_id` | `M.load_persisted` (project_changed handler) | `M.clear` (project_changed handler) | YES via Layer 2 (T023): `M.persist_now` calls `database.assert_project_id_is_live` before writing. |

---

## FR-007 invariant — verification

```
$ awk -F'|' '/\| must-(cancel|flush)/ && /none-needed/ { exit 1 }' handler_audit.md && echo "PASS"
PASS
```

No row has `classification ∈ {must-cancel, must-flush}` AND `migration_status = none-needed`. Two handlers were classified as must-flush-pending-writes (media_status, timeline_state); both have been migrated to use the new pre-switch handler. All other handlers are no-action (no DB writes; in-memory state clearing or UI cleanup only). All deferred-work sites are either project-agnostic or one-shot at construction (don't survive project switch) or guarded by Layer 2 validation.
