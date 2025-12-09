# Layered Mutation & Undo Journal Spec

## Goals
- Re‑establish a strict `Command → Domain Service → Mutator → SQLite` pipeline so commands never reach raw SQL.
- Centralize undo/redo in a mutation journal attached to the mutator layer, eliminating bespoke per-command undo logic.
- Keep timeline caches hot by emitting timeline diff payloads alongside every database change.
- Guarantee algorithmic bounds (no hidden *O(n²)* loops); document and test those bounds.
- Provide instrumentation and tooling so future code cannot regress into ad-hoc database writes.

## Observed Problems
1. **DB writes are scattered:** `src/lua/core/command_implementations.lua` executes SQL directly for clips, properties, tags, imports, etc., making correctness proofs impossible.
2. **Undo complexity:** Each command stores custom snapshots (clip states, occlusion logs, property lists). Regressions appear because nothing enforces consistency between execution, undo, and redo paths.
3. **Timeline reload fallbacks:** Since the command layer guesses how to notify the timeline cache, missing payloads force expensive reloads and replays.
4. **Performance erosion:** `clip_mutator.resolve_occlusions` and similar helpers rescan entire tracks per invocation; repeated edits flirt with *O(n²)* behavior.

## Target Architecture

### 1. Domain Services (DB Accessors)
- **ClipsService, TrackService, MediaService, TagService, PropertyService, SnapshotService** each own *all* SQL touching their tables.
- Services expose intent-focused APIs (e.g., `ClipsService.overwrite_clip`, `TracksService.ensure_default_tracks`, `TagService.assign_master_clip`).
- Services are responsible for:
  - validating inputs,
  - interacting with the Mutation Journal (see below),
  - generating timeline diff payloads,
  - refreshing per-sequence caches (see “Caching Strategy”).
- Commands are reduced to: validate request → call service(s) → capture user state (playhead/selection) → enqueue journal bundle ID for undo.

### 2. Mutation Journal
- A lightweight module records every mutator call inside a command execution scope:
  - table name, primary key,
  - before/after snapshot,
  - semantic action (`insert`, `update`, `delete`, `trim`, `tag_assign`, etc.),
  - optional timeline diff payload.
- On command success the journal bundle is persisted with the command record (instead of one-off parameters).
- Undo = replay journal entries in reverse order; redo = forward order. Commands no longer implement custom undo logic.
- Journal flush also emits collected timeline mutation buckets so `timeline_state` stays in sync without reloads.

### 3. Caching Strategy (Answering the DB accessor question)
- Each service maintains **per-sequence in-memory caches** that sit directly beside the DB accessors, not in commands.
  - `ClipsService` keeps per-track interval windows (balanced interval tree or skip list) keyed by sequence ID; occlusion/mutation queries run against the cache first, falling back to DB hydration on cache miss.
  - `TagService` mirrors tag assignments per project; assign/unassign operations update the memory map and journal simultaneously.
  - Caches subscribe to the Mutation Journal so they invalidate/update entries whenever bundled mutations commit or undo.
- Timeline/UI code continues to own the presentation layer (`timeline_state`), but it relies on the diff payloads the services emit rather than bespoke cache rebuilds.
- This design directly addresses the question: *yes*, the DB accessor layer (services) maintains the per-timeline cache so commands remain thin and no longer manage bespoke caches.

### 4. Command Layer
- Executes validation and orchestration only.
- Captures user-visible state (playhead, selection) once per command and stores it alongside the journal bundle.
- During undo/redo, `command_manager`:
  1. replays the journal bundle (DB + caches),
  2. applies the emitted timeline mutations,
  3. restores captured user state.
- Replay no longer re-runs high-level executors, so we avoid re-importing XML, re-running constraint scans, etc.

## Complexity Guarantees
- **Clip overlaps:** Replace linear scans in `clip_mutator` with interval trees per track. Operations touching `k` clips become *O(k log n)*.
- **Batch imports:** Process media/clip rows via batched INSERTs using temporary staging tables to ensure *O(n log n)* (sorting) or *O(n)* (bulk load) behavior.
- **Tag assignments:** Maintain hash maps for tag↔clip lookups; operations stay *O(1)* amortized.
- Each service documents the complexity of its public APIs. Adding tests/benchmarks guards against regressions (e.g., `tests/perf/test_split_clip.lua` ensures no *O(n²)* splits).

## Implementation Phases
1. **Inventory Pass**
   - Scripted scan for `db:prepare`, `database.exec`, etc.
   - Produce `docs/db_write_map.md` listing each caller and the tables it touches.
2. **Service Skeletons**
   - Create services for clips, properties, tags, tracks/sequences, media, snapshots.
   - Move existing mutator logic (e.g., `Clip:save`, `clip_mutator`) under the new services without behavior changes.
3. **Mutation Journal MVP**
   - Implement journal scopes, entry records, bundle serialization.
   - Integrate with ClipsService first (high ROI) and ensure undo/redo uses the journal for clip-only commands.
4. **Timeline Diff Integration**
   - Services append diff payloads to journal entries; `command_manager` consumes them post-commit.
   - Remove fallback reloads once coverage is verified.
5. **Expand Service Coverage**
   - Gradually migrate remaining command SQL paths to the services. After each migration, delete the command-level SQL and add regression tests.
6. **Enforcement**
   - CI check forbids `db:prepare` outside service directories.
   - Lint/test ensures commands supply journal bundles for undo/redo (no bespoke snapshots).
7. **Performance Benchmarks**
   - Add Lua benchmarks for overwrite, ripple, batch import, and undo/redo to ensure complexity bounds hold (attach to CI jobs).

## Deliverables
- `docs/db_write_map.md` — living inventory of DB writers.
- `src/lua/services/*` — new service modules encapsulating all SQL.
- Mutation Journal module with serialization + tests.
- Updated `command_manager` that consumes journal bundles and timeline diff payloads.
- Benchmark + regression tests proving no *O(n²)* paths and no full timeline reload fallbacks.

## Open Questions / Follow-ups
- **Snapshot Size:** For large imports the journal could become heavy. Plan: chunk bundles and optionally compress them when persisting commands.
- **Cross-Project Commands:** Need a deterministic way to scope caches/journals when commands touch multiple projects (rare but feasible during relinks).
- **Schema Evolution:** Journal format must be versioned so future migrations can replay old bundles safely.

With this structure in place, undo/redo correctness follows from the services’ mutation logs, the command layer becomes thin and verifiable, and caching/performance concerns live in one place instead of being re-implemented per command.
