# Phase 0 Research: Inspector Rewrite (012)

This document resolves every `/plan`-deferred open item from `spec.md`. It is the authoritative source for Phase 1 design decisions.

---

## 1. FR-023c — Property enumeration (clip and sequence)

**Method**: audited `src/lua/models/clip.lua`, `src/lua/models/sequence.lua`, `src/lua/core/database/schema.sql`, `src/lua/inspectable/{clip,sequence}.lua`, `src/lua/ui/metadata_schemas.lua`, the playback engine, timeline_resolver, source viewer, and renderer for consumers of each column.

**Inclusion criterion** (per FR-023 / FR-023a): property is read by some subsystem that acts on it (renderer, audio engine, timeline display, source viewer, export, persistence consumer). Columns that exist in schema but have no consumer, or are structural identity / audit metadata, are OUT OF SCOPE.

### 1.1 Clip properties in scope

| Key | Type | Consumers | Editable? | Today's UI | Schema section (Resolve-style) |
|---|---|---|---|---|---|
| `name` | STRING | Timeline label, project browser, Inspector | yes | Project browser rename, timeline label | File |
| `media_id` | STRING (read-only) | Media lookup, renderer, relinker | no (edited via Relink dialog) | Relink dialog | File |
| `offline` | BOOLEAN (read-only, transient) | Media-status registry, playback engine | no (derived) | Status indicator | File |
| `rate` | RATIONAL (read-only) | Playback engine, renderer, frame math | no (from media) | Display only | File |
| `timeline_start` | TIMECODE | Playback engine, timeline UI, renderer | yes | Timeline drag, trim | Source Range |
| `duration` | TIMECODE | Playback engine, renderer, timeline | yes | Timeline trim handles | Source Range |
| `source_in` | TIMECODE | Playback engine, source viewer, renderer | yes | Source viewer marks | Source Range |
| `source_out` | TIMECODE | Playback engine, source viewer, renderer | yes | Source viewer marks | Source Range |
| `mark_in` | TIMECODE (nullable) | Source viewer UI, selection | yes | Source viewer marks | Source Range |
| `mark_out` | TIMECODE (nullable) | Source viewer UI, selection | yes | Source viewer marks | Source Range |
| `playhead_frame` | TIMECODE (read-only) | Source viewer state | yes (via source viewer) | Source viewer playhead | Source Range |
| `enabled` | BOOLEAN | Playback engine, timeline filter | yes | Track toggle / clip enable | File |
| `volume` | DOUBLE | Audio mixer, playback engine | yes | Audio track mixer | Audio |

### 1.2 Sequence properties in scope

| Key | Type | Consumers | Editable? | Today's UI | Section |
|---|---|---|---|---|---|
| `name` | STRING | Timeline tab, project browser | yes | Timeline tab rename | Project |
| `frame_rate` | RATIONAL (read-only) | Renderer, all timeline math | no | Display only | Project |
| `width` | INTEGER (read-only) | Renderer, canvas size | no | Display only | Project |
| `height` | INTEGER (read-only) | Renderer, canvas size | no | Display only | Project |
| `audio_sample_rate` | INTEGER (read-only) | Audio mixer | no | Display only | Project |
| `start_timecode_frame` | TIMECODE | Ruler rendering, timecode display | yes | Ruler start | Project |
| `playhead_position` | TIMECODE | Playback engine, timeline ruler | yes | Timeline playhead drag | Viewport |
| `mark_in` | TIMECODE (nullable) | Source viewer, mark display | yes | Mark set commands | Marks |
| `mark_out` | TIMECODE (nullable) | Source viewer, mark display | yes | Mark set commands | Marks |

**Debatable (decided here):**
- `video_scroll_offset`, `audio_scroll_offset`, `video_audio_split_ratio`: these are **UI layout state**, not user-facing properties. Users manipulate them implicitly via scroll and splitter drag; surfacing them in the Inspector as editable numeric fields adds no value and invites bugs. **Decision: OUT OF SCOPE for Inspector.** They stay persisted on the sequence row (no schema change), but the Inspector does not render them.
- `viewport_start_time` and `viewport_duration`: same reasoning as above. Users set these by horizontal scroll and zoom gestures on the timeline; numeric entry in the Inspector is not a Resolve-parallel interaction and would be a surprising affordance. **Decision: OUT OF SCOPE for Inspector** (raised in /analyze as finding I1). They remain on the sequence row as persisted state; the Inspector does not render them.

### 1.3 Out of scope (explicitly noted)

- Clip: `clip_kind`, `master_clip_id`, `owner_sequence_id`, `track_id`, `project_id`, `id`, `created_at`, `modified_at` — all structural identity or audit metadata.
- Sequence: `kind`, `mutation_generation`, `current_sequence_number`, `current_branch_path`, `selected_clip_ids_json`, `selected_edge_infos_json`, `selected_gap_infos_json`, `project_id`, `id`, `created_at`, `modified_at` — structural, volatile UI state, or undo cursor.
- Resolve's transform / composite / crop / retime / blend-mode properties — **do not exist in the current data model**; deferred to the features that introduce their consumers (per Session 2026-04-19 Part 2, Q-Property-existence).

### 1.4 Surprises / notes for implementation

- No "zombie" columns — every schema column is consumed or structural. We do not need a schema cleanup pass.
- `rate` is per-clip in the schema but must equal the sequence rate for timeline clips; validated at `clip.lua:162–169`. Inspector displays it read-only.
- `offline` is transient — not persisted on save; recomputed from file existence. Inspector displays read-only.
- A `properties` table exists in `schema.sql` for arbitrary key-value storage but is unused in the standard flow. Out of scope for this feature.
- Masterclip-is-a-sequence identity: `clip.lua:87–90` aliases `master_clip_id` to the sequence id. Inspector's `clip` vs `sequence` schema detection relies on `inspectable:get_schema_id()` which already handles this correctly.

---

## 2. FR-023e — Existing property-editing UI inventory

### 2.1 Form-editing UIs (migrate into Inspector schema, then delete)

| File | Lines | Properties edited | Entry point | Disposition |
|---|---|---|---|---|
| `src/lua/ui/inspector/view.lua` | 400–700 | all clip / sequence metadata | Inspector panel | **Delete** — replaced by the rewrite |
| `src/lua/ui/timeline/timeline_panel.lua` | 291–310 | sequence `playhead_position` via SetPlayhead | Timecode entry field in timeline header | **Keep** — this is a specialized affordance (timecode-as-keyboard-entry at the timeline ruler), not a duplicate of the Inspector row. It edits the same property as the Inspector row but via a different modality (keyboard-focused, always-visible). **Classified as specialized tool surface per Session 2026-04-19 Part 2.** |
| `src/lua/ui/project_browser.lua` | 2478–2551 | clip/sequence `name` | F2 / right-click → Rename | **Keep** — inline tree rename is a specialized interaction (tree-item edit gesture). Inspector row for name coexists. |
| `src/lua/ui/find_replace_dialog.lua` | 44–90 | any searchable editable clip field | Cmd+H | **Keep** — batch search-and-replace across many clips is fundamentally not a single-selection Inspector form row. Specialized tool. |
| `src/lua/ui/timeline/timeline_panel.lua` | 1220–1268 | track `muted`, `soloed` via SetTrackProperty | M / S buttons in track header | **Keep** — track properties, not clip/sequence properties. Out of the Inspector's two-schema scope (tracks are not one of the supported schemas). **No Inspector migration needed.** |

**Net result**: the only form-editing UI being deleted is the existing `view.lua` itself. Every other property-editing surface is a specialized tool and coexists with the rewritten Inspector — exactly the outcome Session 2026-04-19 Part 2 Option C+D predicted.

### 2.2 Dead code / worktree copies (delete outright)

| File | Status |
|---|---|
| `clip_audio_inspector.lua` (repo root) | Dead; test fixture / stale worktree. Delete. |
| `.claude/worktrees/agent-a605dc4d/clip_audio_inspector.lua` | Stale worktree copy. Leave to worktree cleanup. |
| `src/lua/ui/inspector/adapter.lua` | Orphaned — only referenced by dead `main_window.lua`. Delete. |
| `src/lua/ui/inspector/widget_pool.lua` | Flattened per Q2. Delete. |
| `src/lua/core/runtime/controller/selection_inspector.lua` | Orphaned. Delete. |
| `src/lua/ui/main_window.lua` | Orphaned; uses `scripts.*` require paths that don't resolve. Delete. |
| `tests/test_inspector_modules.lua` | Tests the dead adapter. Delete. |

### 2.3 Stub entry points to remove

| File:Line | What | Action |
|---|---|---|
| `src/lua/ui/timeline/timeline_panel.lua:395` | `function M.set_inspector(_)` empty stub, comment says "routed through selection_hub" | Delete the function + any callers (there are none in live wiring). |
| `src/lua/ui/project_browser.lua:1668` | `function M.set_inspector(inspector_view)` stores reference; grep shows nothing reads `M.inspector_view`. | Verify unread once more during Phase D; delete if confirmed. |

---

## 3. Contract audit of surrounding systems

### 3.1 `selection_hub` (`src/lua/ui/selection_hub.lua`)

- API used by Inspector: `register_listener(callback) → token`, `set_active_panel(panel_id)`. Callback signature `(items, panel_id)`.
- **Items are opaque** in the hub. Each panel is responsible for the item shape it passes. The timeline and project browser today pass tables with fields `{item_type, clip_id, sequence_id, project_id, display_name, …}` (see `resolve_inspectables` in the current `view.lua`). The Inspector maps those fields to inspectable factory calls.
- Notification is synchronous direct fan-out (not a Signals emission). No re-entrancy guard in the hub.
- **No click-order preservation.** For FR-005a's "most-recently-clicked" tiebreak, the Inspector must track previous-selection IDs locally and treat "first item not in previous selection" as the click.

### 3.2 `Signals` (`src/lua/core/signals.lua`)

- `Signals.connect(name, handler, priority)`, `Signals.emit(name, ...)`, `Signals.disconnect(id)`.
- Handlers pcall'd internally (line 233) — errors do not abort the chain.
- Used signals Inspector consumes:
  - **`content_changed(sequence_id)`** — emitted at `command_manager.lua:199` after every command execution, and at `timeline_core_state.lua:640` on state changes. Inspector matches on `sequence_id` to decide whether to pull.
  - **`project_changed(new_project_id)`** — emitted at `commands/open_project.lua:142`.

### 3.3 `command_manager` (`src/lua/core/command_manager.lua`)

- `begin_command_event(origin)` / `end_command_event()`: nestable depth counter. Only outermost sets origin. Inspector uses `origin="ui"`.
- Undo grouping: root command captures `sequence_number`; nested commands inherit as `undo_group_id`. Multi-edit Apply wraps N `inspectable:set` calls in one begin/end pair — all share one undo group.
- `execute_interactive(cmd)`: what `inspectable:set` calls internally.

### 3.4 `inspectable` factory (`src/lua/inspectable/{clip,sequence}.lua`)

- Constructor: `ClipInspectable.new({clip_id, project_id, sequence_id?, clip?, metadata?})` / `SequenceInspectable.new({sequence_id, project_id, sequence?})`.
- API used by Inspector: `:get(key)`, `:set(key, payload)`, `:refresh()`, `:get_display_name()`, `:supports_multi_edit()`, `:get_schema_id()`.
- `:set` payload: today `{value, property_type, default_value}`. **This feature adds `property_type == "TIMECODE"` as a distinct branch** (Session 2026-04-19, Q3). Value is integer frames; frame rate remains on the owning entity.
- `:supports_multi_edit()`: `clip` returns true, `sequence` returns false. FR-008 read-only path already covered by this.
- **Non-goal protects this factory**: we do not change its API shape beyond adding the TIMECODE branch to `:set`'s switch.

### 3.5 `collapsible_section` (`src/lua/ui/collapsible_section.lua`)

- `create_section(title, parent)` returns `{section, section_widget, content_layout}`.
- `section:addContentWidget(widget)` adds to content layout.
- `section:setExpanded(bool)` toggles visibility; `self.expanded` is the in-memory flag.
- **State is not persisted** — this is precisely what FR-021a fixes via `persistent_widget`.

### 3.6 `qt_constants` / `ui_constants` (live; no changes)

Inspector will consume:
- `qt_constants.WIDGET.*`, `LAYOUT.*`, `PROPERTIES.*`, `DISPLAY.*`, `GEOMETRY.*`, `CONTROL.*`
- `ui_constants.COLORS.{FIELD_BACKGROUND_COLOR, FIELD_TEXT_COLOR, FIELD_BORDER_COLOR, FOCUS_BORDER_COLOR, FIELD_FOCUS_BACKGROUND_COLOR, LABEL_TEXT_COLOR, HEADER_TEXT_COLOR}` and any new keys we add for the header bar, batch banner, and read-only field styling.
- `ui_constants.FONTS.*` and `LAYOUT.*` for spacing / label width.
- **New ui_constants keys** (added alongside this feature): `COLORS.INSPECTOR_HEADER_BG`, `COLORS.INSPECTOR_APPLY_BTN_BG`, `COLORS.INSPECTOR_APPLY_BTN_HOVER`, `COLORS.INSPECTOR_APPLY_BTN_PRESSED`, `COLORS.INSPECTOR_CONTENT_BG`, `COLORS.FIELD_ERROR_BORDER`, `COLORS.FIELD_READ_ONLY_TEXT`. Eliminates the hardcoded `#2b2b2b` / `#3a3a3a` / `#4a90e2` / `#5aa0f2` / `#3a80d2` inline styles in the current `view.lua`.

### 3.7 Missing: `persistent_widget` (to be built new)

- **Does not exist today.** Rule 1.6 ("all widgets inherit PersistentWidget") is aspirational in the codebase.
- This feature builds the minimal primitive:
  - API: `persistent_widget.register(key, get_state_fn, set_state_fn)`, `persistent_widget.save()`, `persistent_widget.load()`, `persistent_widget.install_autosave(signal_name)` (optional convenience).
  - Storage: JSON file at `~/.jve/widget_state.json`. Loaded on app start, saved on app quit + opportunistically on project_changed.
  - First consumer: Inspector section collapse state, keyed as `inspector.section.<schema_id>.<section_name>.expanded`.
  - Scope: this feature ships the primitive + one consumer. Other widgets adopting it is a later effort.

---

## 4. Resolutions of remaining plan-level unknowns

| Open item | Resolution |
|---|---|
| Most-recently-clicked tiebreak without changing selection_hub | Inspector stores previous selection IDs locally; "click" = "first item in new selection not in previous set." If full overlap (user reshuffled without adding/removing), keep the previous active schema — delivers the FR-005a "stable across selection updates that do not change the set of schemas present" invariant. |
| Single refresh channel when two exist today | Keep `Signals.connect("content_changed", ...)` only. Delete the `timeline_state.add_listener` subscription in the rewritten module. |
| Self-triggered refresh loops | `suppress_field_updates` depth counter remains (wrapping `load_single`/`load_multi`). The outer `content_changed` after an inspector commit re-enters and does an idempotent pull — no harm, simpler than a self-ID guard. |
| Persistent-widget backend format | JSON in `~/.jve/widget_state.json`. Not QSettings (opaque, platform-specific). Not SQLite (overkill; widget state is small and independent of projects). |
| TIMECODE branch placement | `inspectable/clip.lua` and `inspectable/sequence.lua` each grow a `property_type == "TIMECODE"` arm in the switch inside `:set`. Integer frames are written as-is to the underlying column (which is already an integer frame count). The "branch" is really a parse-pass-through with an assertion that `value` is a non-negative integer. |
| Field `read_only` flag placement | In each field definition in `metadata_schemas.lua` (alongside `default`, `options`). `field_widget.lua` reads it at create time; if set, the widget is created in disabled style and no signal handlers are connected. Read-only fields do not participate in pending-edit state. |
| Test fixtures for `--test` scripts | Each scenario creates its own test project via `Project.create` in a temp dir, adds clips/sequences, exercises the scenario, asserts via the public inspector module + inspectable state. No reliance on existing project DBs. |

---

## 5. Phase 0 Gate

All Technical Context NEEDS CLARIFICATION items are resolved. No blocker for Phase 1 design.
