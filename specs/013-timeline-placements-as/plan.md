# Implementation Plan: Timeline Placements as Nested Sequence References

**Branch**: `013-timeline-placements-as` | **Date**: 2026-04-23 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/Users/joe/Local/jve-spec-kit-claude/specs/013-timeline-placements-as/spec.md`

## Summary

Collapse four today-distinct primitives (synced clips, multicam clips, compound clips, single-camera clips) into a uniform three-table model:

- `sequences` holds every sequence with `kind IN ('master','nested')`.
- **Master sequences** (`kind='master'`) hold **media refs** on their tracks — direct references to media files.
- **Non-master sequences** (`kind='nested'`) hold **clips** on their tracks — references to other sequences.

Every user-visible entry on a non-master sequence's timeline is a clip (a reference to another sequence). Clips live-track the referenced sequence by default, with sparse per-clip overrides (layer selector, channel enable/gain) that diverge only on properties the editor has explicitly touched. Media references live exclusively in media refs inside masters. No backward compatibility; old project files are invalidated. All editing commands rewired at once. Export uses the same resolver as playback, with export-only processing applied above the resolver.

## Technical Context

**Language/Version**: Lua (LuaJIT). No C++ changes required for this feature: clip resolution runs entirely in Lua before the flat media-ref list reaches TMB (the C++ media pipeline). All data model, commands, resolver, override state, renderer pull paths, and importer updates are Lua-layer work.
**Primary Dependencies**: Qt6 (UI + XML parsing), LuaJIT (scripting), SQLite3 (project storage), libzstd (DRP FieldsBlob decode — already landed earlier this session), nlohmann_json, FFmpeg (media decode), lsqlite3.
**Storage**: SQLite `.jvp` project files. Schema change is substantial but unconstrained by back-compat requirements (FR-018).
**Testing**: LuaJIT black-box tests under `tests/` (run via `tests/run_lua_tests_all.sh`), plus `--test` mode integration tests under `tests/synthetic/integration/` (run via `tests/run_integration_tests.sh`). Zero mocks that encode assumptions; non-trivial values; domain-behavior assertions.
**Target Platform**: macOS (Darwin 24+, Qt6); Linux/Windows follow. Desktop application; no network, no multi-user.
**Project Type**: Single project, hybrid C++/Lua. Source layout `src/lua/*` + `src/*.cpp`.
**Performance Goals**: Preview playback cadence p95 ≤ 80ms (existing integration-test budget). Clip resolution recursion must not regress the current single-level clip-resolution latency at 24/25/30 fps.
**Constraints**:
- Fail-fast asserts (no silent fallbacks).
- MVC: views pull from model state; timeline renderer queries `clips` or `media_refs` (branching on focused sequence's `kind`), doesn't receive imperative push outside playback hot path.
- Every editing command undoable; each override change one undo step (FR-020).
- All 22 FRs testable black-box.
**Scale/Scope**: Existing projects have hundreds of masters and thousands of clips (anamnesis-gold-timeline: 562 media, dozens of media refs per master worst case, thousands of clips on timelines). Nesting depth unbounded (FR-010) — implementations must avoid O(depth²) traversal on the hot path.

## Constitution Check
*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Note |
|---|---|---|
| I. Modular Architecture + MVC | ✅ | Feature extends existing model layer (`src/lua/models/sequence.lua`, `src/lua/models/clip.lua`) and command layer; renderer is pull-based, model emits mutation signals per existing infrastructure. |
| II. Command-Driven Interface | ✅ | All mutations — including the new override commands (channel toggle, gain, layer selector, master-level audio automation) — register via `command_manager`. |
| III. Test-First Development | ✅ | TDD gates every task (§ Phase 2). Black-box tests for playback recursion, override resolution, import, export parity, cycle detection. |
| IV. Documentation-Driven Specifications | ✅ | Spec locked; this plan defines what ships. |
| V. Template-Based Consistency | ✅ | Uses spec-kit templates. |
| VI. Fail-Fast Assert Policy | ✅ | Cycle detection refuses at mutation time (FR-010); missing master surfaces loud-fail per FR-022; invalid override (e.g., layer_index pointing at deleted track) asserts with context. |
| VII. No Fallbacks or Default Values | ✅ | No `or N`; audio_sample_rate no longer defaulted to 48000 (landed earlier this session); clip's window must be complete at drop time. |
| VIII. No Backward Compatibility | ✅ | FR-018: old timeline-Clip model deleted, not gated. Existing `.jvp` files won't open. |

Initial Constitution Check: **PASS**

## Project Structure

### Documentation (this feature)
```
specs/013-timeline-placements-as/
├── plan.md              # This file
├── research.md          # Phase 0 output — resolves data-model + algorithm choices
├── data-model.md        # Phase 1 output — schema + entity fields + invariants
├── contracts/           # Phase 1 output — resolver, command, renderer contracts
│   ├── resolver.md
│   ├── commands.md
│   └── renderer.md
├── quickstart.md        # Phase 1 output — end-to-end manual validation scenarios
└── tasks.md             # Phase 2 output (/tasks — NOT created by /plan)
```

### Source Code (repository root)
```
src/lua/
├── schema.sql                          # sequences.kind narrows to ('master','nested');
│                                       #   add default_video_layer_track_id, video/audio
│                                       #   start_tc, fps_mismatch_policy. NEW tables:
│                                       #   media_refs, media_refs_channel_state,
│                                       #   clip_channel_override. clips.clip_kind and
│                                       #   clips.media_id removed; master_clip_id
│                                       #   renamed to nested_sequence_id.
├── models/
│   ├── sequence.lua                    # ensure_master (renamed from ensure_masterclip); pick_in_range
│   │                                   #   dispatch on kind; cycle detection
│   ├── clip.lua                        # clips row shape + override resolution helpers;
│   │                                   #   INV-2 assertion (owner_sequence_id is nested)
│   ├── media_ref.lua                   # NEW: media_refs row shape; INV-1 assertion
│   └── track.lua                       # Stable track identity surfacing for clips
├── core/
│   ├── commands/
│   │   ├── add_clips_to_sequence.lua   # Create clip rows referencing sequences; no flattening
│   │   ├── insert.lua, overwrite.lua   # Stop flattening; insert clip rows only
│   │   ├── trim_head.lua, trim_tail.lua, roll.lua,
│   │   │   slip.lua, slide.lua, ripple_*.lua,
│   │   │   split_clip.lua, blade.lua,
│   │   │   extend_edit.lua, delete_*.lua,
│   │   │   duplicate.lua                # All operate on clip rows; source units are
│   │   │                                  the nested sequence's timebase.
│   │   ├── nest.lua                     # NEW: Nest selection into a new kind='nested' sequence
│   │   ├── unnest.lua                   # NEW: expand a clip's nested sequence inline; refuses
│   │   │                                   on masters.
│   │   ├── set_clip_layer.lua          # NEW: per-clip layer override
│   │   ├── toggle_clip_channel.lua     # NEW: per-clip channel enable override
│   │   ├── set_clip_channel_gain.lua   # NEW
│   │   ├── clear_clip_override.lua     # NEW
│   │   ├── set_master_default_layer.lua # NEW: sequences.default_video_layer_track_id
│   │   ├── set_master_channel_state.lua # NEW: media_refs_channel_state upsert
│   │   ├── set_sequence_start_tc.lua   # NEW: per-sequence video/audio start TC
│   │   └── set_fps_mismatch_policy.lua # NEW: project-level + per-clip override
│   ├── playback/
│   │   └── playback_engine.lua         # Consumes resolver; thin-wrapper API stays, delegates
│   │                                     to pick_in_range
│   ├── renderer.lua                    # Lua composition layer; already pull-based
│   └── export/
│       └── export_engine.lua           # NEW: shares pick_in_range with playback (FR-019)
├── importers/
│   ├── drp_importer.lua                # Emit clips (not flattened); synced-clip decoder
│   │                                     already landed; create kind='master' sequences
│   │                                     populated with media_refs
│   ├── fcp7_xml_importer.lua           # same
│   └── prproj_importer.lua             # same
├── media/
│   └── media_reader.lua                # Drag-drop: create kind='master' + media_ref,
│   │                                     then a clip on the current edit sequence
└── ui/
    ├── timeline/view/
    │   └── timeline_view_renderer.lua  # Branch on focused sequence's kind: query media_refs
    │                                     for masters, clips for non-masters. Waveform/offline
    │                                     follows clip → nested sequence → media_ref → media.
    └── inspector/
        └── schema.lua                  # Master inspector (default layer, start TCs,
                                          channel state); clip inspector (layer override,
                                          per-channel overrides, fps policy); media_ref
                                          inspector (window + volume).

tests/
├── test_clip_*.lua                     # clips row shape, override resolution, cycle detection
├── test_media_ref_*.lua                # media_refs row shape, INV-1 assertion
├── test_timeline_command_*.lua         # One per rewired + new command, black-box
├── test_pick_in_range_*.lua         # Resolver recursion, layer/channel overrides,
│                                         fps-mismatch, cycle defense-in-depth
├── test_nest_unnest.lua                # Nest and Unnest; refusal on master unnest
├── test_export_resolver_parity.lua     # FR-019: export == playback for same content
└── integration/
    ├── test_synced_clip_playback.lua   # Real Resolve DRP synced clip → audio from WAV
    ├── test_multicam_layer_switch.lua  # Drop multicam, change layer, verify media file swap
    └── test_nested_sequence_depth.lua  # Nested sequence with another nested sequence inside,
                                          playback recurses correctly
```

**Structure Decision**: Single project, extend existing `src/lua/models/` and `src/lua/core/commands/` layout. The refactor adds one new model module (`media_ref.lua`) and narrows `clip.lua`'s scope; new override and nest/unnest commands; importers emit the new shape. No changes required to the C++ TMB or renderer layers — recursion lives in Lua before the flat clip list reaches TMB.

## Phase 0: Outline & Research

Five questions resolved in `research.md`:

1. **Row-type separation**: split today's `clips` into two tables (`media_refs` inside masters, `clips` inside non-masters). Table-as-type removes the `source_in_frame` unit ambiguity.
2. **Override state storage**: dedicated sparse tables (`clip_channel_override`, `media_refs_channel_state`) + one nullable column on `clips` (`master_layer_track_id`). Enables row-level undo per FR-020.
3. **Cycle detection**: uncached mutation-time DFS + defense-in-depth resolver assert.
4. **Layer selector + FK**: `track_id` FK with `ON DELETE SET NULL` on the per-clip override; master's own `default_video_layer_track_id` under INV-8.
5. **Resolver signature + override order**: unified `Sequence:pick_in_range(seq_id, start, end, context)`; override order layer → channel → gain; same code path for preview and export.

**Output**: `research.md` with one Decision / Rationale / Alternatives considered block per question.

## Phase 1: Design & Contracts
*Prerequisites: research.md complete*

1. **data-model.md**: three-table split. Column-for-column schema with invariants.
   - `sequences` — `kind` narrows to `('master','nested')`; add `default_video_layer_track_id`, `video_start_tc_frame`, `audio_start_tc_samples`, `fps_mismatch_policy`.
   - `media_refs` (NEW) — direct media references inside master sequences; replaces today's `clips` rows where `clip_kind='master'`.
   - `clips` — now exclusively holds sequence-references. `clip_kind` and `media_id` removed; `master_clip_id` renamed to `nested_sequence_id`; `master_layer_track_id` and `fps_mismatch_policy` added. `source_in/out_frame` units are the referenced sequence's timebase.
   - `media_refs_channel_state` (NEW) — master-level per-channel enable/gain.
   - `clip_channel_override` (NEW) — sparse per-clip per-channel overrides.
   - `clip_links` (existing) — unchanged; scopes exclusively to clips (media_refs don't have link groups).
   - State transitions for each override lifecycle + clip creation + nest/unnest are documented.

2. **contracts/resolver.md**: `Sequence:pick_in_range` interface. Dispatches on `sequences.kind` — master reads `media_refs`, nested recurses via `clips`. Documents cycle-safety, override order, fps-mismatch plumbing, offline loud-fail, export parity. Single code path for playback and export (FR-019).

3. **contracts/commands.md**: per-command entries for rewired existing commands (Insert, Overwrite, Trim, Slip, Slide, Roll, Ripple, Split, Blade, Extend, Delete, Duplicate), new override commands (per-clip and master-level), and new nest/unnest commands.

4. **contracts/renderer.md**: pull contract for the timeline view renderer and inspector. Branches on the focused sequence's `kind`: queries `media_refs` for masters, `clips` for non-masters. Waveform/offline indicators walk `clips.nested_sequence_id` → media_refs → media.

5. **contract tests**: one failing test per contract endpoint (command / resolver / renderer). TDD gates.

6. **quickstart.md**: end-to-end manual validation scenarios that map directly to the spec's 11 Acceptance Scenarios. Each scenario: setup, action, expected observable result. Runs in `--test` mode where possible.

7. **Agent file update**: run `.specify/scripts/bash/update-agent-context.sh claude`. Adds the three-table model + override semantics to the active tech surface for future sessions.

**Output**:
- `/Users/joe/Local/jve-spec-kit-claude/specs/013-timeline-placements-as/data-model.md`
- `/Users/joe/Local/jve-spec-kit-claude/specs/013-timeline-placements-as/contracts/{resolver,commands,renderer}.md`
- `/Users/joe/Local/jve-spec-kit-claude/specs/013-timeline-placements-as/quickstart.md`
- Updated `CLAUDE.md` (agent context)

## Phase 2: Task Planning Approach
*This section describes what the /tasks command will do — DO NOT execute during /plan*

**Task Generation Strategy**:

Load `.specify/templates/tasks-template.md` as base. Generate tasks from Phase 1 design docs:

- Each entity in data-model.md → schema-migration task + model-module task (with black-box test task preceding implementation).
- Each resolver contract → contract-test task + implementation task + recursion-depth test.
- Each command in contracts/commands.md (existing-command rewire + new override commands) → command-spec test task + command implementation task.
- Each Acceptance Scenario in spec.md → integration-test task under `tests/synthetic/integration/`.
- Renderer/inspector pull updates → UI test + UI implementation task per affected surface.
- Importer updates (DRP already in progress, FCP7, prproj, drag-drop) → per-importer nested-ref emission task + fixture-validation test.

**Ordering Strategy**:

1. **Schema changes first** — `src/lua/schema.sql` migration (add `media_refs`, `media_refs_channel_state`, `clip_channel_override` tables; narrow `sequences.kind`; adjust `clips` columns). Blocks everything else.
2. **Model layer next** — `media_ref.lua` and `clip.lua` row shapes, INV-1 / INV-2 / INV-3 assertions, cycle detection, `pick_in_range` dispatch on `sequences.kind`. TDD-first.
3. **Command layer** — `add_clips_to_sequence.lua` → insert/overwrite → trim/roll/slip/slide → ripple/split/blade/extend → delete/duplicate. In roughly this dependency order.
4. **Override commands (new)** — per-clip layer/channel; master default-layer; master channel state; per-sequence start TC; project fps-mismatch policy.
5. **Nest / unnest commands** — create + inverse operations; refuse unnest on masters.
6. **Importers** — DRP (landing on existing synced-clip infra) → FCP7 → prproj → drag-drop/media_reader. Each produces masters with media_refs + clips on target sequences.
7. **Renderer + inspector UI updates** — kind-branching queries, waveform/offline chain traversal, inspector fields for all three selection targets (clip / master / media_ref).
8. **Export** — wire to shared `pick_in_range`; export-only processing-pipeline tests.
9. **End-to-end integration tests** — one per Acceptance Scenario.
10. **Cleanup** — delete legacy `clip_kind` / `media_id`-on-timeline-clips code paths (FR-018); no compatibility shims.

**Parallelism markers [P]**: independent commands, independent importer updates, independent inspector schema entries.

**Estimated Output**: 40–55 numbered, ordered tasks in tasks.md (larger than the template's typical 25–30 estimate because this feature touches every editing command).

**IMPORTANT**: This phase is executed by the /tasks command, NOT by /plan.

## Phase 3+: Future Implementation
*These phases are beyond the scope of the /plan command*

**Phase 3**: `/tasks` generates `tasks.md`.
**Phase 4**: Implementation following constitutional principles — TDD per task, fail-fast asserts, no fallbacks, no back-compat.
**Phase 5**: Validation — run `tests/run_lua_tests_all.sh` + `tests/run_integration_tests.sh`; execute quickstart.md scenarios; performance regression check against current playback p95.

## Complexity Tracking

*No Constitution Check violations requiring justification.*

The plan is intentionally large (one primitive replaces four, rewiring every editing command) but each piece is within the patterns already established in the codebase (command_manager, sequence model, TMB flat-clip interface, clip_mutator). No new frameworks, no new architectural paradigms, no constitutional exceptions requested.

## Progress Tracking

**Phase Status**:
- [x] Phase 0: Research complete (/plan command)
- [x] Phase 1: Design complete (/plan command)
- [x] Phase 2: Task planning complete (/plan command — describes approach only)
- [ ] Phase 3: Tasks generated (/tasks command)
- [ ] Phase 4: Implementation complete
- [ ] Phase 5: Validation passed

**Gate Status**:
- [x] Initial Constitution Check: PASS
- [x] Post-Design Constitution Check: PASS (no new violations introduced by design)
- [x] All NEEDS CLARIFICATION resolved (none remained in spec; 4 answered in `/clarify` session; 5 orthogonal items deferred to separate work streams)
- [x] Complexity deviations documented (none required)

---
*Based on Constitution v2.0.0 — See `.specify/memory/constitution.md`*
