# Feature Specification: Gap-as-Clip Refactor

**Feature Branch**: `005-gap-as-clip-refactor`
**Created**: 2026-04-01
**Status**: Draft
**Input**: Refactor gap from edge-modifier to first-class clip entity — eliminate special-case complexity in ripple/roll/preview/constraint pipeline.

---

## User Scenarios & Testing

### Primary User Story

As an editor, when I interact with a gap between clips — dragging its edge, rolling into it, ripple-trimming past it — it behaves identically to any other clip boundary. There is no behavioral difference between "clip meets clip" and "clip meets gap." All timeline operations (roll, ripple, insert, delete, undo) treat gaps as normal entities. The complexity of gap handling is invisible to me.

### Acceptance Scenarios

1. **Given** two clips with a gap between them on V1, **When** the user roll-drags the left clip's out edge right, **Then** the left clip extends into the gap, the gap shrinks, the right clip stays put.

2. **Given** two clips with a gap between them on V1 and linked audio on A1/A2, **When** the user ripple-trims the left clip's out edge (shrinking it), **Then** the gap grows, the right clip and all downstream clips on all tracks shift left by the same amount.

3. **Given** two adjacent clips (no gap) on V1, **When** the user ripple-trims the left clip's out edge (shrinking it), **Then** a gap appears between the clips, all downstream clips shift left, and the gap is a visible, selectable entity.

4. **Given** a gap exists on V1, **When** the user selects the gap's edge and drags it (ripple), **Then** the gap closes and the downstream clip shifts — identical to today's behavior.

5. **Given** a clip-gap roll preview is in progress, **When** the user releases the mouse, **Then** the commit produces the exact result shown in the preview, with no constraint divergence.

6. **Given** a multitrack timeline with clips on V1/A1/A2 at aligned cut points with no gaps on audio tracks, **When** the user ripple-trims V1 (shrink), **Then** the operation is blocked because audio clips have no gap to absorb the shift. Blocking edges shown red.

7. **Given** a gap on V1, **When** the user undoes an operation that created or modified the gap, **Then** the gap is restored to its previous state exactly.

8. **Given** a gap on V1, **When** the user inserts a clip into the gap, **Then** the gap splits or is consumed, with remaining gap portions preserved.

9. **Given** a gap on V1, **When** the user deletes the clip before the gap, **Then** the gap merges with any newly created empty space.

10. **Given** an ExtendEdit (E key) targeting a clip-gap boundary, **When** the command executes, **Then** the clip extends into the gap identically to a mouse drag roll.

### Edge Cases

- What happens when a gap is trimmed to zero duration? It is deleted, just like a normal clip trimmed to zero.
- What happens when two adjacent gaps exist (e.g., after deleting a clip between two gaps)? They merge into a single gap (delete one, extend the other).
- What happens when a clip is inserted or overwritten in the middle of a gap? The gap splits — just like any normal clip. Two gaps result, one on each side of the inserted clip.
- What happens when a gap is at timeline position 0? Its in-edge cannot go below 0 — same constraint as any clip.
- What about the space between timeline start (position 0) and the first clip? That’s a gap. It works like any other gap clip, even though it’s not between two media clips.
- How does the timeline renderer distinguish gaps from media clips visually? Gaps render as empty space (no waveform, no thumbnail), identical to today.
- What happens to gaps during DRP/XML import? Nothing — import doesn’t create gap clips. Gaps are computed when the imported sequence is opened in the timeline.
- What happens when all clips are removed from a track? One gap spans from 0 to the sequence end (or the track is treated as having one gap from 0).

## Clarifications

### Session 2026-04-01

- Q: How should adjacent-clip multitrack ripple work when no gap clip exists at the boundary? → A: Create a real zero-length gap clip on-the-fly at that boundary. Not a modifier on an adjacent clip — a proper gap entity that flows through the normal path.

## Requirements

### Functional Requirements

- **FR-001**: A gap MUST be represented as a clip entity with a start position, duration, unlimited maximum size, and a distinguishing marker (e.g., kind = "gap").
- **FR-001a**: The complexity of gap handling MUST be only in creating them and deleting them. The clip manipulation code MUST NOT look to see if it’s handling a gap clip vs a normal clip.
- **FR-002**: A gap MUST have no media reference, no source in/out points.
- **FR-003**: The edge selection system MUST select gap edges as standard in/out edges on the gap entity — not as modifier edge types on adjacent clips.
- **FR-004**: A clip-gap roll MUST use the same processing path as a clip-clip roll, with no special-case branching for gap edges.
- **FR-005**: The `gap_before` and `gap_after` edge types MUST be eliminated from the edge model.
- **FR-006**: All gap-specific pipeline steps (materialization, gap offset propagation) MUST be removed. Implied edge selection for multitrack ripple on adjacent clips (no gap present) is handled by creating a real zero-length gap clip on-the-fly (FR-010e), not by gap-specific injection logic.
- **FR-007**: All `is_gap_edge()` branching in constraint, preview, mutation, and rendering code MUST be removed.
- **FR-008**: Gap entities MUST be created and destroyed automatically as media clips change position (insert, delete, trim, roll, ripple delete).
- **FR-009**: Two adjacent gaps MUST merge into a single gap.
- **FR-010**: A gap trimmed to zero duration MUST be deleted, just like a normal clip.
- **FR-010a**: Gaps CAN be split by insert/overwrite, just like normal clips. Inserting a clip in the middle of a gap produces two gaps.
- **FR-010b**: Gaps have no maximum duration constraint — they can grow without limit. Minimum duration is zero (at which point the gap is deleted per FR-010).
- **FR-010e**: When multitrack ripple needs an implied edge on a track where clips are adjacent (no gap clip exists), a zero-length gap clip MUST be created on-the-fly at that boundary. This gap clip is a real gap entity (same type as any other gap), not a modifier on an adjacent clip. It participates in the selection and flows through the normal clip path.
- **FR-010c**: Gaps MUST be computed when a sequence is opened in the timeline panel and maintained in-memory for the lifetime of that timeline session. Gaps are updated locally as clips change. Gaps are destroyed when the sequence is closed. Sequences not open in the timeline have no gap clips. Import does not create gap clips.
- **FR-010d**: The edge picker, roll detector, constraint system, and renderer MUST find gap clips in the track's clip list — no special "detect empty space" logic. Gaps are normal clips that happen to be there.
- **FR-011**: Undo/redo MUST correctly restore gap state — creation, destruction, and geometry changes.
- **FR-012**: The timeline renderer MUST render gap entities as empty space, visually identical to current behavior.
- **FR-013**: All existing multitrack ripple tests (27 tests) MUST continue to pass without expectation changes — behavior is unchanged, only the mechanism changes.
- **FR-014**: The roll constraint system MUST treat gap entities as participants in the edit (present in edited_clip_lookup), not as fixed obstacles.
- **FR-015**: Gap entities MUST participate in the neighbor bounds cache identically to media clips.
- **FR-016**: The pre-commit mutation validation (safety net) MUST apply to gap entities the same way it applies to media clips.
- **FR-017**: Gap recomputation MUST be local — only the affected clips and their immediate neighbors, not the entire timeline. Feature-length edits with thousands of clips must not pay O(n) for a single trim.

### Key Entities

- **Gap Clip**: A normal clip entity except: not persisted to DB, has no media/source coordinates, and has no maximum duration constraint. Can be split by insert/overwrite (same as media clips). Can be deleted when trimmed to zero (same as media clips). Represents empty timeline space — between media clips, before the first clip, or after the last clip. Computed in-memory when the sequence opens, maintained for the timeline session lifetime, updated locally as clips change. Undo is free: restoring clip positions automatically recomputes correct gaps. The complexity of gap handling is ONLY in creating and deleting them — clip manipulation code does not distinguish gaps from media clips (FR-001a).
- **Media Clip**: Existing clip with media reference, source in/out. Unchanged by this refactor.
- **Edge**: A boundary on any clip — in (left) or out (right). Same type for both gap clips and media clips. The gap_before/gap_after distinction is eliminated.

---

## Review & Acceptance Checklist

### Content Quality
- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

### Requirement Completeness
- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

---

## Execution Status

- [x] User description parsed
- [x] Key concepts extracted
- [x] Ambiguities marked
- [x] User scenarios defined
- [x] Requirements generated
- [x] Entities identified
- [ ] Review checklist passed

---
