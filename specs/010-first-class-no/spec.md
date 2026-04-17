# Feature Specification: No Active Sequence State

**Feature Branch**: `010-first-class-no`
**Created**: 2026-04-16
**Status**: Draft
**Input**: User description: "First-class 'no active sequence' state for the timeline panel. Close last tab leaves timeline blank. Open project with no saved tab info starts blank. Drop find_most_recent and sequences[1] fallbacks. DRP importer resolver asserts on malformed TimelineHandleVec. Persist open_sequence_ids as []."

---

## Clarifications

### Session 2026-04-16
- Q: Which drop sources are accepted onto a blank timeline? → A: Anything droppable — single clip, multi-select (all into one new sequence), bins recursed, sequences opened as tabs
- Q: Where do the new sequence's fps/resolution come from on drop-to-create? → A: Adapt to the first dropped clip; fall back to project defaults only if the clip has no usable metadata
- Q: What happens when the user deletes the last remaining sequence while it is the active tab? → A: The tab closes and the editor enters the blank state (same as manually closing the last tab)
- Q: What happens to a non-active tab when its sequence is deleted from the browser? → A: The non-active tab silently closes; the active tab is unchanged; per-sequence undo history is not eagerly discarded (so undoing the delete restores both the sequence and its tab)
- Q: How is the auto-created sequence named on drop-to-blank? → A: Use the first dropped clip's name; if more than one clip was added, append "(+N more)" where N is the count of additional clips (e.g., `A001_C001.mov (+3 more)`). A single-clip drop uses the clip name verbatim with no suffix.

---

## User Scenarios & Testing *(mandatory)*

### Primary User Story
An editor user is working on a project with multiple open sequence tabs. They finish with every sequence and close the last tab. The timeline panel shows a blank state — no ghost content from the previously active sequence, no automatic opening of an arbitrary other sequence. The user can then open a sequence from the project browser, create a new sequence, or close the project entirely. Re-opening the project later restores the blank state because the user did not leave any tabs open.

A complementary scenario: the user imports a Resolve DRP archive that was exported without any saved tab workspace. On open, the editor shows a blank timeline and waits for the user to pick a sequence — rather than silently opening whichever sequence happens to sort first.

### Acceptance Scenarios

1. **Given** a project open with exactly one sequence tab in the timeline panel, **When** the user clicks the tab's close button, **Then** the tab disappears, the timeline becomes blank, and the project stays open.

2. **Given** the blank state after closing the last tab, **When** the user double-clicks a sequence in the project browser, **Then** that sequence opens as the only tab and the blank state is replaced.

3. **Given** a project that was last saved with the blank state (no tabs open), **When** the user re-opens the project, **Then** the timeline is blank on load (no automatic sequence selection).

4. **Given** a fresh project import from a DRP file that contains tab/workspace metadata, **When** the import completes, **Then** the saved tabs are restored and the recorded active tab is focused — unchanged from existing behavior.

5. **Given** a DRP file with no tab/workspace metadata at all (neither the newer tab-list blob nor the older handle-vec list is present or non-empty), **When** the import completes, **Then** the project opens in the blank state rather than auto-selecting a sequence.

6. **Given** a DRP file whose handle-vec references a sequence identifier that cannot be resolved (out-of-range index, or the referenced timeline has no corresponding sequence record in the media pool), **When** the import runs, **Then** the import fails loudly with an actionable error identifying the bad reference, rather than silently producing an arbitrary active sequence.

### Edge Cases

- When the blank state is active, menu items and keyboard shortcuts that target "the current sequence" (play, JKL, mark in/out, cut, paste, etc.) are disabled / greyed out. Invoking a disabled shortcut is a silent no-op. Once any sequence becomes active, the same commands re-enable.
- When the blank state is active and the user drops items from the project browser onto the timeline area, the behavior depends on what was dropped:
  - **One or more media clips (including multi-select):** a new sequence is created (with frame rate and resolution inherited from the first dropped clip's metadata; falling back to the project's default sequence settings only if the clip has no usable metadata) and all dropped clips are placed into it. The new sequence is named after the first clip placed into it (plus `(+N more)` if any additional clips were added). The new sequence becomes the active tab.
  - **A bin/folder:** the drop is treated as dropping every media clip contained in the bin recursively (same result as the multi-clip case above).
  - **An existing sequence:** that sequence opens as a tab and becomes active — no new sequence is created.
  - **A mixed drop:** sequences open as tabs; remaining clips + bins produce one new sequence containing them all; the last of these to be activated becomes the active tab.
- When the blank state is active and the user invokes undo/redo, the editor falls through to the project-level undo stack (project-scoped actions such as sequence creation, deletion, rename, and bin/folder operations). Per-sequence actions are unreachable in this state because no sequence is active; they become available again once any sequence is opened.
- Projects that have zero sequences at all (for example, a brand-new project right after creation, before the first sequence is made) must open in the blank state without error.
- Projects whose most recently active sequence has since been deleted must open in the blank state rather than resurrecting a stale reference.
- Deleting the last remaining sequence from the project browser while that sequence is the active timeline tab MUST close the tab and enter the blank state (behaviorally identical to the user manually closing the last tab).
- Closing the last tab must persist the blank state to the project immediately, so an app crash right after does not cause the next session to re-open a phantom sequence.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The timeline panel MUST support a no-active-sequence state, visually blank, with no ghost content from any previously loaded sequence.

- **FR-002**: The user MUST be able to close the last remaining sequence tab. The close action MUST succeed and leave the project in the no-active-sequence state.

- **FR-003**: When the project is in the no-active-sequence state, that state MUST be persisted so that re-opening the project restores the blank state without automatic sequence selection.

- **FR-004**: On project open, if the persisted tab state indicates no open sequences (empty list, and no last-active pointer), the editor MUST open in the no-active-sequence state. It MUST NOT fall back to the most-recently-modified sequence or the first sequence in the list.

- **FR-005**: The DRP importer MUST preserve existing behavior when the DRP file contains either form of saved tab metadata. The imported project MUST open with those tabs restored and the recorded active tab focused.

- **FR-006**: The DRP importer MUST produce the no-active-sequence state on open when the DRP file contains no tab metadata at all. It MUST NOT invent a sequence to activate.

- **FR-007**: The DRP importer MUST fail the import loudly — with an error that names the offending reference — when the DRP file contains tab metadata that is internally inconsistent (handle-vec index out of range, or a referenced timeline has no matching sequence record).

- **FR-008**: Commands and keyboard shortcuts that operate on the current sequence MUST be disabled (greyed out in menus; invoking the shortcut is a silent no-op) when the no-active-sequence state is active. They MUST re-enable automatically once any sequence becomes active. They MUST NOT crash, corrupt state, or produce asserts.

- **FR-011**: When the timeline is in the no-active-sequence state and the user drops items from the project browser onto the timeline area, the editor MUST:
  - open each dropped existing sequence as a tab (without creating a new sequence);
  - collect all dropped media clips and all clips found by recursing into dropped bins/folders, and if any such clips exist, create one new sequence with frame rate and resolution inherited from the first dropped clip's metadata (falling back to the project's default sequence settings only if the clip has no usable metadata), place those clips into it, and open it as a tab;
  - name the new sequence after the first clip placed into it — exactly the clip's name if only one clip was added, or `<first-clip-name> (+N more)` where N is the count of additional clips (e.g., `A001_C001.mov (+3 more)` for a 4-clip drop);
  - leave exactly one tab active after the operation (the last one activated during the drop).

- **FR-012**: When the timeline is in the no-active-sequence state, undo/redo MUST operate on a project-level stack (project-scoped actions such as sequence create/delete/rename and bin operations). Per-sequence actions are unreachable while no sequence is active and MUST become available again as soon as a sequence is opened.

- **FR-013**: Deleting the last remaining sequence from the project browser while that sequence is the active timeline tab MUST transition the editor into the no-active-sequence state — the tab closes, the timeline becomes blank, and the blank state is persisted. The editor MUST NOT auto-create a replacement sequence or keep an orphaned tab visible.

- **FR-014**: Deleting a sequence that is open in a non-active tab MUST silently close that tab. The currently-active tab MUST NOT change. Per-sequence undo history MUST NOT be eagerly discarded, so that undoing the sequence delete restores both the sequence itself and its tab in the same position.

- **FR-009**: Selection-dependent UI (inspector, monitor views, playback transport) MUST render a coherent empty/disabled state when no sequence is active.

- **FR-010**: Transitioning into and out of the no-active-sequence state MUST leave other project-scoped state untouched — open media bins, project browser selection, undo history per surviving sequence, and per-sequence scroll/zoom positions MUST all survive.

### Non-Functional Requirements

- **NFR-001**: The no-active-sequence state MUST be a first-class state the codebase can represent directly, not a sentinel value or a disguised dummy sequence. Any subsystem that queries "current sequence id" must be able to receive an unambiguous "no sequence" answer.

- **NFR-002**: The refactor MUST NOT introduce silent fallbacks (auto-selecting a sequence when none is active). Asserts are acceptable on inconsistent internal state; user-facing paths must produce the no-active-sequence state deliberately.

### Key Entities

- **Project tab state**: The ordered list of sequence tabs the user has open, plus a pointer to which one is active. May be empty (no tabs). Persisted per project.
- **Active sequence reference**: A pointer to the currently-displayed sequence on the timeline. May be null (no-active-sequence state).
- **DRP tab metadata**: Two distinct formats produced by Resolve — a newer tab-list blob that enumerates open tabs plus an active pointer, and an older handle-vec list with a separate current-index. Either, both, or neither may be present in a given DRP file.

---

## Review & Acceptance Checklist

### Content Quality
- [x] No implementation details (languages, frameworks, APIs) — module names from the input are translated into user-visible behaviors in the spec
- [x] Focused on user value and the "what"
- [x] All mandatory sections completed

### Requirement Completeness
- [x] No [NEEDS CLARIFICATION] markers remain — all three resolved (commands grey out, drag creates new sequence, undo falls through to project-level stack)
- [x] Requirements are testable and unambiguous where not marked
- [x] Scope is clearly bounded — timeline panel + importer resolver + project open path
- [x] Dependencies and assumptions identified

---

## Execution Status

- [x] User description parsed
- [x] Key concepts extracted
- [x] Ambiguities marked
- [x] User scenarios defined
- [x] Requirements generated
- [x] Entities identified
- [x] Review checklist passed

---
