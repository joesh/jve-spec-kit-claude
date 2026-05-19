# Research: Uniform Clip Source Timebase with Canonical-Clock Sub-Frame Primitives

**Phase**: 0 — design tradeoff investigation
**Status**: Complete
**Spec**: [spec.md](spec.md)
**Plan**: [plan.md](plan.md)

This file records the design tradeoffs the team considered before committing to the spec's final shape, the alternatives that were rejected, and the rationale for the chosen path. Every decision below is already reflected in `spec.md`; this document is the long-form "why".

---

## R1. Sub-frame representation

### Question

How should sub-frame precision be stored on each clip row?

### Alternatives considered

| Option | Storage | Tradeoff |
|---|---|---|
| **(a) Canonical project clock (CHOSEN)** | INTEGER ticks at project-wide `master_clock_hz` (default 192000 Hz), one row pair per audio clip. | Single rate for all clip-level math; reads and writes consult the project's `master_clock_hz`. Round-trip exact for every divisor file rate (48k, 96k, 192k, 24k, …). Non-divisor rates (44.1k) introduce ≤0.5 sample of conversion error — below any human-perceptible threshold and below the minimum BWF-TC-precision the file format itself can express. Decouples clip storage from per-file rates. Single value to migrate if the user ever needs higher precision (`SetProjectMasterClock`). |
| (b) Rational (`subframe_num`/`subframe_den` per clip) | Two INTEGER columns per audio source position. | Exact for any file rate, no rounding error ever. BUT: every clip carries its own denominator, doubling subframe storage, and arithmetic across clips (e.g. ConformSequence rescaling, comparison, sort) requires normalizing denominators or upcasting to a common base. Schema-layer invariant checks (FR-002, "subframe < ticks_per_frame") become per-row rather than per-project. Extra storage and complexity for a precision class no audio tool downstream can consume — file-natural decode is integer-sample, and conversion back to integer samples loses any sub-tick precision the rational form bought us. |
| (c) Per-media_ref clock | Sub-frame stored in the audio media_ref's native sample rate. | Was the legacy convention (the bug this spec fixes). The clip layer would need to know which media_ref it would ultimately resolve through in order to interpret its own sub-frame — but masters with heterogeneous audio rates (Acceptance Scenario 2) make that ambiguous: which media_ref's rate "owns" the clip's sub-frame when both 48k and 96k media_refs lie under the same clip? The data model would need to drop multi-rate audio in one master, which is the very capability Joe specifically rejected. Re-introduces order-dependence. |

### Decision

**(a)**, with `master_clock_hz` defaulting to 192000.

### Why 192000 Hz?

- LCM-friendly with the four common pro audio rates: 48000 (÷4), 96000 (÷2), 192000 (÷1), 24000 (÷8). All round-trip exactly.
- 44100 / 88200 / 176400 do NOT divide 192000. Conversion error bound: `0.5 / 192000` ≈ 2.6 µs. The smallest sample period at 44.1k is 22.7 µs — i.e. the worst-case clip-position error is one ninth of a 44.1k sample. Imperceptible.
- Comfortably within INTEGER range: ticks_per_frame at 24/1 = 8000, at 23.976 (24000/1001) ≈ 8008, at 60/1 = 3200. All fit in INT32 with five orders of magnitude headroom; INT64 is the schema type, leaving even more.
- Industry precedent: ProTools internal clock is 192k; FFmpeg's `AV_TIME_BASE` is 1000000 (microsecond, a coarser but similar-purpose canonical clock).

### Rejected: variable per-project clock at creation time

Was considered to let users opt for a smaller clock (e.g. 48000) to save subframe-column bytes on huge projects. Rejected: a 10k-clip project's subframe columns total ~160 KB of disk regardless of clock value (INT64 size is fixed). The clock value affects precision, not storage. Defaulting to 192000 is the safe choice and `SetProjectMasterClock` exists for users with a specific reason to deviate.

---

## R2. `sequences.fps` single-writer enforcement

### Question

How do we prevent any code path other than `ConformSequence` from mutating `sequences.fps_numerator` / `sequences.fps_denominator`?

### Alternatives considered

| Option | Where | Strength |
|---|---|---|
| **(a) SQLite trigger + session flag (CHOSEN)** | Database layer. Trigger fires on `BEFORE UPDATE OF fps_numerator, fps_denominator ON sequences`; raises ABORT unless a session-scoped flag (set via `PRAGMA user_version` or a `_session` temp table) is currently set. `ConformSequence` sets the flag inside its transaction before any UPDATE and clears it on commit. | **Statically-verifiable** (Constitution V.21): the rule lives next to the column it protects; a future Lua caller cannot bypass it; a future C++ binding writing direct SQL also cannot bypass it. Defense-in-depth survives crashes-mid-transaction (Clarification Q3): if WAL rollback ever fails to restore a half-updated row, the trigger catches it on next write. |
| (b) Lua-layer guard (a `Sequence.set_fps` function that asserts caller identity) | Lua model layer. | Easier to write, no SQL-trigger learning curve. BUT: caller-identity asserts are notoriously brittle (depends on `debug.getinfo`, breaks under module wrapping). Any future code path that touches the row directly via `database.exec` bypasses the guard silently. NOT statically-verifiable. |
| (c) Don't enforce; rely on code review | None. | The contradiction-of-conventions this spec fixes (the very bug we're shipping 018 for) was introduced exactly because a piece of code wrote audio clip source positions in a different convention than the resolver expected, and code review didn't catch it. Same risk class. Rejected. |

### Decision

**(a)**, with the session flag mechanism being a temporary table created at `ConformSequence` entry and dropped at exit. Concrete trigger pattern documented in `data-model.md`.

### Why a temp-table flag rather than `PRAGMA user_version`?

`PRAGMA user_version` is a single integer at the database level; concurrent connections (none today, but a robustness consideration) would race. A `CREATE TEMP TABLE _conform_sequence_in_progress (...)` is per-connection and per-session. The trigger inspects `EXISTS (SELECT 1 FROM temp.sqlite_master WHERE name = '_conform_sequence_in_progress')`. Clean, atomic with the transaction, no races.

### Coverage

The same pattern covers FR-031 (sequences.fps_num/den) and is the model for FR-028's enforcement of `projects.settings.master_clock_hz` (writeable only inside `SetProjectMasterClock`).

---

## R3. Project default fps initial value

### Question

What value should `projects.settings.default_fps` carry for a brand-new project?

### Alternatives considered

- **24/1 (CHOSEN)**: cinema-standard, integer rate, exact representation, easy to reason about in tests. Joe's stated preference: "Probably 24. The user is free to change it but not forced to come up with a number."
- 23.976 (24000/1001): the most common professional NTSC rate, but a non-integer ratio that makes example arithmetic harder to follow in tests and documentation.
- 30/1: more common in broadcast / web video, but Joe's stated preference settled this.
- "Force user to pick at New Project dialog": rejected — friction for users who don't know or care, and 018 explicitly excludes UI work.

### Decision

**24/1**, hard-coded as the initialization value for `projects.settings.default_fps` in the New Project path. User changes via `SetProjectDefaultFps` (FR-030a) — settings-only, no cascade.

---

## R4. `ConformSequence` performance target

### Question

Is `ConformSequence` fast enough on realistic projects to run synchronously without progress UI (per Clarification Q1 — no UI in 018)?

### Investigation

Worst plausible 018-era project: 10,000 clips spread across a handful of sequences, each clip potentially needing four-column UPDATE (`source_in_frame, source_in_subframe, source_out_frame, source_out_subframe`). Plus media_ref UPDATE inside the conformed master.

Estimate, single transaction on local SQLite WAL on a modern SSD:
- 10,000 row UPDATEs ≈ 200–400 ms typical.
- Transaction commit (single fsync) ≈ 5–20 ms.
- Total: comfortably <500 ms p95.

### Decision

Target **<500 ms p95 for a 10k-clip project**. No progress UI in 018 scope. If a real project ever exceeds the target by a factor that makes the UI feel frozen, the followup is to add a busy indicator, not to fragment the transaction (the atomicity guarantee — FR-029 — is load-bearing).

### Test posture

`test_conform_sequence.lua` (FR-035) measures wall-clock for a 1000-clip case as a fast smoke; a separate optional `test_conform_sequence_perf.lua` runs the 10k case but is excluded from the default test loop to keep `make -j4` fast.

---

## R5. Schema-version-bump open-error path

### Question

When a user opens an old `.jvp` file (schema_version < 11) under Clarification Q2's hard-error policy, where does the error message reach the user?

### Investigation

`Project.open` already calls a schema-version check today (the bump from V12 → V13 in 013 exercised this path). The path:

1. `Project.open(path)` opens the SQLite connection.
2. Reads the `schema_version` row (single-row table).
3. If mismatch → currently asserts. Per Constitution VI (fail-fast asserts include actionable messages with context), the assert message names old + new version.
4. The assert surfaces through the QWidget error-dialog facility that the app's top-level exception handler already wires to.

No new UI work needed; the existing path already handles this case. 018's contribution is just to update the assert message to mention "re-import from original source (DRP/FCP7 XML)" so the user has a clear next step (rather than the generic "schema mismatch" text).

### Decision

Modify `database.lua` schema-version check to use a 018-specific assert message:

```
Schema version mismatch: this project file uses schema vN, this build expects vN+1.
The 018 sub-frame primitives feature changed how audio clip source positions
are stored; old projects cannot be opened. Re-import from the original source
(DRP / FCP7 XML / etc.) to produce a fresh .jvp file.
```

Documented in `data-model.md` § "Schema version bump" and verified by `test_schema_version_bump_hard_error.lua`.

### Rejected: in-place migration writer

Considered: a one-time conversion that reads old `clip.source_in_frame` (in samples for audio) and writes new `(frame, subframe)` pairs. Rejected because:

- The old data is *incoherent* per Joe's analysis — the importers wrote one convention, the edit commands another. There is no single rule the migration can apply that produces correct output for every clip; some clips' positions are already wrong-by-convention in the old file.
- Per MEMORY `feedback_schema_bump_freely`: Joe regenerates project DBs freely. The product is in active development; no end-user files are at risk.
- The re-import path from the original DRP / XML is itself the only authoritative migration: it re-derives the position from sample-precise source data using the new (correct) convention.

---

## Cross-cutting decisions echoed from the spec

For convenience, the following decisions are recorded in `spec.md`'s Clarifications section and not re-derived here:

- No UI in 018 (Clarification Q1).
- Hard error open for old `.jvp` (Q2).
- Silent SQLite WAL rollback on crash mid-conform (Q3).
- Round-half-away-from-zero rounding (Q4) — matches existing `round_int` in `models/sequence.lua:1995`.

---

*Phase 0 research complete. Proceed to Phase 1 design (`data-model.md`, `contracts/`, `quickstart.md`).*
