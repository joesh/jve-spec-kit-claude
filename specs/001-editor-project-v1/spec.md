# Feature Specification: Video Editor M1 Foundation

**Feature Branch**: `001-editor-project-v1`  
**Created**: 2025-09-26  
**Status**: Draft  
**Input**: User description: "Editor Project v1.2 — M1 Backlog (Editor-First Rewrite) - Ship a usable editor skeleton that demonstrates the model–UI loop with Project Browser, Timeline, and Inspector/Metadata panels"

## User Scenarios & Testing

### Primary User Story
Video editors and post-production teams need freedom from monolithic, proprietary editing tools that can't be customized or extended. They want a hackable, script-forward editing platform (like Emacs for video) where they can rapidly prototype new workflows, collaborate in real-time without vendor limitations, and maintain full control over their tools and data through an extensible Lua/C++ architecture.

For M1, users need a usable editor skeleton that demonstrates the core model-UI loop: browse assets and sequences, place and edit clips on a timeline, select clips and edit their properties and metadata through a unified Inspector panel, with projects that save and load as a single file.

### Acceptance Scenarios
1. **Given** the editor is launched, **When** a user opens the application, **Then** Project Browser, Timeline, Inspector, and Viewers are all visible and functional
2. **Given** a user creates a sequence, **When** they add clip references and place clips on the timeline, **Then** clips appear correctly on tracks with proper layout
3. **Given** a clip is selected on the timeline, **When** user views the Inspector panel, **Then** Properties tab shows clip instance settings and Metadata tab shows source media information
4. **Given** user performs editing operations (split, ripple delete, roll), **When** commands are executed, **Then** timeline updates reflect changes with proper sync badges and deterministic behavior
5. **Given** user has made edits to a project, **When** they save, quit, and reopen, **Then** identical state and selection are restored from the single project file
6. **Given** user switches between Properties and Metadata tabs in Inspector, **When** editing values, **Then** changes are saved and tab state is preserved
7. **Given** multiple clips are selected, **When** user views Inspector, **Then** controls show indeterminate state for mixed values and allow setting values across all selected clips

### Edge Cases
- What happens when user attempts to delete referenced media from Project Browser?
- How does the system handle invalid property edits with schema validation?
- What occurs when ripple operations create out-of-sync badges?
- How are command replays handled when reopening projects with complex edit histories?

## Requirements

### Functional Requirements
- **FR-001**: System MUST provide a unified data model with SQLite persistence for projects, sequences, tracks, clips, properties, and metadata
- **FR-002**: System MUST display Project Browser panel for managing assets and sequences with create/rename/delete operations
- **FR-003**: System MUST provide Timeline panel with multi-track layout, clip selection, and snapping toggle functionality
- **FR-004**: System MUST provide unified Inspector panel with Properties and Metadata tabs with state preservation between tabs
- **FR-005**: Properties tab MUST display clip instance settings (speed, color, effects) with inline validation and per-property undo
- **FR-006**: Metadata tab MUST display source media information (camera settings, keywords, scene data) with editing capability and per-property undo
- **FR-007**: Inspector MUST support multi-selection with tri-state controls (indeterminate/mixed values, set values across group, per-property undo for group operations)
- **FR-008**: System MUST display Record/Timeline and Source Viewers with timecode overlays (non-playing for M1)
- **FR-009**: System MUST support core editing commands: create, delete, split (add edit), ripple delete, ripple trim, and roll
- **FR-010**: System MUST use deterministic command API with `apply_command(cmd,args) → delta|error` pattern
- **FR-011**: System MUST provide atomic save/load operations to single .jve project files
- **FR-012**: System MUST replay command sequences to identical post-hash states for deterministic behavior
- **FR-013**: System MUST display sync badges when ripple operations override linked audio/video
- **FR-014**: System MUST support keyboard shortcuts for playhead control (J,K,L for backward/stop/forward) and editing commands (Cmd+B for blade)
- **FR-015**: Timeline MUST support edge selection for ripple trim and roll operations with Cmd+click to add/remove additional edges, following Avid/FCP7/Resolve patterns

### Key Entities
- **Project**: Single-file container (.jve) with SQLite schema for all editing session data
- **Sequence**: Timeline container with tracks and clips, selectable in Project Browser
- **Track**: Container for clips with video/audio designation and targeting behavior
- **Clip**: Media reference with timeline position, properties, and sync state
- **Command**: Logged editing operation with deterministic replay capability and inverse deltas
- **Property**: Schema-driven clip attribute with validation rules and undo history
- **Metadata**: Source media information (camera settings, keywords, scene data) editable through Inspector Metadata tab
- **Viewer**: Display panel (Record/Timeline or Source) with timecode overlays and safe guides
- **Selection**: Current clip/edge focus that drives Inspector content and editing targets, supports multi-selection of clips and edges with tri-state control behavior and Cmd+click patterns

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
- [x] Review checklist passed

---