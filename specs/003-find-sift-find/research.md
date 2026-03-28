# Research: Find, Sift, Find & Replace, and Timeline Search

**Feature**: 003-find-sift-find
**Date**: 2026-03-26

## NLE Industry Research

### Decision: Compositional Sift over Boolean Query Builder
- **Chosen**: Sequential composition — Sift (fresh), Expand Sift (OR), Narrow Sift (AND), Clear Sift
- **Rationale**: No NLE exposes AND/OR syntax. Apple/Resolve use "Match All/Any" toggle. Avid uses separate Find (select) vs Sift (filter) operations. Sequential composition is more intuitive for editors — each step is visible before refining further.
- **Alternatives considered**: Boolean query builder (too complex for editors), Match All/Any toggle (less flexible than expand/narrow), modifier keys only (not discoverable)

### Decision: Expand/Narrow Terminology
- **Chosen**: "Expand Sift" (OR) and "Narrow Sift" (AND)
- **Rationale**: "Expand" clearly means "show more things", "Narrow" means "show fewer things". No boolean literacy required. Short enough for menu items and buttons.
- **Alternatives considered**: "Sift More/Less" (ambiguous), "Also Matching/All Matching" (Apple-style but verbose), "Add to Sift/Refine Sift" (verbose)

### Decision: Shared Query Engine
- **Chosen**: One query engine powering Find (select), Sift (filter), Smart Bins (membership), Timeline Index (filter)
- **Rationale**: Avid's Find and Sift share the same query mechanism — difference is only result action. Reduces code, ensures consistent behavior.
- **Alternatives considered**: Separate implementations per feature (more code, inconsistency risk)

### Decision: Timeline Index as Floating Dialog
- **Chosen**: Floating dialog window, becoming dockable panel later
- **Rationale**: Dockable panel system is TODO. Current 3-panel splitter layout is fragile (squeezed panels bug). Floating dialog has zero layout impact and the index logic is container-agnostic — trivial migration when dockable panels ship.
- **Alternatives considered**: Tab in timeline panel (can't see both), tab in browser panel (semantically wrong), dedicated panel slot (layout system can't handle it yet)

### Decision: User-Selectable Scope Switches
- **Chosen**: Prominent scope selector in Find, Find & Replace, and Smart Bin dialogs (like Finder search scope bar)
- **Rationale**: User may want to search all clips or only sifted/selected clips. Making it a visible switch avoids hidden behavior and matches Finder UX patterns editors already know.
- **Alternatives considered**: Fixed scope per operation (too inflexible), separate commands per scope (too many commands)

## Technical Research

### Persistence: Sift State
- **Decision**: Persist sift criteria with the project file
- **Rationale**: JVE principle — maintain identical state across sessions. Editor reopens project and sees the same sifted view.
- **Mechanism**: `projects.settings` JSON column already stores `browser_sort_*` preferences. Sift criteria follow same pattern. Smart Bins get their own table in schema.sql (no backward compat, no `IF NOT EXISTS`).
- **Alternatives**: Session-only (Avid's approach) — rejected because JVE values session continuity.

### Persistence: Dialog Settings
- **Decision**: All dialogs in this feature persist their settings (FR-025b)
- **Rationale**: ENGINEERING.md rule 1.6 — "MANDATORY universal state persistence"
- **Mechanism**: Existing `~/.jve/` prefs pattern or `projects.settings` JSON

### Query Engine: Searchable Fields
- **Decision**: Search clip table columns + properties table + media table metadata
- **Fields available**: name, enabled, offline, volume, fps, duration, codec, resolution, date_modified, plus all custom properties (Scene, Take, Shot, Comments, etc. from metadata_schemas.lua)
- **Read-only exclusions for Replace**: Duration, FPS, Resolution, Date Modified (computed/derived)
- **Editable for Replace**: name, plus all custom properties from properties table

### Command Architecture: Replace All as Batch
- **Decision**: ReplaceAll is a single undoable command that captures all previous values
- **Rationale**: Single Cmd+Z for batch undo. Individual Replace operations are each their own command.
- **Mechanism**: Executor captures `previous_values` array in command params, undoer restores them. Uses `undo_group_id` for batch grouping if needed.

### Keyboard Shortcuts: Context-Aware
- **Decision**: Cmd+F dispatches to Find in whichever panel is focused (project_browser vs timeline)
- **Mechanism**: `@project_browser` and `@timeline` context suffixes in `default.jvekeys`. Or: single "Find" command that checks `focus_manager` for current panel context.
- **Conflict resolved**: GoToTimecode moved from Cmd+G to Ctrl+G (Meta on macOS). Cmd+G freed for Find Next (universal standard).

### Smart Bins: Storage
- **Decision**: New `smart_bins` table in schema
- **Rationale**: Smart Bins are first-class persistent entities with name, criteria, scope. They don't fit in project_settings JSON (potentially many, each with structured criteria). Tag system already has bins — Smart Bins need to appear alongside regular bins in the browser tree.
- **Schema**: `smart_bins(id, project_id, name, scope_bin_id, criteria_json, created_at, modified_at)`

### Tag System Integration
- **Decision**: Smart Bins appear in browser tree alongside regular bins but with distinct icon
- **Rationale**: tag_service.lua manages bin hierarchy. Smart Bins are virtual — they don't own clips via tag_assignments but dynamically resolve membership via query criteria. They should appear in the same tree but behave differently (no drag-into, no manual assignment).
