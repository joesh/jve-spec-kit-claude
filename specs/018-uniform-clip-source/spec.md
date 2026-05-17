# Feature Specification: Uniform Clip Source Timebase with Sample-Precise Sub-Frame Primitives

**Feature Branch**: `018-uniform-clip-source`
**Created**: 2026-05-17
**Status**: Draft
**Input**: User description: "Uniform clip source timebase with sample-precise sub-frame primitives. Standardize clip.source_in_frame / source_out_frame on the nested master's master.fps timebase for both video and audio; add source_in_subframe_samples and source_out_subframe_samples integer columns for sample-precise residual; primitives + tests only, no new user tools."

---

## ⚡ Quick Guidelines
- ✅ Focus on WHAT users need and WHY
- ❌ Avoid HOW to implement (no tech stack, APIs, code structure)
- 👥 Written for business stakeholders, not developers

---

## User Scenarios & Testing *(mandatory)*

### Primary User Story
A user loads a camera-original clip (video and audio in one file, with a non-zero camera timecode) into the source viewer, sets marks around a passage of dialogue, and overwrites the marked passage onto the record timeline. When the user parks the playhead inside the new clip and plays, both picture AND sound play — the dialogue is audible. Today the picture plays but the audio is silent: the clip exists on the timeline, the waveform draws, but no sound comes out because the audio half of the placement uses a different coordinate convention than the audio resolver expects.

### Acceptance Scenarios
1. **Given** a mixed video+audio master (e.g., a camera .mov with a timecode origin like 15:49:39:08) loaded into the source viewer with marks set, **When** the user overwrites the marked passage onto a record sequence and parks the playhead inside the inserted clip, **Then** the corresponding audio is audible.
2. **Given** a camera-original audio source whose start does not land exactly on a video-frame boundary (e.g., a BWF file with a fractional-frame timecode offset), **When** a clip referring to that source is placed and played, **Then** the sample position presented to the decoder is exact to the sample — no precision is lost at the clip layer.
3. **Given** any video clip, **When** it is inspected after creation by any importer or edit operation, **Then** its sub-frame field is exactly zero.
4. **Given** an audio-only master whose frame rate equals its audio sample rate, **When** any clip references it, **Then** the clip's sub-frame field is exactly zero (because the timebase already resolves to single samples).
5. **Given** an existing clip with a non-zero sub-frame, **When** any standard edit operation (insert, overwrite, slip, roll, trim, split, ripple) is applied to it, **Then** the sub-frame value survives end-to-end — the operation never silently zeros it.

### Edge Cases
- What happens when an importer encounters audio source content whose start does not align to a video-frame boundary? The importer MUST translate the sample-precise start position into the unified frame value plus a residual sub-frame value; the residual MUST be strictly less than the per-frame sample count.
- What happens when any writer attempts to set a sub-frame value greater than or equal to the per-frame sample count for the relevant master? The system MUST refuse the write with a loud, actionable failure (this is an invariant violation, never a silent fallback or modulo wrap by accident).
- What happens when an existing project file is opened whose audio clips were written under the legacy sample-only convention? Per project convention, old data with sample-encoded audio clip source positions becomes invalid and must be re-imported. There is no in-place migration.
- What happens if a user attempts a sample-precise edit through today's tools (slip by one sample, trim to a zero-crossing)? Out of scope. The primitives support such an operation, but the user-facing tools do not yet offer sample-level granularity. Today's tools remain frame-aligned and MUST default any new sub-frame value to zero.

## Requirements *(mandatory)*

### Functional Requirements

#### Storage and invariants

- **FR-001**: The system MUST store each clip's source range as two pairs of fields: a frame component in the nested master's frame-rate timebase (one field for `in`, one for `out`), AND a sub-frame component measured in audio samples (one field for `in`, one for `out`). The frame components apply to video and audio clips uniformly; the sub-frame components carry sample-precise residual for audio.
- **FR-002**: The system MUST enforce that any clip's sub-frame value is strictly less than the number of audio samples in one frame at the nested master's frame rate (the per-frame sample count is derived from the nested master's audio sample rate and frame rate). Violations MUST cause an immediate, actionable failure.
- **FR-003**: The system MUST enforce that video clips have a sub-frame value of exactly zero.
- **FR-004**: The system MUST enforce that any clip whose nested master has a per-frame sample count of one (the audio-only-at-sample-rate case) has a sub-frame value of exactly zero.
- **FR-005**: The system MUST persist sub-frame values across project save and load with no precision loss.

#### Math primitive

- **FR-006**: The system MUST provide a canonical sample-precise math primitive that packs and unpacks a `(frame, sub-frame)` pair against a per-frame sample count, normalizes any sample arithmetic into a canonical `(frame, sub-frame)` representation, and is the single source of truth used by every reader and writer of clip source positions.
- **FR-007**: The math primitive MUST fail loudly on invalid inputs (negative frame, negative sub-frame, sub-frame out of range, non-integer values, non-positive per-frame sample count) — never silently clamp, round, or default.

#### Resolution

- **FR-008**: When resolving a clip's source position to a file-natural sample position for decode, the system MUST include the clip's sub-frame value as an additive offset on top of the file's natural-sample arithmetic. The contribution of the sub-frame MUST be exact and round-trippable: a clip whose sub-frame is `N` results in a decode request offset by exactly `N` samples relative to a clip whose sub-frame is zero.

#### Importers

- **FR-009**: Every importer that writes audio clip source positions MUST translate sample-precise source values into the unified `(frame, sub-frame)` representation via the canonical math primitive before persisting. No importer may write a sample-only or otherwise out-of-convention value.
- **FR-010**: The DRP importer MUST adopt the unified convention as part of this feature.
- **FR-011**: The FCP7 XML importer MUST be verified to adopt the unified convention as part of this feature; if it already writes frame-aligned values, no behavior change is required beyond ensuring the sub-frame defaults to zero.
- **FR-012**: The prproj importer is OUT OF SCOPE for this feature. A persistent TODO entry MUST be recorded so it is fixed in a follow-up. Until then, the prproj path is allowed to remain inconsistent with the unified convention.

#### Edit commands

- **FR-013**: Every edit command that creates new clips (Insert, Overwrite) MUST set new clips' sub-frame values to zero (the marks UX is frame-aligned today).
- **FR-014**: Every edit command that mutates existing clips' source positions (Slip, Roll, Trim, Split, Ripple, etc.) MUST preserve any pre-existing sub-frame value through its math. Sub-frame values MUST NOT be silently zeroed by routing through frame-only intermediate forms.
- **FR-015**: Every undo and redo path that touches clip source positions MUST round-trip sub-frame values exactly.

#### Legacy accessor removal

- **FR-016**: The legacy per-medium dual-unit accessors that returned sample values for audio (the `get_effective_audio_in` / `get_effective_audio_out` accessors and the video-frame-to-audio-sample utility) MUST be removed.
- **FR-017**: Every consumer of those accessors (the mark-resolution helper used during command-context gathering, and any others identified during implementation) MUST be migrated to the unified `(frame, sub-frame)` form before the accessors are removed.

#### Documentation alignment

- **FR-018**: The data-model documentation MUST be updated so that the unified convention is the explicit, single source of truth for clip source coordinates. Any prior wording that endorsed or tolerated a per-medium dual-unit convention MUST be removed or revised.

#### Test coverage

- **FR-019**: The canonical math primitive MUST have full unit-test coverage, including: pack and unpack round-trips at a representative selection of `(sample-rate, frame-rate)` combinations; sample arithmetic that crosses frame boundaries (sub-frame wrap forward and backward); the audio-only-at-sample-rate degenerate case where the per-frame sample count is one; and rejection of every form of invalid input enumerated in FR-007.
- **FR-020**: A schema round-trip test MUST verify that a clip persisted with a non-zero sub-frame survives save and reload exactly (FR-005).
- **FR-021**: A resolver test MUST verify that a clip with sub-frame `N` produces a decode-position offset of exactly `+N` versus an otherwise-identical clip with sub-frame zero (FR-008).
- **FR-022**: An importer test MUST verify that a known sample-precise input to the DRP importer produces a stored `(frame, sub-frame)` pair that round-trips through the math primitive to the original sample value (FR-009, FR-010).
- **FR-023**: An edit-command preservation test MUST verify that for at least one representative mutating edit operation (slip, roll, or split), a pre-existing non-zero sub-frame value survives the operation, undo, and redo unchanged (FR-014, FR-015).
- **FR-024**: Invariant-violation tests MUST verify that the system rejects each of: a video clip with a non-zero sub-frame (FR-003); a clip on an audio-only-at-sample-rate master with a non-zero sub-frame (FR-004); a sub-frame value greater than or equal to the per-frame sample count (FR-002).
- **FR-025**: An end-to-end acceptance test MUST verify that overwriting a passage from a mixed-media master with a non-zero camera timecode onto a record sequence produces an audible audio entry from the resolver at any frame inside the new clip's range (the Primary User Story).

### Key Entities

- **Clip source range**: The pair of positions (in and out) that describe what portion of a clip's referenced source material is presented on a record sequence. Each position is now a pair: a frame component in the nested master's frame-rate timebase, and a sample-residual component holding any sub-frame remainder for audio. Together they encode a sample-precise position without sacrificing the integer-frame invariant that governs every other coordinate in the system.
- **Per-frame sample count**: A derived property of any nested master sequence — how many audio samples occupy one frame at that master's frame rate and audio sample rate. The sub-frame component is always strictly less than this value. For audio-only masters whose frame rate is the sample rate, this value is one and the sub-frame is therefore always zero.
- **Canonical math primitive**: The single, project-wide module responsible for translating between sample-only quantities (as they appear in media files and decode requests) and the `(frame, sub-frame)` form that clip storage requires. Every writer and reader of clip source positions consults this primitive instead of doing ad-hoc rate math.

---

## Review & Acceptance Checklist
*GATE: Automated checks run during main() execution*

### Content Quality
- [x] No implementation details (languages, frameworks, APIs) — the spec describes the convention and its observable consequences, not file names, column names, function signatures, or module layout
- [x] Focused on user value and business needs — the user story is "audio plays when expected"; the technical rule exists only to make that user value possible
- [x] Written for non-technical stakeholders — terminology stays at the level of "clip", "audio", "frame", "sample", "import"
- [x] All mandatory sections completed

### Requirement Completeness
- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous — every functional requirement has a concrete observable acceptance criterion enumerated in FR-019 through FR-025
- [x] Success criteria are measurable — audio audibility is binary; sub-frame round-trip is exact-equality
- [x] Scope is clearly bounded — excluded items (user-facing sample-precise tools, prproj importer, in-place data migration) are called out in Edge Cases and FR-012
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
