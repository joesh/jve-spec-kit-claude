# Phase 0 — Research

## Decisions

### 1. `clear()` primitives rather than `init(nil, nil)` overload
- **Decision**: Add distinct `clear()` functions on `timeline_state` and `command_manager`. Keep `init(sequence_id, project_id)` strict (both non-nil).
- **Rationale**: `init` is called in ~6 places with assumed non-nil values; relaxing it risks silent drift. A distinct `clear()` has an unambiguous contract and is trivial to grep.
- **Alternatives**:
  - Overload `init(nil,nil)` — rejected: weakens existing assertions, forces every init caller to re-read the contract.
  - Single `set_active(seq_id_or_nil)` — rejected: conflates construction with transition; `init` also wires project_id which `clear` must retract.

### 2. `unload_sequence()` on `timeline_panel` as inverse of `load_sequence`
- **Decision**: New function performs:
  1. `state.clear()`
  2. `command_manager.deactivate()`
  3. Blank the timeline monitor (`timeline_monitor.set_sequence(nil)` or equivalent)
  4. `selection_hub.update_selection("timeline", {})` (inspector reacts via existing pull)
  5. `database.set_project_setting(pid, "last_open_sequence_id", "")`
  6. `database.set_project_setting(pid, "open_sequence_ids", {})`
- **Rationale**: Mirrors `load_sequence`'s five-step transition. Puts the whole inverse in one function so close-tab, startup blank, and sequence-delete all call a single primitive.
- **Alternative**: Split into three (state clear, persist clear, monitor clear) — rejected: fragmented transitions are where push-vs-pull bugs hide.

### 3. No new `sequence_unloaded` signal
- **Decision**: Reuse `selection_hub.update_selection("timeline", {})` to trigger inspector refresh. Monitor reads state.get_sequence_id() on its existing tick/pull path.
- **Rationale**: MVC principle (views pull). A new signal would be a push-broadcast where one doesn't belong.
- **Alternative**: Add `Signals.emit("sequence_unloaded")` — rejected: invents a pub/sub contract that existing modules don't need.

### 4. DRP resolver: case 1 empty, cases 2/3/4 assert
- **Decision**:
  - Case 1 (no SequenceTabsData AND no TimelineHandleVec) → leave `project.open_timeline_ids = {}`, `active_timeline_id = nil`. Legitimate format variant; downstream opens into blank state.
  - Case 2 (CTI ≥ len(TimelineHandleVec) or CTI < 0) → `assert` with actionable message.
  - Case 3 (referenced `Sm2Timeline.DbId` has no entry in `timeline_id_map`) → `assert`.
  - Case 4 (`TimelineHandleVec` non-empty but `CurrentTimelineIndex` missing) → `assert`.
- **Rationale**: Case 1 is file-format variation. Cases 2/3/4 are file corruption or parser bugs — fail loudly (principle VI).
- **Alternative**: Assert case 1 too — rejected: would break legitimate DRPs that shipped without tab metadata.

### 5. Drop-to-blank reuses existing command types
- **Decision**: Handler flow (pseudocode):
  ```
  on_drop_to_empty_timeline(items):
    sequences, clips = partition_droppable(items)   -- recurses bins into clips
    if #sequences > 0:
      for seq in sequences: open_tab(seq.id)        -- last one becomes active
    if #clips > 0:
      name = name_from_first_clip(clips)
      fps, w, h = settings_from_first_clip(clips)
      in undo group:
        seq_id = create_sequence(name, fps, w, h)
        for c in clips: insert_clip(seq_id, c)
      open_tab(seq_id)                              -- becomes active
  ```
- **Rationale**: No new command types (principle II). One undo group per drop = one atomic user action.
- **Alternative**: Bespoke `drop_to_blank` command — rejected: duplicates existing `create_sequence` + `insert_clip` logic.

### 6. Sequence name construction
- **Decision**: Pure function `build_drop_sequence_name(first_clip_name, additional_count)`:
  - `additional_count == 0` → returns `first_clip_name` unchanged.
  - `additional_count >= 1` → returns `first_clip_name .. " (+" .. additional_count .. " more)"`.
- **Rationale**: Testable in isolation; exact format matches spec's example `A001_C001.mov (+3 more)`.
- **Alternative**: Embed formatting in the drop handler — rejected: untestable without widget setup.

### 7. First-clip settings extraction
- **Decision**: Query the existing `asset_info`/`media_cache` API for the first clip's fps + resolution. Fall back to project defaults only when both are nil/unusable (e.g., audio-only media).
- **Rationale**: Matches spec Q2 answer; reuses existing media metadata cache.
- **Alternative**: Re-probe via ffprobe — rejected: already cached; wasteful.

### 8. Project-level undo fallback routing
- **Decision**: `command_manager` already maintains per-sequence and project-scoped command stacks (per prior work on per-sequence undo, commit `fcfb681`). When `get_sequence_id()` returns nil, undo/redo dispatches to the project-scoped stack instead of the per-sequence stack. If no project stack exists yet (newly-opened blank project), undo is inert (no error, no-op).
- **Rationale**: Reuses existing dual-stack architecture. No new data structure.
- **Alternative**: Single global stack — rejected: loses per-sequence isolation that already works.

### 9. Sequence-delete cascade
- **Decision**: The existing sequence-delete command handler iterates open tabs; for each tab whose sequence_id matches the deleted id, it calls `close_tab(seq_id)` — which now in turn calls `unload_sequence()` if it was the last tab. No special-case "last tab" logic at the delete site.
- **Rationale**: Keeps delete generic; relies on `close_tab`'s existing last-tab branching.
- **Alternative**: Delete handler explicitly checks `#open_tabs == 1` — rejected: duplicates logic in close_tab.

### 10. Non-active tab close does NOT discard per-sequence undo
- **Decision**: `close_tab` only removes the tab widget + `open_tabs[seq_id]` entry. The per-sequence command stack in `command_manager` persists on disk (via existing per-sequence stack tables) and is restored if the sequence is reopened — including when restored via undo of the deletion.
- **Rationale**: FR-014. If the user undoes a delete, the sequence's edit history returns intact.
- **Alternative**: Clear the stack on close — rejected: loses user work.

## Unknowns resolved

All `NEEDS CLARIFICATION` markers were already resolved during `/clarify` (5 questions, 5 answers). No residual unknowns.

## Dependencies already present

- `command_manager` per-sequence + project-scoped stack split (FU-5, commit `fcfb681`)
- `selection_hub.update_selection` broadcast to inspector
- `selection_hub` + inspector pull-based MVC
- `database.get_project_setting` / `set_project_setting` for JSON tab persistence
- `timeline_panel.load_sequence` five-step transition (reference implementation for `unload_sequence`)
- DRP `resolve_project_tab_ids` (just landed on 009 branch, merge commit 87567fb) — edit in place.

## Risks

| Risk | Mitigation |
|---|---|
| Hidden callers assume `get_sequence_id() ~= nil` and crash on blank state | Explore-agent survey already identified the call sites (see spec Phase 0). Nil-guards are a distinct task group. |
| `timeline_monitor` blanking leaves a stale last frame | Call `sequence_monitor.clear()` (or equivalent); covered by binding test. |
| Legacy `.jvp` projects without tab settings now open blank where they used to open sequences[1] | Per principle VIII (no backcompat): acceptable behavior change. User can open a sequence from the browser. |
| Drop handler undo-group spanning sequence create + clip inserts could leave partial state on error | Use existing `command_manager.execute_group` which rolls back on any failure. |
