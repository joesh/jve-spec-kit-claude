# Session note — 2026-04-25 — Expand/Collapse design landed in spec

## TL;DR

Joe flagged a hole in the original 013 design: FR-002 (composite-only audio drop) makes us FCPX-trackless on the audio side. Spec now supports BOTH composite (single nested-ref clip, all channels composited) AND expanded (N per-track clips, each exposing one audio track). Path 1 + Path 2.

## What landed (spec/contract/schema only — no command code yet)

- `spec.md`: FR-002, FR-003, FR-005 rewritten; FR-021 terminology extended; new **FR-023 ExpandAudio**, **FR-024 CollapseAudio**, **FR-025 default drop-mode**. 8 new edge cases.
- `data-model.md`: `clips.master_audio_track_id` column added (NULL = composite, non-NULL = single audio track of nested seq, symmetric to `master_layer_track_id`). **INV-9** added.
- `src/lua/schema.sql`: matching column with FK + ON DELETE SET NULL. Additive — does NOT break already-landed composite path.
- `contracts/resolver.md`: track-selector step now symmetric V/A. G-R5 extended for dangling audio selector.
- `contracts/commands.md`: Insert/Overwrite gain optional `audio_drop_mode` arg + CT-C1b. New `ExpandAudio` (CT-C20/20b) and `CollapseAudio` (CT-C21/21b/21c/21d) specs with full refusal-list and undo capture.
- `tasks.md`: T003a (schema test), T008a (schema impl — already in schema.sql), T021a (resolver test), **Phase 3.5.c (T056a-T056l)** — 8 tests + 4 impl tasks for Expand/Collapse + AddClipsToSequence drop-mode + resolver extension. T073b (importer classification).

## What this means for the in-flight work

**Nothing already-landed needs to be torn up.** Composite is the strict subset. All commands T030-T069 keep working untouched.

The new pieces plug in additively:
- Schema column: already in `schema.sql` (T008a).
- Resolver: one-line filter extension symmetric to existing video filter at `resolver.md:71`.
- AddClipsToSequence: optional arg with default 'composite' — CT-C1 stays green.
- Two new commands following the T048-T056 override-command shape.
- Importers (Phase 3.8, not yet started) born aware of FR-025 classification.

## Terminology decision (FR-021)

**Expand Audio** / **Collapse Audio**. Came from a research pass:
- FCP X "Expand/Collapse Audio Components" — only major NLE with a clean reversible pair. Strongest precedent.
- Avid "Expand to Tracks" — recognizes "Expand" but no inverse.
- Premiere "Breakout to Mono" — wrong semantic (channel-shape, not track-shape). Avoid.
- Reaper "Explode" — sounds destructive. Avoid.
- Resolve "Multichannel ↔ Mono" — wrong semantic. Avoid.

We dropped FCP X's "Components" qualifier since FCP X is trackless and we're tracked — different operation.

## Key design decisions (rationale, in case they're questioned)

1. **Audio selector NULL = composite, non-NULL = single track**. Symmetric to video's `master_layer_track_id`. Composite stays the default (FR-005 / today's behavior preserved).
2. **Expand collision = refuse + name offender**. Auto-creating tracks is non-destructive (silent OK); collision is destructive (loud-fail per rule 1.14). User clears space and retries.
3. **Collapse with partial selection / missing tracks = projects to per-channel disables**. Joe's insight: deleting an expanded clip is audibly equivalent to muting it. So "incomplete coverage" doesn't refuse — it projects. Roundtrips losslessly.
4. **Collapse with divergent windows = refuse**. This is the only true refusal: per-channel slip is the expressiveness Expand genuinely buys; composite has nowhere to encode it.
5. **Drop mode is per-source heuristic + user override**. Importers classify (synced/multicam → composite; poly-WAV/multitrack → expanded). User toggles via Expand/Collapse afterward.

## Carry-forward unresolved (not yet in `/clarify` round)

- Selection gesture for Collapse: explicit N-clip vs single-clip-implies-link-group. Lean: **explicit** (subset case argues for it).
- Composite that has been partial-collapsed + master later gains a new audio track: new track plays through composite alive (FR-007 default). Confirmed consistent with composite semantics; surprise possible.
- Command keystrokes / menu placement: UX surface, defer.

## Don't reopen (already settled with Joe)

- Audio selector points at ONE track, not a subset. (Subsets get messy; per-channel state covers the subset case.)
- Volume-per-clip → per-channel gain projection. Lossless.
- Clip-level mute → per-channel disables on that clip's tracks. Lossless.
- Non-contiguous tracks at collapse time: topmost selected wins, silent.
- Zero per-track clips remaining: Collapse refuses (don't synthesize a fresh composite — user re-places from master).

## Tree state

Branch: `013-timeline-placements-as`. No commits made by this session — design-only edits to spec/contract/schema.sql files, untracked. Sibling-Claude work visible in `src/audio_output_platform/`, `src/lua/qt_bindings/`, several `tests/test_audio_*` — DO NOT TOUCH; not mine.
