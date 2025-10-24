# Selection Snapshot Strategy & Path to Single-State Model

**Audience:** Core undo/redo maintainers  
**Last updated:** 2025‑10‑24  

---

## 1. Current Behaviour (Dual Snapshot)

We presently persist **two** selection snapshots per command:

| Column | Purpose | When captured | Where used |
| --- | --- | --- | --- |
| `selected_clip_ids_pre` / `selected_edge_infos_pre` | User selection *before* the command executes | Immediately prior to `execute_command_implementation()` | Restored right before each replayed command so the executor sees the same context it had originally |
| `selected_clip_ids` / `selected_edge_infos` | User selection *after* the command succeeds | Immediately after the command commits and before `reload_clips()` | Restored after replay when we are at the tip of history (no future redo), so the UI matches what the user last saw |

Key points:

* `undo()` restores the `*_pre` snapshot after the event log has been replayed back to the parent command.
* `redo()` restores the `*_pre` snapshot of the *following* command when one exists (so the next redo remains idempotent); otherwise it falls back to the current command’s post snapshot.
* `reload_clips()` replaces clip objects with freshly loaded ones, so we cannot keep the previous selection by reference. We always recreate it via the serialized snapshots.
* These columns live directly on the `commands` table; no extra metadata tables are involved.

This approach guarantees deterministic replays but stores duplicate data (two JSON blobs per command).

---

## 2. Motivation for a Single-State Model

* Reduce per-command payload (half the JSON columns).
* Eliminate the need to maintain “post” selection for every command when the only consumer is tip reconstruction.
* Make the replay flow conceptually simpler: restore pre-state, run command, let the command (or UI listeners) update the selection naturally.

The core insight is that, during the original execution, the UI already mutated the selection to the post state, and commands rarely touch it. If we can reliably reapply the *pre* selection for the next command in line, the same mutation should naturally occur on replay—removing the need for persistent post snapshots, except at the head of history.

---

## 3. Target Architecture (Single Snapshot + Tip State)

1. **Per-command:** keep only the `*_pre` columns.
   * These remain essential for restoring context before each command executes during replay.
2. **Tip state:** persist the “current UI selection” (what the user last saw) separately, likely in the `sequences` table alongside `playhead_time`.
   * This record gets updated every time the selection changes (already true) or when redo lands on the new head.
3. **Replay rules:**
   * Restore the `*_pre` snapshot before executing each command.
   * When redo lands on a command that still has a future sibling, we do **not** force selection; the next command’s pre snapshot will handle that.
   * When redo lands on the tip (no further child), we restore the selection from the tip state persisted in `sequences`, not from a per-command post snapshot.

---

## 4. Migration Plan

### Step 1 – Audit Current Callers
* Confirm all selection resets originate from `reload_clips()` and listeners (no hidden mutations that depend on post snapshots).
* Verify no executor relies on the post snapshot columns directly.

### Step 2 – Introduce Tip Snapshot Fallback
* Extend `sequences` to include `selected_clip_ids_tip` / `selected_edge_infos_tip` (or reuse existing `selected_*` columns if semantics allow).
* Update selection setters (`timeline_state.set_selection`, `set_edge_selection`) to mark that tip state explicitly.
* Adjust redo so that when `next_query` finds no future command, it restores from the tip snapshot instead of the command’s post columns.

### Step 3 – Dual-Write Transition
* For a short period, continue writing both post and tip snapshots while the new logic reads from the tip when available.
* Add regression coverage to ensure:
  * `undo → undo → redo → redo` maintains selection without consulting post columns.
  * Loading a project at head uses the tip snapshot successfully.

### Step 4 – Drop Post Columns
* Remove references to `selected_clip_ids` / `selected_edge_infos` from code paths once tests prove they are unused.
* Update schema definition (`schema.sql`) and all test fixtures.
* Provide a lightweight migration script (or runtime `ALTER`) to drop the two columns for Developer installs; production migrations are not required per product guidance.

### Step 5 – Clean Up
* Simplify documentation (`PLAYHEAD_SELECTION_PERSISTENCE.md`) to reflect the single-snapshot model.
* Remove any redundant serialization helpers.

---

## 5. Testing Checklist

1. **Lua regression**: `tests/test_selection_undo_redo.lua` should pass without touching post snapshots.
2. **UI smoke**: manual drag/trim scenarios to confirm selection persists correctly on undo/redo.
3. **Batch replay**: `tests/test_command_replay_invariant.cpp` to ensure sequence hashes stay stable.
4. **Session restore**: open, edit, quit, reopen to confirm tip snapshot restores the last selection.

---

## 6. Open Questions

* Do any commands actually mutate selection directly (e.g., to clear it)? If so, we must ensure they still perform the necessary post-step during replay.
* Should the tip snapshot live on `sequences` (per-sequence) or `projects` (if the UI allows multiple sequences)? Current design suggests per-sequence is sufficient.
* How do we handle branching undo history? We need to confirm that switching branches updates the tip snapshot appropriately.

Document owner: `@timeline-core` (update as design evolves).  
Please sync with the undo/redo working group before dropping the post columns in shared branches.
