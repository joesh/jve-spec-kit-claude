# Data Model: Per-Sequence Undo Stacks

## Schema Changes

### commands table — add sequence_id column

```sql
ALTER TABLE commands ADD COLUMN sequence_id TEXT;
```

- NULL = project-level command (Import, CreateSequence, DeleteSequence)
- Non-NULL = sequence-scoped command
- Populated at recording time from `command_args.sequence_id`
- CreateSequence/DeleteSequence explicitly set to NULL despite having sequence_id in args

### sequences table — add branch tracking

```sql
ALTER TABLE sequences ADD COLUMN current_branch_path TEXT DEFAULT '';
```

- Per-sequence branch path for independent redo tracking
- Empty string = on the main branch (same convention as current global branch_path)

### projects table — global cursor storage

Currently the global cursor (`current_sequence_number`) lives in `command_history.lua` module state. For persistence:

```sql
ALTER TABLE projects ADD COLUMN global_undo_cursor INTEGER DEFAULT 0;
ALTER TABLE projects ADD COLUMN global_branch_path TEXT DEFAULT '';
```

- `global_undo_cursor`: position in the global (project-level) command stream
- `global_branch_path`: branch tracking for project-level redo

## Entity Relationships

```
Project (1) ──── (N) Sequence
    │                    │
    │ global_undo_cursor │ current_sequence_number (cursor)
    │ global_branch_path │ current_branch_path (branch)
    │                    │
    └──── (N) Command ───┘
              │
              ├── sequence_id (NULL = project-level, FK to sequences)
              ├── sequence_number (global ordering, unique)
              └── parent_sequence_number (undo tree parent)
```

## Command Classification

| Command Type | sequence_id | Classification |
|-------------|-------------|----------------|
| BatchRippleEdit | args.sequence_id | Sequence |
| Split | args.sequence_id | Sequence |
| Nudge | args.sequence_id | Sequence |
| Overwrite | args.sequence_id | Sequence |
| Insert | args.sequence_id | Sequence |
| TrimTail | args.sequence_id | Sequence |
| ExtendEdit | args.sequence_id | Sequence |
| DeleteClip | args.sequence_id | Sequence |
| MoveClipToTrack | args.sequence_id | Sequence |
| ImportMedia | NULL | Project-level |
| ImportFCP7XML | NULL | Project-level |
| ImportDRP | NULL | Project-level |
| CreateSequence | NULL (explicit override) | Project-level |
| DeleteSequence | NULL (explicit override) | Project-level |
| DeleteMasterClip | NULL | Project-level |

## Cursor State Model

```
Per-Sequence Cursor:
  - sequence_id → identifies which sequence
  - current_sequence_number → last done command for this sequence
  - current_branch_path → which branch this sequence is on

Global Cursor:
  - global_undo_cursor → last done project-level command
  - global_branch_path → which branch for project-level commands

Merged View (for undo/redo walk):
  - Union of: sequence's done/undone commands + global done/undone commands
  - Sorted by timestamp (or rebase timestamp if rebased)
  - Undo: pick the most recent done command, undo it, move its cursor
  - Redo: pick the earliest undone command, redo it, move its cursor
```

## Rebase Semantics

When a global command is undone/redone from a sequence context:
- The command's `timestamp` field is updated to `os.time()` (wall-clock now)
- This moves it to the current position in all history views
- On redo, it stays at its rebased position (does not return to original)
- The original timestamp is lost (rebase is permanent for display purposes)

## Validation Rules

- `sequence_id` on a command MUST reference an existing sequence OR be NULL
- Per-sequence cursor MUST NOT exceed the max sequence_number of that sequence's commands
- Global cursor MUST NOT exceed the max sequence_number of project-level commands
- CreateSequence for the active sequence MUST be a boundary (can_undo returns false)
- Cross-sequence commands: deferred (no current commands touch two sequences)
