# Feature Specification: Per-Sequence Undo Stacks & History Filtering

**Feature Branch**: `006-per-sequence-undo`  
**Created**: 2026-04-05  
**Status**: Draft  
**Input**: User description: "Per-sequence undo stacks and history filtering"

---

## User Scenarios & Testing

### Primary User Story

Each sequence has its own undo cursor. There is also a global cursor for project-level commands (Import, CreateSequence, DeleteSequence). The history panel shows the active sequence's commands plus project-level commands, merged and sorted by time. Undo/redo within a sequence walks only that sequence's cursor. Global commands are also undoable from within a sequence — the global cursor moves — but only if the cascade gate allows it (no dependent clips in other sequences). When a global command is undone, it appears at the current position in all other sequences' history views (the undo happened now, not at the original timestamp).

### Acceptance Scenarios

1. **Given** two sequences A and B with interleaved commands, **When** viewing sequence A, **Then** the history panel shows project-level commands + A's commands sorted by time (B's commands are hidden).

2. **Given** viewing sequence A, **When** the user switches to sequence B, **Then** the history replaces A's commands with B's commands. Project-level commands stay visible, positioned by their timestamps.

3. **Given** viewing sequence A with 3 edits, **When** the user presses Undo 3 times, **Then** all 3 sequence edits are undone (A's cursor moves back). A 4th Undo hits a global command -- the cascade gate validates it before proceeding.

4. **Given** viewing sequence A, **When** the user undoes all of A's commands, **Then** `can_undo()` returns false if the next global command is CreateSequence for A (cannot undo the creation of the active sequence).

5. **Given** viewing A, user undoes Edit_A1 then undoes Import (global). **When** user switches to B, **Then** B's history shows Import as undone at the current time position (top of history), not at its original chronological position. The act of undoing happened now.

6. **Given** an Import that B's clips depend on, **When** user tries to undo Import from A, **Then** the cascade gate fires: "Undoing this import will remove clips in Sequence B. Proceed?" If the user says no, undo stops.

7. **Given** an Import that B's clips do NOT depend on, **When** user undoes Import from A, **Then** Import is undone. B sees it as undone at the top of its history. No clips affected in B.

8. **Given** an interleaved history [Import, Edit(A), Edit(B), Edit(A)], **When** viewing A and undoing, **Then** the undo order is Edit(A)#2, Edit(A)#1 -- Edit(B) is skipped entirely (B's cursor untouched).

9. **Given** the same history, **When** viewing A, undoing both A edits, then redoing, **Then** redo replays Edit(A)#1 first (not Edit(B)).

10. **Given** a sequence is deleted via DeleteSequence, **Then** its commands remain in the database. They are hidden (deleted sequence is not active) but preserved for restoration via undo of the delete.

11. **Given** a deleted sequence, **When** the user branches away (does something new making DeleteSequence unreachable via redo), **Then** the deleted sequence's commands are orphaned on the old branch. Normal branch mechanics -- no special handling.

12. **Given** a command that touches two sequences (e.g., drag clip from A to B), **Then** it is one atomic command. Undoing from either sequence undoes both sides.

### Edge Cases

- Redo from B of a global command undone from A: B's merged view shows the undone global command at the top. Redo replays it, global cursor moves forward. Switching to A, A sees the global command as redone.
- Per-sequence redo branches are independent: doing something new in A doesn't affect B's redo state.
- CreateSequence for the active sequence: always a boundary. `can_undo()` returns false.
- No active sequence (project browser only): undo walks only the global cursor — project-level commands only. Sequence commands are invisible and untouched.
- History panel "current position" indicator: the most recent done command in the merged view (regardless of which cursor owns it).

---

## Requirements

### Functional Requirements

- **FR-001**: Each command MUST store the sequence_id it belongs to. The sequence_id is derived from the command's arguments (the sequence_id parameter). Commands whose args contain no sequence_id are project-level (NULL). Commands that CREATE or DELETE a sequence are project-level despite having a sequence_id in their args — the sequence_id identifies the target, not the context.
- **FR-002**: Each sequence MUST have its own undo cursor AND its own branch tracking, independent of other sequences. A new command in sequence A forks A's branch only — B's redo path is preserved.
- **FR-003**: There MUST be a global cursor for project-level commands, independent of per-sequence cursors.
- **FR-004**: `undo()` MUST walk the merged view (sequence + global commands) strictly by timestamp, undoing whichever happened most recently. Sequence commands move the sequence cursor; global commands move the global cursor (subject to cascade gate).
- **FR-005**: `redo()` MUST walk the merged view (sequence + global commands) strictly by timestamp, symmetric with undo. Sequence commands move the sequence cursor; global commands move the global cursor.
- **FR-006**: `can_undo()` MUST return false when the next command for the active sequence is CreateSequence for that same sequence.
- **FR-007**: Undoing a global command MUST trigger existing cascade/dependency gates (e.g., "this will remove clips in other sequences").
- **FR-008**: When a global command is undone or redone from a sequence context, it MUST be rebased to the current wall-clock time in all history views. It does not return to its original chronological position on redo — it stays at its new position. This is rebase semantics: the action happened NOW in this context.
- **FR-009**: The history panel MUST display project-level commands plus the active sequence's commands, sorted by time.
- **FR-010**: Switching the active sequence MUST update the history panel with the new sequence's commands while preserving project-level commands.
- **FR-011**: DeleteSequence MUST NOT delete the sequence's commands. They remain on their branch and are orphaned only through normal branch mechanics.
- **FR-012**: Cross-sequence commands MUST be tagged with both sequence_ids and appear in both sequences' history views. When undone from either sequence, the command is removed from the flow of BOTH sequences (rebased out) without losing subsequent commands on either side. Subsequent commands on both sequences remain valid — this is rebase semantics, not cascade undo.
- **FR-013**: The `JVE_ENABLE_MULTI_STACK_UNDO` environment gate MUST be removed -- per-sequence undo becomes the default.
- **FR-014**: Existing commands MUST be migrated -- assigned a sequence_id based on their content, or marked project-level (NULL).

### Key Entities

- **Command**: A recorded action. Has one or more `sequence_id` associations (NULL = project-level). Most commands belong to one sequence. Cross-sequence commands belong to two. CreateSequence/DeleteSequence are project-level despite referencing a sequence.
- **Sequence Cursor**: Per-sequence position tracking which of that sequence's commands are done vs undone. Independent of other cursors.
- **Global Cursor**: Position tracking which project-level commands are done vs undone. Shared across all sequences. Moved when a global command is undone/redone from any sequence.
- **Cascade Gate**: Existing validation that checks for dependent clips before destructive operations. Applied when undoing global commands that may affect other sequences.
- **History View**: Merged display of project-level + active sequence commands. Global commands undone from other contexts appear at their undo timestamp.

---

## Clarifications

### Session 2026-04-05

- Q: When undo walks the merged view, how does it decide whether the next command is sequence or global? → A: Strictly by timestamp — whichever happened most recently goes first.
- Q: Are redo branches per-sequence or globally shared? → A: Per-sequence — new command in A forks A's branch only, B's redo path is preserved.
- Q: Which command types are project-level? → A: Derived — any command whose args don't contain a sequence_id is project-level.
- Q: When no sequence is active, what can the user undo? → A: Only project-level commands (global cursor only).
- Q: How are cross-sequence commands tagged? → A: Tagged with BOTH sequence_ids — appears in both histories, undone atomically from either.
- Q: Is CreateSequence project-level or sequence-level? → A: Project-level. It creates a sequence — it can't be inside the sequence. The sequence_id in its args is the target, not the context.
- Q: Cross-sequence undo vs independent branches? → A: Rebase semantics — undoing removes the command from both sequences' flows without losing subsequent commands on either side.
- Q: Should redo also walk merged-by-timestamp? → A: Yes, symmetric with undo.
- Q: What does "current time position" mean for rebased commands? → A: Wall-clock time of the undo/redo. Commands stay at their new position on redo — they don't return to original position. Rebase semantics.

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
- [x] Ambiguities marked and resolved
- [x] User scenarios defined
- [x] Requirements generated
- [x] Entities identified
- [x] Review checklist passed
