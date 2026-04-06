# Research: Per-Sequence Undo Stacks

## 1. command_history.lua — Current Multi-Stack Infrastructure

**Decision**: Use and complete the existing multi-stack infrastructure, remove the env var gate.

**Current state**:
- `GLOBAL_STACK_ID` and `TIMELINE_STACK_PREFIX` constants exist
- `undo_stack_states` table maintains per-stack state: `current_sequence_number`, `current_branch_path`, `sequence_id`, `position_initialized`
- `stack_id_for_sequence(sequence_id)` generates per-sequence stack IDs
- `resolve_stack_for_command(command)` determines which stack a command belongs to
- `activate_timeline_stack(sequence_id)` switches active stack and reloads cursor from DB
- ALL of this is gated behind `JVE_ENABLE_MULTI_STACK_UNDO=1` (disabled by default)
- When disabled, everything short-circuits to `GLOBAL_STACK_ID`

**What needs to change**:
- Remove the env var gate — per-sequence is always on
- The stack resolution logic already derives sequence_id from command args — aligns with FR-001
- Per-sequence cursor persistence uses `sequences.current_sequence_number` — already exists in schema
- Need to add `current_branch_path` to sequences table for per-sequence branch tracking

**Rationale**: Infrastructure is ~40% complete. Cheaper to finish than rebuild.

## 2. Branch Tracking Model

**Decision**: Per-sequence branch paths stored in `sequences.current_branch_path`.

**Current state**:
- Single `current_branch_path` tracked in `command_history.lua` module state
- `parent_sequence_number` on each command record forms the undo tree
- Branch forking happens when a new command is recorded with a different parent than the current tip

**What needs to change**:
- Each sequence gets its own `branch_path` (stored in sequences table)
- Global commands get their own branch tracking (stored in projects table or a dedicated table)
- When recording a new command, only fork the active sequence's branch — other sequences' branches unchanged
- `find_latest_child_command()` needs to filter by sequence_id to find redo candidates per-sequence

**Rationale**: Per-sequence branches are required by FR-002. Without them, new work in A kills B's redo.

## 3. History Panel (edit_history.lua)

**Decision**: Filter query by active sequence_id + NULL (project-level).

**Current state**:
- Queries all commands ordered by sequence_number
- Displays flat list with current cursor position highlighted
- No sequence filtering

**What needs to change**:
- Query: `WHERE sequence_id = ? OR sequence_id IS NULL` (active + project-level)
- Highlight position: most recent done command in merged view
- Undone global commands display at their rebase timestamp
- Listen to sequence-switch signal to refresh

**Rationale**: Minimal change — add WHERE clause and refresh on sequence switch.

## 4. Command Args sequence_id Availability

**Decision**: Derive sequence_id from `command_args.sequence_id`. Commands without it are project-level.

**Audit of command types**:
- **Have sequence_id in args**: BatchRippleEdit, RippleEdit, Split, Nudge, Overwrite, Insert, TrimTail, ExtendEdit, DeleteClip, SelectClips, SelectEdges, MoveClipToTrack — all sequence-scoped
- **Do NOT have sequence_id**: ImportMedia, ImportFCP7XML, ImportDRP — project-level
- **Special cases**: CreateSequence has sequence_id but is project-level (creates the sequence). DeleteSequence same. These need explicit classification.
- **Non-recording commands** (Select, Deselect, GoTo): not in commands table, irrelevant

**Rationale**: Derivation from args is reliable. Only CreateSequence/DeleteSequence need explicit overrides.

## Alternatives Considered

1. **Separate commands table per sequence**: Rejected — complicates cross-sequence queries and migration.
2. **Keep single cursor with skip logic**: Rejected — creates holes in the cursor watermark (analyzed in spec discussion).
3. **Global commands as boundaries (never undoable from within sequence)**: Rejected — makes imports permanently non-undoable once any sequence exists.
