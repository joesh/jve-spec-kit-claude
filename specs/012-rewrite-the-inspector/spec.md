# Feature Specification: Inspector Panel Rewrite

**Feature Branch**: `012-rewrite-the-inspector`
**Created**: 2026-04-19
**Status**: Draft
**Input**: Rewrite the Inspector panel to comply with ENGINEERING.md and CLAUDE.md MVC rules. Preserve current user-visible behavior; eliminate dead code, duplicate implementations, and rule violations uncovered in audit.

---

## Clarifications

### Session 2026-04-19 (Part 3)
- Q: What happens when an inspectable disappears from the model while the Inspector is displaying it (clip deleted, sequence closed, underlying row gone)? → A: Not a special case. Deletions flow through the selection hub: a group of 5 becomes a group of 4 or 0 via a normal selection-change notification. The Inspector reacts via its standard selection-change path. Upstream commands that delete items are responsible for emitting the selection change; if the Inspector ever pulls and finds the inspectable absent from the model, that is an upstream-invariant violation and the Inspector asserts (rule 1.14).
- Q: Conflict: external mutation arrives while user is mid-edit on a field? → A: User's in-flight edit wins (last-write-wins). "In-flight" is defined as the widget being **dirty** (typed content differs from the value set by the most recent pull or commit), not merely having focus. Dirty fields skip pull-on-notify refresh; non-dirty fields (including focused-but-not-typed) refresh normally. On commit or blur the dirty flag clears and subsequent notifications refresh the field. A user commit overwrites any intervening external mutation to the same field — this is consistent with principle-of-least-amazement for text inputs.
- Q: Invalid-input field state (what the widget shows between a rejected commit and the next refresh)? → A: Keep the bad text visible with a red/error border; no commit; blur reverts to the model value. Standard form-validation pattern (aligns with rule 3.5). Refinements: (1) blur-reverts, not blur-preserves — otherwise invalid state accumulates silently across sections; (2) in multi-edit, the Apply button is disabled until all pending dirty fields parse successfully.

### Session 2026-04-19 (Part 2)
- Q: Scope for properties that don't exist on clip/sequence today (Video Transform, Composite, Crop, Retime, Audio volume/pan/channels)? → A: Inspector renders only properties that round-trip through a real consumer today. Resolve-style sections for non-existent properties are deferred to the features that add those properties. This feature is strictly an Inspector rewrite.
- Q: What happens to existing property-editing UIs elsewhere in the codebase (e.g., `clip_audio_inspector.lua`, project-browser metadata popups, timeline right-click panels)? → A: Audit + classify. `/plan` research enumerates every UI that currently edits clip or sequence properties. Each is classified as either (1) schema-driven form editing (text field / dropdown / checkbox — the kind the Inspector renders in tabular form) → migrate into the new Inspector schema and delete the old UI; or (2) specialized tool surface (channel mapper, color picker, scope viewer, waveform zoom, keyframe curve editor) → keep as a dedicated coexisting surface. The Inspector row for the same property may act as a simple scalar edit while the specialized tool provides the richer interaction. FR-023's "single place" is thereby reframed: the Inspector is the single place for schema-driven form editing of properties; specialized tool surfaces are a different interaction modality, not duplicates.
- Q: How are inherently non-editable properties (file path, codec, raw duration, etc.) rendered? → A: A `read_only` flag on the field definition (not a new field type). Any existing field type can be marked read-only; the Inspector renders the value, disables the widget, and skips the commit path. No separate LABEL field type.
- Q: Section collapse/expand state persistence? → A: Persist per schema across sessions via the existing PersistentWidget mechanism (rule 1.6). Matches Resolve's behavior. Not per-clip, not ephemeral.
- Q: Test strategy? → A: Both layers. Pure Lua unit tests (Qt stubs) for decomposable pure logic (filter matching, majority-schema computation with tiebreak stability, mixed-value detection, timecode formatting, pending-edit discard). AND `--test` mode integration tests for every Acceptance Scenario in this spec (1:1 between Scenario and `--test` script). Integration suite is the authority on "behavior preserved." Aligns with rules 2.32, 2.34, and the project's established `--test` pattern.

### Session 2026-04-19
- Q: Of the eight existing clip-schema sections, which should the rewritten Inspector render? → A: Model the section set after DaVinci Resolve's Inspector, plus clip properties. The Inspector is the one-stop-shop for all property handling.
- Q: Widget pool strategy? → A: Flatten. Create all widgets per-schema once at construction; show/hide on activation. No rent/return lifecycle. (With only two schemas and one active at a time, pooling reclaims nothing real.)
- Q: TIMECODE property-type boundary? → A: Promote TIMECODE to a distinct property type end-to-end. Payload carries `{value=<int frames>, property_type="TIMECODE"}`. Rate remains single-sourced on the owning entity (sequence.frame_rate or clip.rate), not duplicated into the payload. Consumer dispatches on property_type.
- Q: save-all capability? → A: Collapse. Multi-edit's Apply button is the single implementation of "write all pending fields to all selected items." No separate save-all entry point, no auto-apply on selection change.
- Q: Search scope? → A: Labels and section names only. The Inspector search narrows the *form*, not the *data*. Value-search belongs to the project browser, not here.
- Q: Heterogeneous selection (clip + sequence mixed)? → A: Primary-schema-wins. Active schema = majority of selected items; ties broken by the most-recently-clicked item. Header discloses the split (e.g., "3 clips, 1 sequence — editing 3 clips"). Edits apply only to items of the active schema; items of other schemas are excluded from the edit but counted in the header. The active-schema choice is stable across selection updates that do not change the set of schemas present.

## User Scenarios & Testing *(mandatory)*

### Primary User Story
An editor selects one or more items (a clip or a sequence) in the browser or timeline. The Inspector panel responds by showing a labeled form of metadata fields grouped into collapsible sections. The editor edits a field; the change is applied to the underlying item as an undoable action. When the editor performs undo or redo elsewhere, switches projects, or selects a different item, the Inspector reflects the current state of the project without requiring manual refresh. The editor can narrow what the Inspector shows by typing into a search box, which collapses non-matching sections.

### Acceptance Scenarios

1. **Single clip selection from browser**
   - **Given** a project with at least one master clip and no current selection, **When** the editor selects one master clip in the project browser, **Then** the Inspector shows that clip's name as its header, the clip-schema sections are visible, and each field displays the clip's current value.

2. **Single clip selection from timeline shows mark summary**
   - **Given** a timeline with mark In and mark Out set, **When** the editor selects a timeline clip, **Then** the Inspector header displays the clip name and, on a second line, an In/Out/Duration timecode summary at the sequence frame rate.

3. **Single sequence selection**
   - **Given** a project with a sequence, **When** the editor selects the sequence, **Then** the Inspector shows the sequence-schema sections with the sequence's display name in the header and a mark summary line.

4. **Edit a single field on a single selection**
   - **Given** a clip is selected and displayed in the Inspector, **When** the editor types a new value into a field and commits (blur or Enter), **Then** the underlying clip is updated as a single undoable action and the field widget displays the committed value.

5. **Undo of a field edit round-trips**
   - **Given** a field was just edited, **When** the editor issues undo, **Then** the Inspector field redisplays the previous value without the editor having to re-select the item.

6. **Redo of a field edit round-trips**
   - **Given** a field edit was just undone, **When** the editor issues redo, **Then** the Inspector field redisplays the edited value.

7. **Multi-select of same-schema items enters multi-edit mode**
   - **Given** two or more items of the same schema are selected and every item supports multi-edit, **When** selection updates, **Then** the Inspector shows an "Apply" button, fields where all selected items share a value display that value, and fields where values differ display a `<mixed>` placeholder.

8. **Apply in multi-edit commits changes to every selected item**
   - **Given** the Inspector is in multi-edit mode with pending edits on one or more fields, **When** the editor presses Apply, **Then** every selected item receives the pending value for each edited field, as a single undoable group.

9. **Mixed-schema selection edits the majority schema**
   - **Given** a selection containing three clips and one sequence, **When** selection updates, **Then** the Inspector activates the clip schema (majority), the header reads "3 clips, 1 sequence — editing 3 clips", and edits apply only to the three clips. The sequence is not edited.

10. **Multi-select where at least one item does not support multi-edit**
    - **Given** a multi-selection where one or more items report they do not support multi-edit, **When** selection updates, **Then** the Inspector displays the first item's data in read-only form with a header indicating the selection is read-only, and no Apply button is shown.

11. **Search narrows visible sections**
    - **Given** an active selection with multiple sections, **When** the editor types text in the search box, **Then** only sections whose name or whose fields' labels contain the query (case-insensitive substring) remain visible; clearing the search restores all sections.

12. **Project change clears the Inspector**
    - **Given** an Inspector showing fields for an item in project A, **When** the user opens project B, **Then** the Inspector clears its state and shows the empty / no-selection label.

13. **External content change refreshes displayed values**
    - **Given** an Inspector showing a clip, **When** another subsystem mutates that clip (including via undo/redo of a non-Inspector command on the same sequence), **Then** the Inspector's field widgets update to the new values without user interaction.

14. **Selection originating from the Inspector itself does not recurse**
    - **Given** the Inspector is the source of a selection event, **When** that event is dispatched, **Then** the Inspector does not re-process its own selection change.

### Edge Cases
- Field commit while the focused field is empty: the commit is treated as "no change" for that field (empty string is not written for numeric or timecode fields).
- Invalid timecode (or other invalid parse) typed into a field and committed: the field keeps the bad text visible with an error border, no write to the model, Apply disabled in multi-edit. On blur the field reverts to the model value and the error indicator clears.
- Selection changes while an edit is in flight (typed but not committed): the pending edit is discarded when selection changes.
- Displayed inspectable is deleted from the model: the deleting command MUST emit a selection-change; the Inspector reacts via its normal selection-change path (a 5-item selection becomes 4 or 0). A pull that finds the inspectable missing is an upstream bug and the Inspector asserts.
- External mutation arrives while a field is dirty (user has typed but not committed): the dirty field retains the user's in-flight text; other fields refresh normally. On commit, the user's value overwrites the external mutation (last-write-wins, no prompt).
- Checkbox in multi-edit with mixed values: resolution per Q5 below.
- Mark In or Mark Out unset: resolution per Q6 below.

---

## Requirements *(mandatory)*

### Functional Requirements

**Display & Selection**
- **FR-001**: Inspector MUST mount into the container supplied by the application's layout module and take no ownership of window-level layout.
- **FR-002**: Inspector MUST receive selection updates only through the application's central selection hub, accepting an item list and the originating panel identifier.
- **FR-003**: Inspector MUST ignore selection events whose originating panel is the Inspector itself.
- **FR-004**: Inspector MUST support exactly two inspectable schemas in this feature: `clip` and `sequence`. Any selected item whose schema is neither is treated as "not editable" for this panel.
- **FR-005**: When the selection is empty, Inspector MUST display the "No editable selection" state and hide all schema sections.
- **FR-005a**: When the selection is heterogeneous (contains items of more than one schema), the Inspector MUST pick a single *active schema* as the majority-schema of the selection, tie-broken by the most recently clicked item. The active-schema choice MUST remain stable across subsequent selection updates that do not change the set of schemas present.
- **FR-005b**: In a heterogeneous selection, the Inspector's header MUST disclose the split (e.g., "3 clips, 1 sequence — editing 3 clips"), and edits MUST apply only to selected items of the active schema. Items of other schemas are counted in the header but excluded from the edit.
- **FR-006**: When a single item is selected, the Inspector header MUST display the item's display name prefixed with its kind (`Clip: <name>` or `Timeline: <name>`).
- **FR-007**: When multiple same-schema items are selected and all support multi-edit, the header MUST display `Clips: <N> selected` or `Timelines: <N> selected`.
- **FR-008**: When multiple same-schema items are selected but at least one does not support multi-edit, the header MUST display `Clips: <N> selected (read-only)` or `Timelines: <N> selected (read-only)`, fields MUST display the first item's values, and the Apply control MUST NOT be shown.

**Fields & Editing**
- **FR-009**: The Inspector MUST render a form whose structure (sections, fields, field types, options, defaults) is defined by the existing schema definitions; the Inspector itself MUST NOT hardcode field lists.
- **FR-010**: The Inspector MUST support the following field types and no others in this feature: STRING, TEXT_AREA, DROPDOWN, INTEGER, DOUBLE, BOOLEAN, TIMECODE.
- **FR-010a**: Each field definition MAY carry a `read_only` flag. When set, the Inspector MUST render the widget for that field in a visually-distinct disabled state, display the current value, and MUST NOT attach commit handlers (no editingFinished, no toggle commit). Read-only fields MUST NOT participate in multi-edit pending state or the Apply path.
- **FR-011**: A single-selection edit MUST commit on widget editingFinished (line edits and text areas) or on toggle (checkbox, dropdown), as a single undoable action tagged as originating in the UI.
- **FR-012**: A committed edit MUST be dispatched through the inspectable's update interface with a payload carrying the value, the inspectable's property type, and the schema-declared default.
- **FR-013**: In multi-edit mode, field edits MUST NOT commit immediately; they MUST be held until the editor presses Apply, at which point all pending edits are applied to every selected item inside a single undoable group tagged as originating in the UI. Apply is the single implementation of "write pending fields to all selected items"; no separate save-all entry point exists.
- **FR-013a**: If the user changes selection while multi-edit has pending (un-Applied) edits, those pending edits are discarded (not auto-applied).
- **FR-014**: In multi-edit mode, fields where the selected items do not all share the same value MUST display a `<mixed>` placeholder until the editor types a value.
- **FR-015**: Invalid input for typed fields (non-numeric for INTEGER/DOUBLE, unparseable timecode for TIMECODE) MUST NOT be written to the model.
- **FR-015a**: When a commit (editingFinished) produces an invalid parse, the field widget MUST remain dirty, continue to display the user's typed text, and display a visually distinct error border. The commit MUST be rejected (no write to the model, no undo event).
- **FR-015b**: When a field with an invalid-parse error state loses focus (blur), the widget MUST revert to the model's current value and the error indicator MUST clear. Invalid state does not persist across focus changes.
- **FR-015c**: In multi-edit mode, if any pending dirty field has invalid-parse state, the Apply button MUST be disabled. Apply re-enables as soon as every dirty field parses successfully.

**Change Notification & Refresh**
- **FR-016**: The Inspector MUST refresh its displayed field values in response to content-change notifications scoped to the sequence(s) containing the current inspectable(s). A single notification channel MUST drive this refresh; no second subscription path is permitted.
- **FR-016a**: A field widget is **dirty** if its content differs from the value set by the most recent pull or commit. On a content-change notification, dirty fields MUST NOT refresh — they retain the user's in-flight typed content. Non-dirty fields (including a focused field the user hasn't typed into) MUST refresh normally. The dirty flag clears on commit (editingFinished, toggle) and on selection change. Subsequent notifications refresh a previously-dirty field once it has been committed or discarded.
- **FR-016b**: When the user commits a dirty field whose model value has been altered by an external mutation since typing began, the commit overwrites the external mutation (last-write-wins). The Inspector MUST NOT prompt the user about the conflict.
- **FR-017**: The Inspector MUST clear all selection and inspectable state on project-change notification.
- **FR-017a**: Disappearance of a displayed inspectable (clip deletion, sequence closure, underlying row removal) is NOT a special-case in the Inspector. The command performing the deletion is responsible for emitting a selection-change through the selection hub that reflects the new selection state (e.g., a 5-item selection becomes 4, or 0). The Inspector reacts via its normal selection-change path.
- **FR-017b**: If the Inspector performs a pull and the target inspectable is absent from the model, this is an upstream-invariant violation (the deleting command failed to emit a selection change). The Inspector MUST assert with context identifying the missing inspectable and the operation; it MUST NOT silently soft-clear.

**Selection Label / Mark Summary**
- **FR-018**: When the selection source is the timeline, or when the active schema is `sequence`, the header MUST append a second line showing an In / Out / Duration timecode summary at the sequence frame rate.
  - [NEEDS CLARIFICATION Q6: when mark In or mark Out is not set, show dashes for the missing value and `--` for duration (current behavior), or hide the mark row entirely until both marks are set?]

**Search Filter**
- **FR-019**: The Inspector MUST provide a search input that filters visible schema sections by case-insensitive substring match against section name or any field label.
  - [NEEDS CLARIFICATION Q7: should the search also match against current field values?]
- **FR-020**: When the search input is empty, all schema sections of the active schema MUST be visible.
- **FR-021**: When no schema is active (empty, mixed, or non-editable selection), the search input MUST leave all sections hidden regardless of query.
- **FR-021a**: Each schema section MUST be collapsible/expandable. The collapsed/expanded state MUST be persisted **per schema** **across sessions** using the existing PersistentWidget mechanism (rule 1.6). State is NOT per-clip and NOT reset on selection change.

**Visual: Mixed Checkbox**
- **FR-022**: For a BOOLEAN field in multi-edit with differing values across the selection, the checkbox MUST display a visually distinguishable mixed state.
  - [NEEDS CLARIFICATION Q5: true tri-state checkbox, or a non-tri-state visual fallback?]

**Schema Coverage**
- **FR-023**: The Inspector is the single place in the application for **schema-driven form editing** of clip and sequence properties (text fields, dropdowns, checkboxes, numeric entries, timecode entries). Specialized tool surfaces (channel mappers, color pickers, scope viewers, waveform zoom, keyframe curve editors) MAY coexist as dedicated surfaces for richer interaction; they are a different interaction modality, not duplicates. Section and field layout MUST be modeled after DaVinci Resolve's Inspector, adapted to this project's clip and sequence properties. Every rendered field MUST round-trip through a real consumer; fields with no consumer MUST NOT appear as Inspector UI.
- **FR-023e**: `/plan` research MUST enumerate every existing UI in the codebase that currently edits clip or sequence properties. Each such UI MUST be classified per FR-023 as either (1) schema-driven form editing → migrate into the new Inspector schema and delete the old UI, or (2) specialized tool surface → keep as a dedicated coexisting surface. The classification, per-UI disposition, and migration plan MUST be recorded in the implementation plan.
- **FR-023a**: The clip schema MUST render exactly the properties that exist on clips today and round-trip through a real consumer (display, audio engine, persistence read by another subsystem, etc.). The target section layout (Resolve-style grouping) describes how those existing properties are organized, not a superset of properties to add. Property sets belonging to features that do not yet exist (e.g., Video Transform, Composite Blend Mode, Cropping, Retime & Scaling, Audio volume/pan/channel-mapping, if absent from the current data model) are OUT OF SCOPE for this feature and MUST NOT appear as Inspector UI.
- **FR-023b**: The sequence schema MUST render exactly the sequence-level properties that exist today and round-trip through a real consumer (frame rate, sequence name, timecode origin, resolution if stored, etc.). No aspirational fields.
- **FR-023c**: Enumeration of the actual properties that meet FR-023a / FR-023b MUST be performed during `/plan` research by auditing the clip, sequence, and media data structures in the codebase, and recorded in the implementation plan. The spec does not pre-declare that set because it depends on current code state, not user intent.
- **FR-023d**: The schema-definition module MAY be restructured to support FR-023/23a/23b, provided the restructured module still only defines fields that round-trip through a real consumer. (This supersedes the earlier non-goal of leaving the schema-definition module structurally unchanged.)

**Engineering Invariants (derived from ENGINEERING.md / CLAUDE.md)**
- **FR-024**: Inspector code MUST NOT swallow UI-binding failures. A failure to create, style, lay out, show, or update a UI element is a broken UI invariant and MUST halt with contextual information (component, field key, operation).
- **FR-025**: Inspector code MUST NOT return fallback values for missing required data (frame rate, schema id, field type, field label, property type). Required data missing is an assertion failure; optional data is explicitly marked optional in the schema definition.
- **FR-026**: The Inspector MUST follow pull-on-notify discipline: on any change notification it queries current model state, rather than depending on imperative push arriving at the right moment. The view never caches a value the model owns.
- **FR-027**: The Inspector MUST expose exactly one public API surface to the layout module and the selection hub. No unused public functions, no legacy aliases, no backward-compatibility shims, no global scratch functions.
- **FR-028**: Field commit and multi-edit apply MUST route through the existing command system so that the resulting mutations are individually undoable (single-edit) or grouped-undoable (multi-edit). The Inspector MUST NOT hold a private undo stack.
- **FR-029**: Visual styling values (colors, font sizes, padding) MUST be sourced from the project's UI constants module; the Inspector MUST NOT embed literal color values inline.

**Housekeeping (negative requirements)**
- **FR-030**: The following MUST be removed, not migrated: the dead inspector adapter module, the dead selection-inspector controller module, the orphaned main-window module that uses stale require paths, the test that exercises only the dead adapter, empty `set_inspector` stubs on timeline and project browser that have no live reader, and any global scratch save helpers.
- **FR-031**: Any public function on the Inspector that is not reachable from live wiring MUST be removed rather than preserved for hypothetical future callers.

**Testing (acceptance gate)**
- **FR-032**: Pure Lua unit tests (running against Qt stubs) MUST cover every decomposable pure function added or modified by this feature: schema filter matching (label and section-name substring), majority-schema computation with last-clicked tiebreak and stability across non-schema-changing updates, mixed-value detection across N inspectables, timecode formatting and parsing at the field boundary, pending-edit discard semantics on selection change, read-only commit suppression.
- **FR-033**: Every Acceptance Scenario listed in this spec MUST have a corresponding `./build/bin/JVEEditor --test <script>` integration test. The integration suite MUST pass as the gate on "behavior preserved." A 1:1 map between Acceptance Scenario number and integration test file MUST be recorded in the implementation plan.

### Out of Scope (Non-Goals)
- No new field types beyond the seven listed.
- No new inspectable schemas beyond `clip` and `sequence`.
- No changes to the selection hub, command manager, or inspectable factory. (The schema-definition module is in-scope for restructure per FR-023d.)
- No new clip or sequence properties. Properties that do not exist in the current data model are out of scope; they are added by whichever feature introduces the corresponding consumer (e.g., a future Transform feature adds the Transform properties and their Inspector rows together).
- No layout changes outside the Inspector panel's own container.
- The widget pool module is removed. All per-schema widgets are constructed once and shown/hidden; there is no rent/return lifecycle. (Resolves Q2.)

### Key Entities

- **Inspectable**: An entity the Inspector can display and edit. Has a schema identifier (`clip` or `sequence`), a display name, and an update capability that routes through the command system. Reports whether it supports multi-edit.
- **Schema**: A declarative description of sections and fields for one inspectable kind. Each field declares a key, label, field type, default, and (for DROPDOWN) options.
- **Selection**: A list of inspectables plus a source-panel identifier. Selection of size 0, 1, or N is meaningful; the Inspector responds differently to each.
- **Field Widget**: The on-screen control bound to one field. Carries value read/write, mixed-state presentation, and placeholder handling.
- **Property Type**: The classification the Inspector hands to the inspectable's update interface alongside a value. Set: `STRING`, `NUMBER`, `BOOLEAN`, `ENUM`, `TIMECODE`. `TIMECODE` values are integer frame counts; the owning entity's frame rate (sequence.frame_rate or clip.rate) is authoritative — rate is never carried inside the payload.
- **Content Change Notification**: A single signal carrying the sequence identifier whose contents changed, used by the Inspector to decide whether to re-pull the current inspectable.
- **Project Change Notification**: A signal that causes the Inspector to clear all state.

### Open Clarifications
- ~~Q1 (FR-023 / schema coverage)~~ — **Resolved 2026-04-19**: model after DaVinci Resolve's Inspector plus this project's clip/sequence properties. The Inspector becomes the sole location for property handling. Schema module is in-scope for restructure.
- ~~Q2 (widget pool)~~ — **Resolved 2026-04-19**: flattened. Delete `widget_pool.lua`; create widgets per-schema once, show/hide on activation.
- ~~Q3 (property type)~~ — **Resolved 2026-04-19**: TIMECODE is a distinct property type end-to-end. Payload `{value=<int frames>, property_type="TIMECODE"}`. Rate stays on the owning entity, never in the payload.
- ~~Q4 (save-all)~~ — **Resolved 2026-04-19**: collapse save-all and multi-edit Apply into one implementation. Selection change discards pending un-Applied edits (FR-013a).
- ~~Q7 (search scope)~~ — **Resolved 2026-04-19**: labels and section names only. Value-search is out of scope for the Inspector; belongs to the project browser.
- ~~Q-Hetero (heterogeneous selection, raised in Session 2026-04-19)~~ — **Resolved**: majority-schema-wins with last-clicked tiebreak; header discloses the split; edits apply only to the active-schema subset (FR-005a, FR-005b).
- **Q5 (FR-022)** — **Deferred to /plan**: tri-state checkbox vs non-tri-state visual fallback for mixed BOOLEAN. Low architectural impact; resolve at implementation.
- **Q6 (FR-018)** — **Deferred to /plan**: when mark In/Out is unset, show dashes or hide the mark row. Low architectural impact; resolve at implementation.

---

## Review & Acceptance Checklist
*GATE: Automated checks run during main() execution*

### Content Quality
- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

### Requirement Completeness
- [ ] No [NEEDS CLARIFICATION] markers remain. Part 1 resolved: Q1–Q4, Q7, Q-Hetero. Part 2 resolved: property-existence scope, UI migration & classification, read-only flag, section persistence, test strategy. Deferred to `/plan`: Q5 (tri-state checkbox), Q6 (mark-row display when unset).
- [x] Requirements are testable and unambiguous (where clarified)
- [x] Success criteria are measurable
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

---

## Execution Status
*Updated by main() during processing*

- [x] User description parsed
- [x] Key concepts extracted
- [x] Ambiguities marked
- [x] User scenarios defined
- [x] Requirements generated
- [x] Entities identified
- [ ] Review checklist passed (blocked on Q1–Q7)

---
