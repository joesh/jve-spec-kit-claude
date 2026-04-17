# Phase 1 — Data Model

## Scope

No SQL schema changes. This document records the **in-memory and persisted-setting** shape changes that arise from introducing the no-active-sequence state. It also enumerates nullable references across the module boundary.

## Persisted settings (SQLite `project_settings` table)

| Key | Type | Before | After |
|---|---|---|---|
| `last_open_sequence_id` | TEXT | non-empty sequence id (asserted) | **sequence id OR empty string / absent row** — empty/absent ⇒ no active sequence on open |
| `open_sequence_ids` | JSON array of TEXT | non-empty list (asserted) | **possibly empty list `[]`** — empty ⇒ no tabs restored |

No new keys. No migration. Old rows with non-empty values continue to round-trip as before.

## In-memory references

### `timeline_state`
- **`sequence_id`**: was `string` (init asserts non-nil). After this feature: `string | nil`.
- **`project_id`**: was `string`. After this feature: `string | nil` (nil only when no project is open at all; unchanged for in-project blank state).
- New operation: `clear()` sets `sequence_id = nil`, leaves `project_id` in place, fires listeners so pull-consumers re-query.

### `command_manager`
- **`active_timeline_stack`**: was always a per-sequence stack when a project was open. After this feature: may be nil.
- New operation: `deactivate()` sets active stack to nil. Undo/redo dispatch then falls through to the project-level stack (existing per-project undo mechanism from FU-5 / commit `fcfb681`).

### `timeline_panel`
- **`open_tabs`** (map of `sequence_id → tab_record`): may be `{}`.
- **`tab_order`** (array): may be `[]`.
- New operation: `unload_sequence()` — inverse of `load_sequence`.

## Entity summary

### ActiveSequenceRef *(in-memory only)*
- **Location**: `timeline_state.sequence_id`
- **Cardinality**: 0..1 per open project
- **Lifecycle**: `init(seq, pid)` → sequence id set; `clear()` → nil; `init(other_seq, pid)` permitted after clear.

### ProjectTabState *(persisted in `project_settings`)*
- **Fields**:
  - `open_sequence_ids: string[]` (possibly empty)
  - `last_open_sequence_id: string | ""` (possibly empty/absent)
- **Invariant (post-feature)**: if `last_open_sequence_id` is a non-empty string, it MUST appear in `open_sequence_ids`. If `open_sequence_ids` is empty, `last_open_sequence_id` MUST be `""` or absent.
- **Enforcement**: asserted at save sites (`timeline_panel.unload_sequence()`, `drp_importer.convert()`).

### DropPayload *(transient, never persisted)*
- **Fields**:
  - `clips: MediaClip[]` (flattened — bins have been recursed)
  - `sequences: Sequence[]`
- **Construction**: `partition_droppable(items)` walks the browser selection, recurses bins, separates clips from sequences.

## State transitions (no-active-sequence state)

```
                    (project open, ≥1 tab)                      (project open, no tabs)
                 ┌─────────────────────────┐                  ┌─────────────────────────┐
                 │   Active-sequence state │◄─ open_tab ─────►│  No-active-sequence     │
                 │   sequence_id = s       │                  │  sequence_id = nil      │
                 │   open_tabs ⊇ {s}       │                  │  open_tabs = {}         │
                 └──────────┬──────────────┘                  └──────────┬──────────────┘
                            │                                             │
         close_last_tab,    │                                             │     drop-anything,
         delete_active_seq  │                                             │     open_tab_from_browser
                            ▼                                             ▼
                 ┌─────────────────────────┐                  ┌─────────────────────────┐
                 │ unload_sequence()       │                  │ load_sequence(s)        │
                 │   - state.clear()       │                  │   - state.init(s, pid)  │
                 │   - cmd.deactivate()    │                  │   - cmd.activate(s)     │
                 │   - monitor blank       │                  │   - ensure_tab_for(s)   │
                 │   - persist [] + ""     │                  │   - persist [s, …] + s  │
                 └─────────────────────────┘                  └─────────────────────────┘
```

Orthogonal transition: **project open/close** sets `project_id`; blank state is scoped within an open project.

## Nullability propagation

Any module that receives a sequence id from the model MUST handle the nil case. The Phase 0 survey identified these call sites:

| Module | Call site | Treatment when nil |
|---|---|---|
| `timeline_panel.load_sequence` | existing nil/empty early return | already OK |
| `timeline_view_drag_handler` | `state.get_sequence_id()` ~L43, L237 | **add**: if nil AND drop is on timeline, delegate to new drop-to-blank handler; else early-return |
| `keyboard_shortcuts` | `state.get_sequence_id()` ~L222, L273 | **add**: if nil, abort dispatch (grey-out behavior); unlock when state re-populates |
| `command_manager` undo/redo dispatch | checks `active_timeline_stack` | **add**: if nil, route to project-level stack |
| `sequence_monitor` | polls state per tick | already pull-based; renders blank on nil |
| `inspector` | reads via `selection_hub` | already tolerates empty selection |

## Out of scope

- Audio/video playback controller behavior in blank state (playback is inert when no sequence is loaded; no code change required — it already pulls from state)
- New project-level undo commands — we use existing mechanism only
- Changes to DRP parse output beyond `resolve_project_tab_ids` assertion set
