# Timeline Undo & Collaboration Strategy

This document captures how we want to scope undo stacks, persistence, and collaboration semantics going forward. It builds on recent work around selection persistence and highlights reference behaviour from other NLEs.

## Reference Behaviour in Other NLEs
- **DaVinci Resolve** keeps independent undo queues per timeline (and per page). Switching timelines reactivates its queue; project-level actions (media pool, settings) stay on a global stack.
- **Adobe Premiere Pro** uses panel-specific undo. The active panel (timeline, project browser, graphics) consumes its own history, and composite actions are mirrored into each impacted stack. A global History panel exposes the ordered list.
- **Final Cut Pro** scopes undo to the focused context (timeline, browser, inspector). Compound actions that touch multiple contexts create grouped entries. Undo state serialises with the library so reopening a project restores context-aware history.

## Proposed Stack Model for JVE
- **Per-timeline stacks**: each timeline gets its own command stack and head pointer. Focus-based shortcut routing determines which stack `Undo/Redo` hits.
- **Global stack**: browser imports, project metadata, layout or preferences continue to use the existing global stack.
- **Composite commands**: actions that bridge contexts (e.g., dragging from browser to timeline) produce linked entries—the timeline stack records the timeline mutation, the global stack records media usage, and both point back to a shared transaction id.
- **UI affordances**: surface active stack information (status text or history palette) so users know which queue they are undoing against, matching industry expectations.

## Persistence & Save Format Implications
- Command log entries gain a `stack_id` (timeline id or `global`) plus an optional `transaction_id` for composites.
- Project saves persist each stack’s head pointer and branch markers so reopening resumes undo availability exactly where the user left off.
- Autosave and migration code must initialise per-timeline stacks when loading older projects; no schema migrations are required if we treat the metadata as runtime scaffolding.

## Collaboration Considerations
- **Per-timeline isolation** reduces interference: editors working on different timelines append to distinct stacks. Session ownership/locks still gate simultaneous edits on the same timeline.
- **Global operations** remain serialised; undo entries include author metadata so collaborative tooling can warn before rolling back another user’s work.
- **Branching model**: because we remain event sourced, a server can maintain branches per editor and merge via deterministic replay, similar to rebasing command streams.

## Event Sourcing Compatibility
- We keep the append-only log. Stack IDs simply shard the event stream, and head pointers become read-model state. Undo in a timeline replays its slice exactly as today; the global stack replays the rest. The event sourcing model remains intact.

## CRDT Evaluation
- **Upside**: true lock-free concurrency and automatic convergence.
- **Downside**: requires re-implementing undo as compensating operations, mapping every timeline command to CRDT operations, and handling potentially surprising auto-merges in the UI. Migration/testing cost is high.
- Conclusion: CRDTs are disproportionate for our current needs; per-timeline stacks plus coordination provide safer, predictable semantics.

## Google Docs-like Collaboration Without Full CRDT
- **Authoritative ordering with local prediction**: clients execute commands locally, then reconcile against the server’s canonical order. Conflicts surface as explicit prompts.
- **Fine-grained soft locks & presence**: show who is touching which clip or edge to prevent clashes before they happen.
- **Session branches**: give each editor a lightweight branch of the command log, merge frequently, and resolve only true conflicts.
- **Selective CRDT usage**: apply CRDT-style replication only to low-stakes data (markers, comments) where it pays off, keeping timeline edits command-based.

This approach delivers collaborative “feel” (live updates, awareness) while preserving deterministic undo/redo and avoiding the heavy rewrite a full CRDT timeline would require.

## Current Implementation Inventory (2025-10-28)
- **Command routing**: All commands flow through `src/lua/core/command_manager.lua` (see lines 18-116, 205-352). Keyboard shortcuts (`src/lua/core/keyboard_shortcuts.lua:69-210`) and menu handlers (`src/lua/core/menu_system.lua`) call the single global instance; there is no focus-based selection of alternate stacks yet.
- **Non-recorded commands**: `command_manager` skips persistence for entries listed in `non_recording_commands` (Select/Deselect All, GoTo* commands). Everything else is appended to the global log.
- **Command log schema**: Lua tests define `commands` tables with columns `id`, `parent_id`, `parent_sequence_number`, `sequence_number`, `command_type`, `command_args`, `pre_hash`, `post_hash`, `timestamp`, `playhead_time`, `selected_clip_ids`, `selected_edge_infos`, plus `_pre` variants (e.g., `tests/test_cut_command.lua:56-69`). There is currently no stack identifier or transaction metadata.
- **Undo pointers**: `current_sequence_number` and `current_branch_path` (command_manager.lua:124-138) track a single undo position across the entire project; replay always walks the global event stream regardless of timeline.
- **Selection capture**: `capture_selection_snapshot()` lives in `command_manager.lua:142-191`, showing that timeline state access is centralized and assumes a single active sequence (`active_sequence_id` global at line 32).
- **Persistence helpers**: `ensure_command_selection_columns()` (command_manager.lua:196-233) mutates the DB schema at runtime, confirming that all history is stored in one table shared by every timeline.

This baseline informs the plan for introducing per-timeline/global stacks and the supporting metadata.
