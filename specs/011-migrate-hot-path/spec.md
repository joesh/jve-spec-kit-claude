# Feature Specification: Migrate Hot-Path Lua Subsystems Into C++ (EMP and JVE)

**Feature Branch**: `011-migrate-hot-path`
**Created**: 2026-04-20
**Status**: Draft
**Input**: User description: "Migrate hot-path Lua subsystems into the C++ EMP (editor_media_platform) layer, in a phased order that prioritizes leverage and minimizes coupling risk. Lua remains the orchestrator/UI/command/model layer; EMP gains responsibility for compute-heavy and I/O-heavy primitives."

---

## Quick Summary

Five Lua subsystems perform compute- or I/O-heavy work that belongs in C++. Lua retains orchestration, UI, command, and model responsibilities. Each subsystem migrates as an independent, revertable phase, ordered by leverage and coupling risk: media probing first (lowest risk), Rational time primitive last (highest coupling).

**Two C++ destinations — this distinction is load-bearing:**
- **EMP** (`src/editor_media_platform/`) is a **distributable, editor-agnostic media platform library**. Its contract is "media primitives usable by any NLE." Generic capabilities go here: probe, decode, peaks, Rate/Rational, timecode math.
- **JVE C++** (`src/cpp/`) is the host application's own C++. Editor-specific knowledge (project formats, importer-specific binary schemas, JVE-shaped result tables) goes here. JVE C++ may depend on EMP; EMP must not depend on JVE.

Architectural rules:
1. Lua decides *what* happens; C++ does *how fast* it happens. Anything inside an inner loop belongs in C++.
2. Any C++ code specific to a single editor's formats, commands, or schema belongs in JVE C++, NOT in EMP. EMP stays clean as a distributable.

---

## User Scenarios & Testing *(mandatory)*

### Primary User Story
A user importing a large DaVinci Resolve project (DRP with hundreds to tens of thousands of clips) waits for binary blob decoding to complete. Today this work runs in pure Lua and dominates import cost. After this feature, the same import completes substantially faster because blob decoding runs in compiled C++ inside EMP. The user observes a shorter import dialog duration; the resulting project is identical.

A second user opens a project containing audio media. Today the Lua main thread polls peak-generation status every 500ms during waveform generation, causing visible stalls in unrelated UI work. After this feature, peak generation completion notifies Lua via a signal; the main thread is no longer occupied by polling.

A third user imports a single media file. Today a subprocess (`ffprobe`) is spawned and its JSON output parsed, even though the C++ decoder must read the same headers when the file plays. After this feature, probing reuses the C++ decoder's metadata extraction; no subprocess spawns.

### Acceptance Scenarios

1. **Given** a DRP file containing ≥500 clips with retiming keyframes, **When** the user imports it, **Then** total import time is at least 5× faster on the blob-decoding portion than pre-migration baseline, and the resulting project is byte-for-byte identical in DB content.

2. **Given** a project with audio media that requires peak generation on open, **When** the user opens the project, **Then** no Lua-side polling timer fires during peak generation, and waveforms appear progressively as a C++-emitted signal triggers Lua redraws.

3. **Given** a media file being imported, **When** probing runs, **Then** no `ffprobe` subprocess is spawned and the probe result table contains the same fields with the same values (codec, resolution, frame rate, duration, channels, sample rate, rotation, BWF time_reference) as the pre-migration probe.

4. **Given** the existing test suites (Rational, DRP, peak cache, media_reader, FCP7 import bindings), **When** all phases land, **Then** every existing test passes without modification.

5. **Given** any phase has shipped, **When** that phase is reverted in isolation, **Then** the system returns to a working state without requiring revert of subsequent phases.

### Edge Cases

- Probing a corrupt media file: must surface an error rather than fall back to ffprobe or return defaults.
- DRP blob with malformed TLV structure: must surface a decode error with byte offset; no silent skip.
- Peak generation cancelled mid-flight: completion signal must not fire; in-progress C++ state must release cleanly.
- Rational userdata passed across an undo boundary that captures Lua state: equality and hashing must remain stable across capture/restore.
- An in-flight phase migration partially exposed (new C++ entry point present but some Lua callers not yet rewired): no caller may invoke both old and new paths within a single user action.

---

## Requirements *(mandatory)*

### Functional Requirements — Phase 1: Native Media Probing (EMP)
- **FR-1.1**: The system MUST probe media file metadata via EMP's existing file-open path, not via a `ffprobe` subprocess.
- **FR-1.2**: EMP MUST expose probe results in an editor-agnostic shape — raw media facts only (container, streams, codec, dimensions, frame rate, duration, channel count, sample rate, rotation, BWF `time_reference`). No JVE-specific field names, no JVE-specific result schema.
- **FR-1.3**: JVE-specific reshaping of the probe result into the table shape expected by `commands/import_media.lua` MUST happen in Lua (or in JVE C++ if measurably hot), NOT in EMP.
- **FR-1.4**: Existing import callers MUST continue to work without schema changes to the JVE-side probe result table.
- **FR-1.5**: A failed probe MUST surface an error with file path and underlying cause; no fallback values, no defaults, no silent retry.
- **FR-1.6**: After this phase ships, no production code path MUST invoke `ffprobe` as a subprocess.
- **FR-1.7**: EMP MUST NOT gain any symbol, type name, or comment referring to JVE, .jvp, DRP, FCP7, or other editor-specific concepts as part of this phase.

### Functional Requirements — Phase 2: Peak Cache Orchestration (EMP)
- **FR-2.1**: Peak-generation completion MUST be delivered to the host via an EMP-emitted callback or event, not via a host-side polling timer. The callback/event mechanism MUST be editor-agnostic (no JVE-specific signal names or assumptions).
- **FR-2.2**: Progress updates during long peak generation MUST also be delivered via the same editor-agnostic mechanism, sufficient for a host UI to redraw progressively as new peak ranges become queryable.
- **FR-2.3**: JVE's Lua MUST retain responsibility for: deciding which media needs peaks (visibility), invoking redraws, and checking source-file mtime/staleness at request time. Routing EMP events into `core/signals.lua` or `core/watchers.lua` is a JVE-side concern and MUST happen in Lua or JVE C++, not in EMP.
- **FR-2.4**: Cancellation of an in-flight peak generation MUST cleanly release EMP state and MUST NOT subsequently emit completion events for the cancelled job.
- **FR-2.5**: After this phase ships, no Lua module MUST schedule a recurring timer to poll peak generation status.
- **FR-2.6**: EMP's peak API MUST NOT embed JVE-specific concepts (e.g., `media_id` as a JVE DB row id). EMP identifies peak jobs by its own opaque handle; JVE maps its `media_id` to that handle in Lua.

### Functional Requirements — Phase 3: DRP Binary Blob Decoder (JVE C++, NOT EMP)
- **FR-3.1**: The DRP blob decoder MUST live in JVE C++ (`src/cpp/` or equivalent JVE-only location), NOT in EMP. DaVinci Resolve project format knowledge is editor-specific and has no place in a distributable media platform library.
- **FR-3.2**: The system MUST decode all DRP binary blob types currently handled by the Lua decoder (BtVideoInfo, TracksBA, EffectFiltersBA, KeyframesBA, UIElementsState, MediaTimemapBA) in JVE C++, exposed through a single binding entry point keyed by blob type.
- **FR-3.3**: The decoder MAY use generic binary-parsing primitives from EMP (e.g., if EMP exposes BE/LE integer readers or IEEE 754 decoders as general utilities), but MUST NOT introduce DRP-specific types, field names, or blob-type constants into EMP.
- **FR-3.4**: The decoded result returned to Lua MUST be structurally identical (same nested table shape, same field names, same value types) to the pre-migration Lua decoder output, verified by the existing 38 DRP tests passing unmodified.
- **FR-3.5**: Decode of a malformed blob MUST surface an error identifying the blob type, byte offset, and failing field; no silent skip, no partial result.
- **FR-3.6**: The Lua DRP importer MUST retain ownership of XML parsing, blob extraction from XML, DB writes, and overall import sequencing.
- **FR-3.7**: Total import time on a representative ≥500-clip DRP MUST be at least 5× faster on the blob-decode portion than a measured pre-migration baseline. Baseline must be captured and recorded before this phase begins.
- **FR-3.8**: Decoding MUST remain numerically exact for IEEE 754 doubles encoded in the blob format; no precision loss from intermediate representations.

### Functional Requirements — Phase 4: Frame/Timecode Utility Hot Ops (Conditional, EMP)
- **FR-4.1**: This phase MUST NOT begin unless Phase 5 has either landed or has a committed design that establishes an EMP Rational primitive.
- **FR-4.2**: Timecode formatting and frame snapping, if migrated, MUST live in EMP as editor-agnostic primitives (input: a rational time and a rate; output: a formatted string or snapped rational). No JVE-specific concepts (clip, track, sequence, playhead) in EMP signatures.
- **FR-4.3**: JVE Lua utilities (`frame_utils.lua`, `timecode.lua`) MUST remain as thin JVE-side wrappers that adapt JVE call sites to the EMP primitives.
- **FR-4.4**: If executed, results MUST be bit-identical to the current Lua implementations across the existing test suite.
- **FR-4.5**: If, during planning, the Lua↔C++ boundary cost is measured to exceed the compute saved, this phase MUST be cancelled and the decision recorded; partial migration is not acceptable.

### Functional Requirements — Phase 5: Rational Time Primitive (EMP)
- **FR-5.1**: The Rational primitive MUST live in EMP, built on the existing `emp::Rate` foundation. It is generic rational-number time math, applicable to any editor.
- **FR-5.2**: The primitive MUST support add, subtract, rescale (round/floor/ceil rounding modes), equality (via cross-multiplication, no float comparison), and ordered comparison.
- **FR-5.3**: Existing JVE Lua call sites using `Rational:method()` form MUST continue to compile and run unchanged. The Lua `core/rational.lua` module remains as the JVE-side public surface; its implementation delegates to EMP.
- **FR-5.4**: Rational values MUST be safely passable across undo capture/restore boundaries, including equality and identity semantics that the JVE command system depends on. Capture/restore semantics are a JVE concern; EMP MUST expose sufficient primitives (serialize to a plain value, construct from a plain value, equality) for JVE to implement them without reaching into EMP internals.
- **FR-5.5**: All 60+ existing Rational tests MUST pass unmodified.
- **FR-5.6**: This phase MUST NOT migrate any consumer of Rational (command_manager, timeline_constraints, command_rational_helpers, frame_utils, timecode) into C++; the migration is bounded to the Rational primitive itself.
- **FR-5.7**: EMP's Rational MUST NOT gain any JVE-specific convenience methods, constants, or metadata.

### Cross-Phase Functional Requirements
- **FR-X.1**: Each phase MUST ship as one mergeable unit and MUST be independently revertable without breaking subsequent phases that have not yet shipped.
- **FR-X.2**: No phase MUST grow the Lua side of its target subsystem; LOC on the Lua side MUST be equal or smaller after the phase.
- **FR-X.3**: Each phase MUST add new black-box tests for the new C++ entry point that verify domain behavior (not implementation), independent of the inherited test suite.
- **FR-X.4**: Each phase MUST end with an audit pass against ENGINEERING.md (rules 1.14, 2.4, 2.13, 2.15, 2.20, 2.21, 2.32, 3.14) before being marked done. The audit findings MUST be reported in the phase commit or PR.
- **FR-X.5**: No phase MUST introduce a fallback value, default, or compatibility shim. Errors MUST surface with sufficient context to identify the failing input.
- **FR-X.6**: At no point during a phase rollout MUST a single user action invoke both the old (Lua) and new (C++) code path for the same subsystem.
- **FR-X.7 (EMP distributability)**: EMP MUST remain buildable and testable as a standalone library with no dependency on JVE headers, JVE types, JVE constants, or JVE test fixtures. Any phase that places code in EMP MUST verify this by building EMP in isolation as part of phase acceptance.
- **FR-X.8 (placement rule)**: For each unit of C++ added in any phase, the phase's commit/PR MUST justify the placement choice (EMP vs JVE C++) in one sentence. Default answer: "does this type/function make sense for a non-JVE editor?" If no → JVE C++. If yes → EMP.
- **FR-X.9 (no backflow)**: JVE concepts (`media_id`, `.jvp` schema, DRP, FCP7, `Clip`, `Sequence`, `Track`, `Project`) MUST NOT appear in EMP source. Grep-level check: EMP source MUST match zero occurrences of these tokens after each phase.

### Out of Scope (Explicit)
- **FCP7 XML importer** (`src/lua/importers/fcp7_xml_importer.lua`): live, actively maintained code with binding tests (`test_import_fcp7_xml.lua`, `test_import_fcp7_negative_start.lua`, `test_import_bad_xml.lua`) and a registered command. Stays in Lua because the underlying XML parser was already migrated to C++ in commit `3d045f51` (xml2.lua → QXmlStreamReader); what remains is orchestration, not hot compute. No work in this feature.
- **Premiere `.prproj` importer** (`src/lua/importers/prproj_importer.lua`): same rationale — orchestration over an already-C++ XML parser.
- **Command dispatch**, command_manager, timeline_state, ORM models (Clip, Sequence, Project), panel UI modules, signals module: stay in Lua per established architecture.
- **Rendering pipeline** and **audio pipeline** (TMB/SSE/AOP): already in C++; not affected.

### Key Entities
- **Probe Result**: Structured description of a media file's streams and metadata. Produced once at import; consumed by import to populate Media records.
- **Peak Generation Job**: Long-running C++ task producing waveform peak data. States: {requested, in-progress, complete, cancelled}. Emits progress and completion signals.
- **DRP Binary Blob**: Typed binary payload embedded in DaVinci Resolve project XML. Each type has its own structured shape (clips, keyframes, effects, UI state, time-remapping).
- **Rational**: Exact rational number representing time and rates throughout the timeline. Identity and equality semantics matter to the command/undo system.

---

## Success Criteria

- Import time on a representative ≥500-clip DRP measurably reduced; blob-decode portion ≥5× faster than recorded pre-migration baseline.
- Project open with peak generation no longer schedules a Lua-side polling timer; main thread stalls during waveform generation eliminated.
- Media import dialog spawns no `ffprobe` subprocesses.
- All existing tests pass without modification across all phases.
- Lua side of each migrated subsystem is equal or smaller in LOC; no Lua glue grown to accommodate C++ bindings.
- Each phase has an ENGINEERING.md audit recorded.

---

## Review & Acceptance Checklist

### Content Quality
- [x] Focused on observable outcomes (import speed, UI responsiveness, no subprocess spawning)
- [x] Phase boundaries clearly bounded
- [x] Out-of-scope items explicitly listed with rationale
- [x] All mandatory sections completed

### Requirement Completeness
- [x] No [NEEDS CLARIFICATION] markers remain (open questions tracked separately below)
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable (5× speedup, zero subprocess, zero polling timer, LOC equal-or-smaller)
- [x] Scope is clearly bounded per phase
- [x] Dependencies between phases identified (Phase 4 gated on Phase 5)

---

## Unresolved Questions

- Phase 3 home: JVE C++ confirmed. But *which subdir* of `src/cpp/`? New `src/cpp/importers/drp/`? Existing location? Decide before Phase 3 design.
- Phase 3 generic primitives: which binary-decode helpers (varint, BE/LE readers, IEEE 754 decoder) are generic enough to live in EMP as utilities, vs. staying in JVE C++ as internal helpers? Err toward JVE C++ unless reuse is concrete.
- Phase 3 baseline: which DRP file is the 5× reference? Need representative ≥500-clip Resolve 19.x project committed (or path referenced) before Phase 3 starts.
- Phase 2 event mechanism: EMP needs an editor-agnostic callback/event shape (C function pointers? std::function? Qt signal — but EMP should avoid Qt if distributable to non-Qt hosts). Decide before Phase 2 design, and confirm whether EMP already depends on Qt.
- Phase 2 JVE signal routing: once EMP emits an event, should JVE deliver it via the broadcast `core/signals.lua` or the planned per-entity `core/watchers.lua`? JVE-side question only.
- Phase 5 userdata identity: command undo captures Rational values. Clone or reference? Affects whether EMP Rational is plain value type or GC-managed handle, and what EMP must expose for JVE to serialize/restore.
- Phase 1 error surface: assert (process exit) vs. Lua-level error (pcall-catchable) for malformed media at import. Import flow currently shows user a dialog on failure; assert would crash. Confirm.
- Phase 1 FFmpeg/codec licensing: ffprobe was a subprocess boundary. If EMP's internal decoder links FFmpeg, does EMP's distributability story change (LGPL/GPL implications for downstream editors)? Confirm before removing the ffprobe path entirely.
- Phase 4 cancellation criterion: what measurement and threshold defines "boundary cost exceeds compute saved"? Need concrete benchmark + cutoff before Phase 4 starts.
- FCP7 / prproj importers: are they future candidates for the same JVE-C++-not-EMP treatment if profiling shows their orchestration is actually hot? Flag for downstream planning.
- EMP's current Qt dependency: EMP today lives alongside Qt bindings. For true distributability, does EMP need a Qt-free build mode, or is "Qt-required platform" acceptable for the distributable? This shapes every API choice in this feature.
