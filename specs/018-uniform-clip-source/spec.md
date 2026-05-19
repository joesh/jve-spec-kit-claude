# Feature Specification: Uniform Clip Source Timebase with Canonical-Clock Sub-Frame Primitives

**Feature Branch**: `018-uniform-clip-source`
**Created**: 2026-05-17
**Status**: Implemented (with deviations — see below)

---

## ⚠️ Implementation Deviations from the Draft

Mid-implementation decisions that differ from the draft Input/FRs. Authoritative — the FR text below is preserved for traceability but should be read through this lens.

1. **Master clock = canonical flicks (705,600,000 Hz), not user-mutable.** The draft proposed `master_clock_hz` as a per-project integer settable at creation (default 192000) and mutable via `SetProjectMasterClock`. As implemented, every project uses `master_clock_hz = 705600000` (the flicks unit; divides 24/25/30/48/50/60/100/120 fps AND 8/16/22.05/24/32/44.1/48/88.2/96/192 kHz audio exactly). The value lives in `projects.settings` as a constant for the math primitive's API symmetry, but is **not user-settable** at creation or after. INV-6 still locks the column down (no direct UPDATE). The `SetProjectMasterClock` command and its test (T041/T044) were **not built**; their contract file is retained as informational. Canonical value pinned by `tests/test_master_clock_canonical_flicks.lua`.
2. **Affected FRs**: FR-027 (default value), FR-028 (mutability), FR-030b (command existence), FR-036b (command test) are superseded. INV-6, FR-008 math, FR-021 resolver semantics, FR-024 invariant rejection of direct settings edits — all retained as written.
3. **T012 static-scan chokepoint test dropped.** Field-access discipline is enforced by deletion of the legacy accessors (compile-fail on direct field use), not by a static scan. See tasks.md notes.
4. **Resolver audio entries carry `audio_sample_rate`; TMB feeder dispatches on `media_kind`.** Discovered while writing the T054 smoke: the playback engine's resolver→TMB converter (`PlaybackEngine:_build_tmb_clip`) was passing the media's *video* fps as the TMB clip rate even for AUDIO entries, while `source_in` on an audio chain leaf is in file-natural samples (FR-008). TMB computes `source_origin_us = FrameTime::from_frame(source_in - first_sample_tc, rate)` — when `rate` is video fps but `source_in` is samples, the decoder seeks thousands of seconds past EOF and returns nothing (the F10 silent-audio symptom 018 was written to fix, made visible by the clip-row unit change). Architectural fix: `Sequence.resolve_master_leaf`'s audio-channel entries now carry `audio_sample_rate` (denormalized from `media_refs.audio_sample_rate`, FR-004/INV-8); `_build_tmb_clip` passes `(rate_num, rate_den) = (audio_sample_rate, 1)` for AUDIO entries, video fps for VIDEO. Pinned by `tests/integration/test_018_t054_overwrite_audio_audible_smoke.lua` — drives Overwrite → resolver → `_build_tmb_clip` → real TMB decode and asserts audible PCM. No new FR; this is the actual delivery of FR-025.

---
**Input**: User description: "Uniform clip source timebase with canonical-clock sub-frame primitives. Standardize `clip.source_in_frame` / `source_out_frame` on the source sequence's frame-rate timebase for both video and audio; add `source_in_subframe` / `source_out_subframe` integer columns for sub-frame residual expressed in a project-wide canonical audio clock. Drop `master.audio_sample_rate` (each audio media_ref carries its own rate). A project carries a default frame rate (set at project creation, pre-fills new-sequence/new-master creation, does NOT constrain existing rows) and a canonical audio master clock (default 192000 Hz). Any sequence's `fps` is only mutable via `ConformSequence` post-creation; that command performs a per-sequence rewrite of all dependents (works for both `kind='master'` and `kind='sequence'`). The `SetProjectMasterClock` command performs a project-wide subframe rescale. Primitives, these commands, and tests only — no UI for the default fps / master clock pickers, no other new user tools."

---

## ⚡ Quick Guidelines
- ✅ Focus on WHAT users need and WHY
- ❌ Avoid HOW to implement (no tech stack, APIs, code structure)
- 👥 Written for business stakeholders, not developers

---

## Clarifications

### Session 2026-05-18
- Q: Does 018 ship UI for `ConformSequence`, or only the underlying command + tests? → A: Command only, no UI in 018. Menu entry + dialog deferred to a later UX-focused spec.
- Q: When opening an old `.jvp` written under a pre-018 schema, what should the user experience be? → A: Hard error dialog, project not opened. No partial open, no migration prompt.
- Q: If the process crashes mid-`ConformSequence` / mid-`SetProjectMasterClock` (SQLite WAL rolls back), what should the next open surface? → A: Silent rollback, no UI. DB rolls back transparently to pre-conform state; no banner, no marker, no recovery prompt. User re-issues the conform if still wanted.
- Q: At a half-integer boundary, which rounding rule applies to `file_sample_offset = round(subframe * file_sample_rate / master_clock_hz)` (FR-008)? → A: Round half away from zero (`floor(x + 0.5)` for non-negative values). Matches the existing `round_int` helper in `models/sequence.lua` and the convention used by the resolver. Subframes are always non-negative per FR-002, so no sign-handling branch is needed.

---

## Domain Model (terminology, for future readers)

The remainder of this spec uses these terms precisely. Several of them changed meaning in V13 (013-timeline-placements-as) and earlier specs use older words — flagged below so future readers don't get confused.

- **Sequence** — a top-level container. The `sequences` table stores all of them; the structural distinction is the `kind` column.
- **Sequence kinds** — the schema allows exactly **two** values: `'master'` and `'sequence'`. (Historically the second was `'nested'`; renamed mid-013 and the codebase is consistent on the new value.)
- **Master sequence** (`kind='master'`) — contains **media_refs only**. A master represents one continuous capture and MAY hold media_refs pointing at **multiple files at heterogeneous rates** (a synced-sound master can carry a 48 kHz camera-audio media_ref alongside a 96 kHz field-recorder media_ref alongside a 23.976 fps video media_ref — each media_ref carries its own native rates). Carries `fps_numerator` / `fps_denominator` (the master's frame rate) but **does not** carry an audio sample rate; audio rate is per-media_ref.
- **Regular sequence** (`kind='sequence'`) — what users think of as "a sequence" or "the timeline". Contains **clips**, never media_refs. Each clip has `sequence_id` pointing at another sequence — master OR another regular. This is how nesting works.
- **Loading into the source viewer** — only sequences load (never a raw file); **both `kind='master'` and `kind='sequence'` are valid**. The user can also bypass the source viewer entirely and select a sequence directly in the project browser — when the browser is the active panel and its selection is an insertable sequence (kind is master or sequence), that selection IS the source for Insert / Overwrite / etc. (See 015 §F2 precedence rule for the active-panel arbitration.) The two paths are equivalent inputs into the same effective-source resolver; neither is privileged over the other at the data-model layer.
- **Source sequence** — the sequence a clip's `sequence_id` points at; the place this clip's content is sourced from. Either `kind='master'` or `kind='sequence'`; the clip layer treats both uniformly. The clip's `source_*_frame` coordinates are expressed in the source sequence's fps timebase, not the containing sequence's. Whether the source is a master or a regular sequence only matters at resolution time, inside the resolver (a master leaf iterates media_refs; a regular sequence iterates inner clips and recurses) — not at the clip layer.
- **Sequence `fps`** — every sequence row (both `kind='master'` and `kind='sequence'`) carries `(fps_numerator, fps_denominator)`. Used by the resolver and by anything that interprets `sequence_start_frame` / `duration_frames` on rows inside the sequence, and by clips that point AT the sequence (their `source_*_frame` is in this sequence's frame units). For `kind='master'` it is the `master.fps` value previously referenced by `Sequence.resolve_master_leaf`. Per-sequence fps is independent — two regular sequences in the same project may run at different rates (e.g. main edit at 23.976, vertical cut at 30), and a master's fps is independent of any sequence that nests it. (Note: `sequence_start_frame` is the post-018-precursor name for the column the code currently calls `timeline_start_frame`. The precursor rename commit lands ahead of 018's behavioral work.)
- **Sequence `fps` is only mutable via `ConformSequence`** — once a sequence row exists, its `fps_numerator` / `fps_denominator` cannot be changed by any code path other than `ConformSequence` (FR-029), which couples every change to an atomic rewrite of all dependent rows. Adding a media_ref or clip never bends the containing sequence's fps. This guarantees order-independence: two masters with the same final set of media_refs resolve identically regardless of import order.
- **`fps_mismatch_policy`** — when a media_ref's native rate differs from its containing master's fps, OR a clip's source sequence's fps differs from its containing sequence's fps, the existing per-project / per-sequence / per-clip `fps_mismatch_policy` (`'resample' | 'passthrough'`) determines decode/playback behavior. fps does not bend to accommodate the new arrival; the mismatch is a first-class, policy-driven decode concern.
- **Project default frame rate** — `(fps_numerator, fps_denominator)` stored in `projects.settings`. Set at project creation; the user picks it explicitly (no system default-of-defaults). **Pre-fills** new-sequence / new-master creation as a convenience — it does NOT constrain existing rows and does NOT cascade to existing sequences when changed. A user freely changes it via `SetProjectDefaultFps` (FR-030a); the change affects only future creations. To actually rewrite an existing sequence's fps, the user invokes `ConformSequence` on that sequence specifically.
- **Project audio master clock (`master_clock_hz`)** — `INTEGER` stored in `projects.settings`. Defaults to `192000` at project creation. This is the canonical rate in which **clip-level sub-frame** values are expressed (see "Canonical sub-frame" below). It is independent of any media_ref's native sample rate.
- **Canonical sub-frame** — every clip stores `(source_in_frame, source_in_subframe)` and `(source_out_frame, source_out_subframe)` where the sub-frame is an integer count of ticks at the project audio master clock, taken inside one frame of the source sequence's fps. Valid range: `0 ≤ subframe < master_clock_hz * source_seq.fps_den / source_seq.fps_num`. At decode time the resolver converts the sub-frame from master-clock ticks to file-natural samples using the audio media_ref's native rate: `file_sample = round(subframe * media_ref.audio_sample_rate / master_clock_hz)`. Round-trip is exact for any file rate that divides `master_clock_hz` (e.g. 48 000, 96 000, 192 000 with the default); for other rates (e.g. 44 100) the conversion introduces sub-microsecond error — acceptable for editing, far below human-perceptible drift.

---

## User Scenarios & Testing *(mandatory)*

### Primary User Story

A user loads a sequence (of either kind — master or regular) into the source viewer, sets marks around a range, and presses Overwrite. A clip lands on a regular record sequence. The user switches to the record sequence, moves the playhead to the start of the new clip and presses play.

The expected outcome: the user sees and hears the inserted media. They also see the waveform in the clip body.

The actual outcome today: empty waveform, silence. Both failures share one root cause — clip source positions for audio are stored in one convention by importers and a different convention by edit commands like Overwrite, and neither convention is universal across the codebase. The fix is to settle on a single convention for the source-position column and add a separate sub-frame residual column for sample-precise audio positioning, expressed in a project-wide canonical clock independent of any file's native rate.

The specific source conditions under which this bug manifests today (non-zero file timecode origin, synced-sound masters with multi-file audio at heterogeneous sample rates, audio-only masters whose frame rate equals the sample rate) are captured in Acceptance Scenarios and Edge Cases below.

### Acceptance Scenarios
1. **Given** a mixed video+audio master (e.g. a camera `.mov` with a timecode origin like `15:49:39:08`) loaded into the source viewer with marks set, **When** the user overwrites the marked range onto a regular record sequence and parks the playhead inside the inserted clip, **Then** the resolver returns the TC-corresponding non-silent audio entry at every frame in the clip's range, AND the peak-cache query for the clip's source range returns the same non-empty peak data the resolver's decode would yield.
2. **Given** a synced-sound master holding a 48 kHz camera-audio media_ref AND a 96 kHz field-recorder media_ref AND a 23.976 fps video media_ref, **When** a clip referencing that master is placed and played, **Then** every audio media_ref whose containing track is enabled (in both the master and the placed clip) decodes at its native sample rate AND the video media_ref decodes under the master's `fps_mismatch_policy`, all sharing the master's single fps timebase. Audio media_refs on disabled tracks are silent.
3. **Given** two masters that ultimately contain identical media_refs but were assembled in different orders (e.g. master A: video first then audio; master B: audio first then video), **When** any clip references either master at the same range, **Then** the resolver produces bit-identical output for both. Order-independence is a hard invariant.
4. **Given** a camera-original audio source whose start does not land exactly on a video-frame boundary (e.g. a BWF file with a fractional-frame timecode offset), **When** a clip referencing that source is placed and played, **Then** the sample position presented to the decoder is exact for any file rate that divides the project audio master clock, and within sub-microsecond accuracy for non-divisor rates.
5. **Given** an existing audio clip with a non-zero sub-frame, **When** any standard edit operation (insert, overwrite, slip, roll, trim, split, ripple) is applied to it, **Then** the sub-frame value survives end-to-end — the operation never silently zeros it.
7. **Given** a project with several sequences (masters and regulars) and many clips, **When** the user invokes `ConformSequence` on one sequence to change its `fps`, **Then** every row whose units depend on that sequence's fps is rewritten so playback at any timeline position resolves to the same wall-clock instant as before the conform; the operation is atomic and undoable. For `kind='master'` the rewritten rows are this master's internal media_refs plus every clip pointing at this master. For `kind='sequence'` the rewritten rows are clips contained in this sequence (their `sequence_start_frame` / `duration_frames`) plus every outer clip pointing at this sequence (their `source_*_frame`).
8. **Given** a project with default frame rate X, **When** the user invokes `SetProjectDefaultFps` to change the default to Y, **Then** `projects.settings` is updated AND every existing sequence (master or regular) remains untouched AND the next newly-created sequence pre-fills its fps from Y. No cascade.
9. **Given** a project with `master_clock_hz` of M and many clips with non-zero subframes, **When** the user invokes `SetProjectMasterClock` to change the clock to M', **Then** every clip's `source_*_subframe` is rewritten by `new = round(old * M' / M)` AND `projects.settings.master_clock_hz` is updated, under one atomic, undoable transaction. Existing sequence fps values are untouched (subframe rescale is orthogonal to fps).

### Edge Cases
- What happens when an importer encounters audio source content whose start does not align to a video-frame boundary? The importer MUST translate the sample-precise start position into the unified `(frame, sub-frame)` pair where sub-frame is in project audio master clock ticks; the sub-frame MUST be strictly less than the ticks-per-master-frame derived value.
- What happens when any writer attempts to set a sub-frame value greater than or equal to the ticks-per-frame bound for the relevant master? The system MUST refuse the write with a loud, actionable failure (invariant violation; never a silent fallback or modulo wrap).
- What happens when a master already has audio media_refs and the user adds a video media_ref at a different native frame rate than the master's fps? The master's `fps` does NOT change. The new media_ref's mismatch is handled by the existing `fps_mismatch_policy`. To force the master's fps to follow the new media, the user runs `ConformSequence` on that master. **Why this doesn't break Acceptance Scenario 3 (order-independence):** master.fps at master creation comes from the project default frame rate (FR-026 / FR-032), NEVER from the first-imported media file's native rate. So in the order-independence scenario, both master A (video first) and master B (audio first) are born with `fps = project_default`, and neither's fps changes as more media gets added. Without that creation rule, order-independence would indeed break — auto-deriving fps from "the first arrival" would make A and B diverge.
- What happens when a master already has a 48 kHz audio media_ref and the user adds a 96 kHz audio media_ref? Both coexist in the master. Each decodes at its native rate. Sub-frame values on clips referencing this master remain in master-clock ticks; per-media_ref conversion happens at decode time.
- What happens when an existing project file is opened whose audio clips were written under the legacy sample-only convention OR whose masters carried a `master.audio_sample_rate` field? Per project convention (MEMORY: `feedback_schema_bump_freely`), old data with sample-encoded audio clip source positions or with a master-level audio rate becomes invalid and must be re-imported. There is no in-place migration shim. The schema version bump triggers a **hard error dialog at open time** — modal, project not opened, message names the old schema version and instructs the user to re-import from the original source (DRP / FCP7 XML / etc.). No partial open, no migration prompt, no read-only mode. Implementation: `Project.open` asserts on schema version mismatch and surfaces the result through the existing error dialog facility — no silent fail-and-continue path.
- What happens if a user attempts a sample-precise edit through today's tools (slip by one sample, trim to a zero-crossing)? Out of scope. The primitives support such an operation, but the user-facing tools do not yet offer sub-frame granularity. Today's tools remain frame-aligned and MUST default any new sub-frame value to zero.

## Requirements *(mandatory)*

### Functional Requirements

#### Project-level settings (new)

- **FR-026**: A project MUST carry a default frame rate `(fps_numerator, fps_denominator)` stored in `projects.settings` JSON. New projects are initialized with this set to **`24/1`** — the user is free to change the value at project creation (via the New Project dialog) or mid-project (via `SetProjectDefaultFps`, FR-030a), but is never forced to come up with a number to create a project.
- **FR-027**: A project MUST carry an integer `master_clock_hz` in `projects.settings`. Default at creation is `192000`. The user MAY choose a different value at creation but it MUST be a positive integer.
- **FR-028**: `projects.settings.default_fps` MAY be changed mid-project freely via `SetProjectDefaultFps` (FR-030a) — the change does not cascade to existing rows. `projects.settings.master_clock_hz` MAY be changed mid-project only via `SetProjectMasterClock` (FR-030b), which rewrites every clip's subframe atomically. Direct edits to `projects.settings` that bypass these two commands are an invariant violation.

#### Sequence timebase (revised)

- **FR-001**: Every clip stores `source_in_frame` and `source_out_frame` — integer frame positions in the source sequence's fps timebase. Audio clips additionally store `source_in_subframe` and `source_out_subframe` — integer counts of project audio master clock ticks within the corresponding frame. Video clips do NOT have subframe fields; the columns are NULL on video clip rows. "Source sequence" means the sequence the clip's `sequence_id` points at, of either `kind`. The subframe-existence invariant is enforced at the schema layer (CHECK + trigger): video clips MUST have NULL subframe columns; audio clips MUST have non-NULL subframe columns. The principle: a field that doesn't exist on a video clip cannot be misused.
- **FR-002**: The system MUST enforce that any audio clip's sub-frame value satisfies `0 ≤ subframe < master_clock_hz * source_seq.fps_denominator / source_seq.fps_numerator`. Violations MUST cause an immediate, actionable failure.
- **FR-003**: (Subsumed by FR-001 — video clips have no subframe columns to constrain.)
- **FR-004**: The system MUST drop `sequences.audio_sample_rate` from the `kind='master'` schema. Audio sample rate is carried per-media_ref (`media_refs.audio_sample_rate`, populated from the underlying media file). A single master MAY contain audio media_refs at heterogeneous sample rates.
- **FR-005**: The system MUST persist sub-frame values across project save and load with no precision loss.
- **FR-031**: `sequences.fps_numerator` and `sequences.fps_denominator` MUST be mutable post-creation only via `ConformSequence` (FR-029), for sequences of BOTH kinds. A SQLite trigger MUST refuse any direct `UPDATE` to these columns unless `ConformSequence` has set the session flag the trigger checks.
- **FR-032**: At sequence creation (either kind), `fps_numerator` / `fps_denominator` MAY be initialized either from the project default (the common case, pre-filled by UI / importers) or to an explicit user choice that overrides the default at creation time. Importers and edit commands MAY NOT mutate the fps of an existing sequence — they invoke `ConformSequence` if a change is required.

#### Math primitive

- **FR-006**: The system MUST provide a canonical sub-frame math primitive that packs and unpacks a `(frame, sub-frame)` pair against a master's ticks-per-frame value, normalizes any tick-arithmetic into a canonical `(frame, sub-frame)` representation, converts file-natural sample positions to-and-from sub-frame ticks given a file's native sample rate, and is the single source of truth used by every reader and writer of clip source positions.
- **FR-007**: The math primitive MUST fail loudly on invalid inputs (negative frame, negative sub-frame, sub-frame out of range, non-integer values, non-positive `master_clock_hz`, non-positive source-sequence fps, non-positive file sample rate) — never silently clamp, round, or default.

#### Resolution

- **FR-008**: When resolving a clip's source position to a file-natural sample position for decode, the system MUST include the clip's sub-frame value as an additive offset converted from master-clock ticks to file-rate samples via `file_sample_offset = round(subframe * media_ref.audio_sample_rate / project.master_clock_hz)`. A clip whose sub-frame is `N` ticks results in a decode request offset by `round(N * media_ref.audio_sample_rate / master_clock_hz)` samples relative to a clip whose sub-frame is zero. Round-trip MUST be exact when the file rate divides `master_clock_hz`. The `round()` operation MUST use round-half-away-from-zero (`floor(x + 0.5)` for non-negative inputs — subframes are non-negative per FR-002, so no sign-handling branch is needed). This rule matches the existing `round_int` helper in `models/sequence.lua` used by the resolver; same rounding everywhere prevents off-by-one mismatches between the subframe path and the existing master-leaf resolver.

#### Importers

- **FR-009**: Every importer that writes audio clip source positions MUST translate sample-precise source values into the unified `(frame, sub-frame)` representation via the canonical math primitive before persisting. No importer may write a sample-only or otherwise out-of-convention value.
- **FR-009a**: All importers, edit commands, the resolver, and every other reader/writer of clip source positions MUST go through a shared `clip_position` accessor module that exposes the canonical read/write API — e.g. `read_audio_source(clip) → (frame_in, subframe_in, frame_out, subframe_out)`, `write_audio_source(clip, frame_in, subframe_in, frame_out, subframe_out)`, `read_video_source(clip) → (frame_in, frame_out)`, `write_video_source(clip, frame_in, frame_out)`, plus the sample↔(frame, subframe) conversion helpers from FR-006. Direct field access on clip rows (`clip.source_in_frame = ...`) is forbidden outside this module. This keeps every consumer DRY, makes the schema-level video-vs-audio distinction (FR-001) impossible to violate at the call site, and gives the trigger/CHECK enforcement (FR-001, FR-002, FR-024) a single chokepoint to audit.
- **FR-010**: The DRP importer MUST adopt the unified convention as part of this feature, including the creation-time fps initialization rule (FR-032).
- **FR-011**: The FCP7 XML importer MUST be verified to adopt the unified convention as part of this feature; if it already writes frame-aligned values, no behavior change is required beyond ensuring the sub-frame defaults to zero and the master fps initialization comes from the project default (FR-032).
- **FR-012**: The prproj importer is OUT OF SCOPE for this feature. A persistent TODO entry MUST be recorded so it is fixed in a follow-up. Until then, the prproj path is allowed to remain inconsistent with the unified convention.

#### Edit commands

- **FR-013**: Every edit command that creates new audio clips (Insert, Overwrite) MUST set the new clips' sub-frame values to zero (the marks UX is frame-aligned today). Video clip creation never touches subframe (the columns are NULL by schema — FR-001).
- **FR-014**: Every edit command that mutates existing clips' source positions (Slip, Roll, Trim, Split, Ripple, etc.) MUST preserve any pre-existing sub-frame value through its math. Sub-frame values MUST NOT be silently zeroed by routing through frame-only intermediate forms.
- **FR-015**: Every undo and redo path that touches clip source positions MUST round-trip sub-frame values exactly.

#### Conform / settings commands (new in 018)

- **FR-029** (`ConformSequence`): The system MUST provide a `ConformSequence` command that takes a sequence id (of either kind) and a new `(fps_numerator, fps_denominator)`. 018 ships the command at the data-model + command-dispatcher layer only — no menu entry, no dialog, no button. Invokable from scripts and tests; a user-facing UX surface is deferred to a follow-up spec. Under one atomic transaction, the command:
  - Rewrites the sequence's `fps_numerator` / `fps_denominator` (the only legal path to change these — FR-031).
  - For `kind='master'`: rewrites every media_ref inside this master so its `sequence_start_frame` and `duration_frames` (in master-frames) represent the same wall-clock content under the new fps. The media_ref's `source_in` (file-natural samples) is unchanged. (Note: `sequence_start_frame` is the post-018-precursor name for what the code currently calls `timeline_start_frame`; see the precursor commit that lands the rename ahead of this spec's implementation.)
  - For either kind: rewrites every clip in the project whose `sequence_id` points at this sequence, converting `(source_in_frame, source_in_subframe)` and `(source_out_frame, source_out_subframe)` so the same wall-clock content is referenced under the new fps. Subframe values are unchanged by an fps-only conform (they're in master-clock ticks, fps-independent); only frame components rescale; video clips have no subframe to touch (FR-001).
  - For `kind='sequence'`: also rewrites every clip CONTAINED in this sequence — their `sequence_start_frame` and `duration_frames` (in this sequence's frames) so the same wall-clock placement is preserved under the new fps.
  - Is fully undoable as a single command; redo restores the new state.
  - On any per-row failure within the transaction, the entire transaction rolls back; the sequence is left in its pre-conform state.
  - On process crash mid-transaction: SQLite WAL rolls back to pre-conform state on next open. No banner, no recovery marker, no prompt — the user simply sees the project as it was before they initiated the conform. (Defense-in-depth: if WAL rollback fails to fully restore, the FR-001 / FR-002 / FR-031 invariant triggers catch any resulting inconsistency at the first touched row — silent corruption cannot persist beyond the next operation.)
- **FR-030a** (`SetProjectDefaultFps`): The system MUST provide a `SetProjectDefaultFps` command that takes a new `(fps_numerator, fps_denominator)` and writes it to `projects.settings`. The command MUST NOT touch any existing sequence, media_ref, or clip — its effect is limited to pre-filling future creations. Undoable.
- **FR-030b** (`SetProjectMasterClock`): The system MUST provide a `SetProjectMasterClock` command that takes a new integer `master_clock_hz` and, under one atomic transaction:
  - Rewrites `projects.settings.master_clock_hz`.
  - Rewrites every clip's `source_in_subframe` and `source_out_subframe` by `new = round(old * new_clock / old_clock)`.
  - Does NOT touch sequence fps values (clock and fps are independent dimensions).
  - Is fully undoable as a single command.
  - On any per-row failure within the transaction, the entire transaction rolls back.
  - On process crash mid-transaction: SQLite WAL rolls back to pre-clock-change state on next open. No banner, no recovery marker, no prompt — same crash-recovery semantics as `ConformSequence`. Defense-in-depth: FR-002 subframe-bound invariant catches any post-rollback subframe value left outside `[0, ticks_per_frame)` at first touched row.

#### Legacy accessor removal

- **FR-016**: The legacy per-medium dual-unit accessors that returned sample values for audio (the `get_effective_audio_in` / `get_effective_audio_out` accessors and the video-frame-to-audio-sample utility) MUST be removed.
- **FR-017**: Every consumer of those accessors (the mark-resolution helper used during command-context gathering, and any others identified during implementation) MUST be migrated to the unified `(frame, sub-frame)` form before the accessors are removed.

#### Documentation alignment

- **FR-018**: The data-model documentation MUST be updated so that the unified convention is the explicit, single source of truth for clip source coordinates. Any prior wording that endorsed or tolerated a per-medium dual-unit convention, an order-dependent sequence fps, a master-level `audio_sample_rate`, the "audio-only master uses `fps = sample_rate`" hack, or mutation of any sequence's fps outside `ConformSequence` MUST be removed or revised.
- **FR-018a** (incidental cleanup, not a primary deliverable): The schema's stale `INV-2` trigger error string ("kind=nested sequence") SHOULD be corrected to "kind='sequence'" to match the actual CHECK constraint and reduce confusion for readers.

#### Test coverage

- **FR-019**: The canonical sub-frame math primitive MUST have full unit-test coverage, including: pack and unpack round-trips at a representative selection of `(master_clock_hz, source_seq.fps_num, source_seq.fps_den, file_sample_rate)` combinations; tick arithmetic that crosses frame boundaries (sub-frame wrap forward and backward); the file-rate-divides-clock case (exact round-trip); the non-divisor file-rate case (round-trip within sub-microsecond bound); and rejection of every form of invalid input enumerated in FR-007.
- **FR-020**: A schema round-trip test MUST verify that a clip persisted with a non-zero sub-frame survives save and reload exactly (FR-005).
- **FR-021**: A resolver test MUST verify that a clip with sub-frame `N` ticks against a file at rate `R` produces a decode-position offset of exactly `round(N * R / master_clock_hz)` samples versus an otherwise-identical clip with sub-frame zero (FR-008). The test MUST cover both a divisor file rate (exact round-trip) and a non-divisor file rate (bounded error).
- **FR-022**: An importer test MUST verify that a known sample-precise input to the DRP importer produces a stored `(frame, sub-frame)` pair that round-trips through the math primitive to within one project-clock tick of the original sample value (FR-009, FR-010).
- **FR-023**: An edit-command preservation test MUST verify that for at least one representative mutating edit operation (slip, roll, or split), a pre-existing non-zero sub-frame value survives the operation, undo, and redo unchanged (FR-014, FR-015).
- **FR-024**: Invariant-violation tests MUST verify that the system rejects each of: a video clip with any non-NULL subframe column (FR-001); an audio clip with a NULL subframe column (FR-001); an audio clip's sub-frame value outside `[0, ticks_per_frame)` (FR-002); a direct `UPDATE` to `sequences.fps_num/den` (either kind) outside `ConformSequence` (FR-031); a mutation of any sequence's fps by an importer or edit command outside `ConformSequence` (FR-032); writing `sequences.audio_sample_rate` on any row (FR-004 — the column must not exist); a direct edit to `projects.settings.master_clock_hz` outside `SetProjectMasterClock` (FR-028).
- **FR-025**: An end-to-end acceptance test MUST verify that overwriting a range from a mixed-media master with a non-zero camera timecode onto a regular record sequence produces (a) an audible audio entry from the resolver AND (b) a waveform render against the same sample range AND (c) **the decoded audio samples returned by the resolver are bit-identical to a direct read of the source file at the corresponding sample offset and length** — at any frame inside the new clip (the Primary User Story).
- **FR-033**: An order-independence test MUST construct two masters by adding the same media_refs in different orders, and verify that the resolver produces bit-identical output for any clip referencing either master at the same range (Acceptance Scenario 3).
- **FR-034**: A multi-rate-audio test MUST construct a master holding two audio media_refs at different sample rates (e.g. 48 kHz and 96 kHz) plus one video media_ref, and verify that a clip referencing that master plays both audio streams correctly under the resolver (Acceptance Scenario 2).
- **FR-035**: A `ConformSequence` test MUST verify FR-029 for both sequence kinds: (a) `kind='master'` — pre-/post-conform wall-clock equivalence for every media_ref inside this master and every clip pointing at it; (b) `kind='sequence'` — pre-/post-conform wall-clock equivalence for every clip contained in this sequence (`sequence_start_frame` / `duration_frames` rescaled) and every outer clip pointing at this sequence (`source_*_frame` rescaled); both cases include full undo/redo round-trip and atomic rollback on injected per-row failure.
- **FR-036a**: A `SetProjectDefaultFps` test MUST verify FR-030a: `projects.settings.default_fps` changes, no existing sequence/media_ref/clip is touched, and a newly-created sequence after the change pre-fills from the new default; undo restores prior default.
- **FR-036b**: A `SetProjectMasterClock` test MUST verify FR-030b: `projects.settings.master_clock_hz` changes; every clip's `source_*_subframe` is rewritten by `round(old * new_clock / old_clock)`; sequence fps values are untouched; full undo/redo round-trip; atomic rollback on injected failure.

### Key Entities

- **Clip source range**: The pair of positions (in and out) that describe what portion of the source sequence's content is presented on the containing regular sequence. Each position is a pair: a frame component in the source sequence's frame-rate timebase, and a sub-frame component in project audio master clock ticks. Together they encode a sub-frame-precise position without sacrificing the integer-frame invariant that governs every other coordinate in the system.
- **Ticks per sequence frame**: A derived value for any source sequence: `master_clock_hz * source_seq.fps_denominator / source_seq.fps_numerator`. The sub-frame component is always strictly less than this. Replaces the prior "per-frame sample count" concept; no longer ties sub-frame range to any file's sample rate.
- **Project default frame rate**: `(fps_numerator, fps_denominator)` stored in `projects.settings`. Pre-fills new sequence creation (either kind); does NOT constrain existing rows. Changeable freely via `SetProjectDefaultFps` with no cascade.
- **Project audio master clock**: Integer `master_clock_hz` in `projects.settings`, default `192000`. The rate in which every clip's sub-frame is expressed. Decouples clip storage from any file's native sample rate. Changeable only via `SetProjectMasterClock`, which rewrites every clip's subframe atomically.
- **Canonical math primitive**: The single, project-wide module responsible for pack/unpack of `(frame, sub-frame)` against `ticks_per_frame`, conversion to-and-from file-natural samples given a file rate, and bounded arithmetic on sub-frame values. Every writer and reader of clip source positions consults this primitive instead of doing ad-hoc rate math.
- **`ConformSequence`**: The user-initiated, transactional, undoable command that rewrites a single sequence's fps (either kind) plus every dependent media_ref and clip whose units derive from that sequence's fps. The only legal path to mutate `sequences.fps_num/den` post-creation.
- **`SetProjectDefaultFps`** / **`SetProjectMasterClock`**: User-initiated, transactional, undoable commands that mutate `projects.settings`. `SetProjectDefaultFps` is settings-only (no cascade). `SetProjectMasterClock` rewrites every clip's `source_*_subframe` atomically. These are the only legal paths to mutate the respective `projects.settings` fields.

---

## Review & Acceptance Checklist
*GATE: Automated checks run during main() execution*

### Content Quality
- [x] No implementation details (languages, frameworks, APIs) — the spec describes the convention and its observable consequences, not file names, column names, function signatures, or module layout
- [x] Focused on user value and business needs — the user story is "audio plays when expected, regardless of master composition order or heterogeneous file rates"; technical rules exist only to make that user value possible
- [x] Written for non-technical stakeholders — terminology stays at the level of "clip", "audio", "frame", "sample", "import"
- [x] All mandatory sections completed

### Requirement Completeness
- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous — every functional requirement has a concrete observable acceptance criterion enumerated in FR-019 through FR-036
- [x] Success criteria are measurable — audio audibility is binary; sub-frame round-trip is exact for divisor rates and sub-microsecond bounded for non-divisor; order-independence is bit-identical resolver output
- [x] Scope is clearly bounded — excluded items (user-facing sample-precise edit tools, prproj importer, in-place data migration of legacy `.jvp` files) are called out in Edge Cases and FR-012
- [x] Dependencies and assumptions identified — the Helen sub-frame BWF concern lives at the media-ref layer and is not in scope here; the project convention "Joe regenerates the project file" covers the legacy-data question

---

## Execution Status
*Updated by main() during processing*

- [x] User description parsed
- [x] Key concepts extracted
- [x] Ambiguities marked (none remain)
- [x] User scenarios defined
- [x] Requirements generated
- [x] Entities identified
- [x] Review checklist passed

---
