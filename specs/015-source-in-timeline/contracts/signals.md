# Signal contracts

**Feature**: 015-source-in-timeline
**Date**: 2026-05-03

JVE uses `core/signals` (broadcast pub/sub) to decouple emitters from listeners. Per CLAUDE.md memory `project_signals_vs_watchers.md`, broadcast is the right shape for state-change notifications consumed by multiple unrelated views; per-entity observation has a different (planned) mechanism. This feature adds broadcast signals only.

Each signal entry: name, payload, emitters, expected listeners, lifecycle.

---

## `source_loaded_changed`

**New**. Fires when the source monitor's loaded master sequence changes (loaded, swapped, or unloaded).

**Payload**: `(new_master_seq_id_or_nil, previous_master_seq_id_or_nil)`.

**Emitters**:
- `src/lua/ui/source_viewer.lua` — at the end of `load_master_clip(master_seq_id)`, AFTER the source_monitor has finished loading the new master.
- `src/lua/ui/source_viewer.lua` — also from a new `unload()` path (added by this feature) that clears the source_monitor's loaded master.

**Listeners (this feature)**:
- `timeline_panel` — re-evaluates SourceTab styling and content. If a SourceTab is currently open in the strip, its tab's `tab_role` and styling are recomputed; if the new master sequence is loaded, the tab's content view re-pulls.
- `inspector` (existing) — out of scope for emission, but listeners may already exist; this feature does not change inspector behavior.

**Lifecycle**: emitted at most once per `load_master_clip` call. Not coalesced.

---

## `source_tab_visibility_changed`

**New**. Fires when the SourceTab is opened or closed in the timeline tab strip.

**Payload**: `(visible_boolean)`. `true` if the tab is now in the strip; `false` if removed.

**Emitters**:
- `ShowSourceTab` command — after opening.
- `CloseSourceTab` (or the existing `close_tab` path applied to the SourceTab) — after closing.

**Listeners**:
- Menu system — to keep the "Show Source Tab" menu item's checkmark / enabled-state in sync.
- Persistence layer — to update `project_settings.open_sequence_ids` so the tab's open-state survives reopen.

**Lifecycle**: emitted on every transition. Not coalesced (the tab transitions are discrete user actions, low frequency).

---

## `displayed_tab_changed`

**New**. Fires when the displayed tab changes (user clicked a different tab).

**Payload**: `(new_displayed_sequence_id, previous_displayed_sequence_id)`.

**Emitters**:
- `timeline_panel` tab-click handler — after the timeline body has re-rendered to show the new tab's content.

**Listeners**:
- Inspector / status bar — if any view depends on which tab is displayed.

**Note**: this signal is independent of `active_sequence_changed`. Switching to the SourceTab fires `displayed_tab_changed` but not `active_sequence_changed` (per FR-005).

**Lifecycle**: emitted on every tab transition. Suppressed if the user clicks the already-displayed tab (no actual change).

---

## `active_sequence_changed` (NEW or extends existing)

**Extends existing or new**: JVE may already emit a similar signal when sequences switch via the existing tab system. This feature ENSURES the signal fires when (and only when) the active sequence pointer moves. Per FR-005, clicking the SourceTab does NOT fire this signal.

**Payload**: `(new_active_sequence_id, previous_active_sequence_id)`.

**Emitters**:
- `timeline_panel` tab-click handler — only when a Record tab is clicked (NOT when the SourceTab is clicked).
- Active-sequence change paths from elsewhere in the app (menu commands, etc.) — out of scope to enumerate here; the existing emitters continue to apply.

**Listeners**:
- All sequence-scoped views (timeline_state, inspector, status bar, transport).

**Lifecycle**: at most once per real change.

---

## `patch_changed`

**New**. Fires when a patches row is created, updated, or deleted.

**Payload**: `(sequence_id, source_track_index, change_type)` where `change_type ∈ {'created', 'updated', 'deleted'}`.

**Emitters**: `SetPatch` command, plus any future patch-deletion command.

**Listeners**:
- `timeline_panel` track-header view — re-renders the affected track's source/rec id buttons and connection visuals.
- Edit commands — if a command had cached patches for a planning step, it MUST consider the cache invalidated and re-read.

**Lifecycle**: emitted once per patch transition. Multiple patch transitions in a single command (rare) emit the signal once per affected row.

---

## `sync_mode_changed`

**New**. Fires when a track's sync_mode changes.

**Payload**: `(track_id, new_sync_mode, previous_sync_mode)`.

**Emitters**: `SetSyncMode` command.

**Listeners**:
- `timeline_panel` track-header view — re-renders the sync-mode cell icon.

**Lifecycle**: at most once per real transition.

---

## `track_preference_changed`

**New**. Fires when a track's solo, mute, lock, or enabled flag changes.

**Payload**: `(track_id, property, new_value, previous_value)` where `property ∈ {'muted', 'soloed', 'locked', 'enabled'}`.

**Emitters**: `ToggleTrackPreference` command (the FR-040a fix).

**Listeners**:
- `timeline_panel` track-header view — re-renders the affected button.
- Audio-mix path — solo/mute changes affect the routing decision in playback.
- Renderer — solo/mute on video tracks affects compositing (FR-019, FR-020).

**Existing signal `track_mix_changed` is REPLACED for solo/mute** — that signal continues for `volume`/`pan` (emitted by the new `SetTrackMixValue` command). The split is per the C4 refactor.

**Lifecycle**: at most once per transition.

---

## `track_mix_changed` (existing, unchanged)

Continues to fire from `SetTrackMixValue` (renamed-and-narrowed `SetTrackProperty`) on volume/pan changes. Listeners continue to react as today. NO behavior change for this signal.

---

## Listener registration contracts

Per CLAUDE.md project memory:
- All listeners register via `Signals.connect("<name>", handler, priority)`.
- Handlers MUST be idempotent — emitting twice in succession with the same payload MUST be safe.
- Handlers MUST NOT emit a signal that, in turn, re-fires the originating signal — guard against loops via the existing signal infrastructure.

For this feature, no signal handler emits another signal in this feature's chain — all 7 new-signal emitters are command executors (single-source), and listeners are pure-update views (zero re-emit).

---

## Test contracts

For each new signal, a test (`tests/test_signals_<name>.lua` or part of the originating command's test) MUST verify:

1. The signal is emitted on the documented action.
2. The payload matches the documented shape.
3. No emission occurs when the action is a no-op (e.g., setting a sync_mode to its current value SHOULD NOT emit `sync_mode_changed`).
4. Decoupling test: clicking the SourceTab fires `displayed_tab_changed` but NOT `active_sequence_changed` (FR-005 displayed-tab-vs-active-sequence pointer independence).
