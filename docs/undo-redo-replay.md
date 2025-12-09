# Undo/Redo Replay & Snapshot Architecture

## Overview
The editor is event-sourced: the timeline is reconstructed from the `commands` log instead of mutating state directly. Undo/redo works by replaying the command stream back to a target sequence number. To keep this fast and deterministic we combine three data sources:

1. **Snapshots** – periodic JSON dumps of every captured sequence: sequence row, tracks, clips, and referenced media saved after specific commands.
2. **Cached initial state** – in‑memory copies of the media library and master-sequence topology gathered when the command manager boots.
3. **Timeline state persistence** – the `sequences` table stores playhead, viewport, and selection information whenever the UI changes them.

Replay stitches these sources back together and only executes the minimum set of commands necessary.

## Data Snapshots
- Created every `SNAPSHOT_INTERVAL` commands (or on explicit request).
- Stored in the `snapshots` table as JSON bundles per sequence:
  - `sequence`: the full `sequences` row (playhead, viewport, selection, etc.).
  - `tracks`: every track for that sequence, preserving order and flags.
  - `clips`: serialized clip rows with all identifying fields.
  - `media`: all media rows referenced by those clips (deduplicated within the bundle).
- Represent the *post-command* state at the moment they were captured.

### Serialization guarantees
- Every clip must provide `id`, `project_id`, `owner_sequence_id`, timing fields, and enable/disable flags.
- Every media record must include `id`, `project_id`, `file_path`, and timing metadata.
- Every track must provide `id`, `sequence_id`, ordering, and enable/lock/mute/solo state.
- Each snapshot payload must include the owning sequence metadata so we can rebuild the timeline table before inserting tracks/clips.
- Missing data raises a fatal error so corrupt snapshots fail fast.

## Replay Flow
1. **Discover project/sequence** – fetch `project_id` for the active sequence; this prevents us from clearing the wrong project tables.
2. **Load snapshot (if any)** – fetch the snapshot bundle for the active sequence plus every other project sequence whose snapshot sequence number ≤ target. Multiple sequences can be restored in one pass.
3. **Merge cached baseline** – fill in master sequences/tracks and cached media that are not part of the snapshot (initial boot state).
4. **Purge DB state** – clear timeline clips/media and any derived master rows so replay always starts from a clean slate.
5. **Restore base rows** – bulk insert master entities, then rebuild each snapshot sequence (sequence row → tracks → clips), ensuring referenced media rows exist.
6. **Replay commands (if required)** – walk parent links from the target command back to the snapshot sequence and execute each command implementation in order.
7. **Finalize timeline state** – the caller reloads clips in the UI and restores selection from the command log (post-state). When no commands are replayed we still reload the target sequence in `timeline_state`, restore viewport + playhead from the `sequences` row, and feed selection JSON back through the standard helper so the UI lands exactly on the snapshot state.

## Edge Cases & Invariants
- **Snapshot == target** – the command chain is empty; the snapshot already represents the desired state, including secondary sequences created earlier (imports, compound timelines, etc.). We must *not* reset the playhead or selection. Instead, read the persisted playhead from `sequences` and let the caller restore selection from the command log.
- **Undo to sequence 0** – no snapshot exists; clearing state to zero remains correct.
- **Missing media** – loading clips requires valid media rows. `load_clips` enforces this and aborts replay if a clip references a missing media entry.
- **Branching histories** – command parent links define the active branch. Replay always follows parent pointers rather than sequence_number - 1.
- **UI persistence** – `timeline_state.persist_state_to_db` keeps playhead/viewport/selection synchronized with `sequences`. Replay relies on these persisted values when no commands are executed.

## Practical Guidelines
- When touching replay logic, update this spec. Future contributors should understand which layer owns each piece of state.
- Never silently substitute defaults (playhead 0, empty selection, etc.) when required data is missing; instead abort with a clear error. This keeps undo/redo deterministic.
- If new fields are added to snapshots, update the serializer assertion list and the replay restore step together.
