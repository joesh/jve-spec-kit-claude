# Feature Specification: Find, Sift, Find & Replace, and Timeline Search

**Feature Branch**: `003-find-sift-find`
**Created**: 2026-03-26
**Status**: Draft
**Input**: User description: "Find, Sift, Find & Replace, and Timeline Search system modeled after Avid/Resolve/Premiere research with compositional Sift (OR/AND through workflow, not syntax), timeline quick find, timeline index panel, and undoable find & replace."

---

## Clarifications

### Session 2026-03-26
- Q: Should sift state persist across sessions? → A: Yes — persist with project, re-applied on reopen. JVE maintains identical state across sessions.
- Q: When sift is active, does Find search visible clips only or all? → A: User-selectable scope switch (prominent in UI, like Finder): "Visible (Sifted)" vs "All Clips". Same pattern for Find & Replace.
- Q: Smart Bin scope — project-wide or parent bin? → A: User chooses at creation, modifiable after. Same scope switch pattern as Find.
- Q: Find & Replace scope — all visible or only selected? → A: User-selectable scope switch: "Selected Clips" vs "All Visible". Defaults to selection if one exists.
- Q: Where does Timeline Index panel live? → A: Floating dialog for now. Becomes dockable panel when dockable panel system ships.
- Q: How are Sift More/Less invoked, and what terminology? → A: All operations are commands (menu + shortcuts + dialog buttons). Terminology: "Sift" (fresh), "Expand Sift" (OR), "Narrow Sift" (AND), "Clear Sift" (show all).
- Q: Should Find/Sift match disabled (muted) clips? → A: No special handling. "Enabled" is just another searchable attribute.

---

## User Scenarios & Testing

### Primary User Story
An editor working with hundreds of clips needs to quickly locate, filter, and batch-rename clips across both the project browser (bins) and the timeline. Today there is no search capability — the editor must visually scan or manually scroll. This feature adds Find (select matches), Sift (hide non-matches), Find & Replace (batch metadata editing), and Timeline Search (locate clips on the timeline by name).

### Acceptance Scenarios

#### Bin Find (Cmd+F)
1. **Given** a project browser with 200+ master clips, **When** user presses Cmd+F, chooses the Name attribute, and types "INT" in the search field with "Contains" operator, **Then** all clips whose name contains "INT" are selected/highlighted in the browser and the view scrolls to the first match.
1.5. **Given** an attribute dropdown chooser, the user may type a regex pattern to narrow the choices shown
2. **Given** an active Find with 5 matches, **When** user presses Cmd+G, **Then** selection advances to the next match and the view scrolls to show it. Wraps to first match after the last.
3. **Given** an active Find with 5 matches, **When** user presses Cmd+Shift+G, **Then** selection moves to the previous match. Wraps to last match before the first.
4. **Given** a Find query with "Begins With" operator and value "A001", **When** searching the Name column, **Then** only clips whose name starts with "A001" are matched (not "XA001" or "BA001").
5. **Given** a Find with no matches, **When** user submits the query, **Then** the system indicates "No matches found" and selection is unchanged.
6. **Given** an open Find dialog, **When** user presses Escape, **Then** the dialog closes and any Find-related selection is cleared, restoring the previous selection state.

#### Bin Sift (Cmd+Shift+F)
7. **Given** a project browser showing 200 clips, **When** user sifts by "Codec Contains ProRes", **Then** only ProRes clips remain visible; all others are hidden. The bin header shows a "(Sifted)" indicator.
8. **Given** an active sift showing 50 ProRes clips, **When** user invokes "Expand Sift" with "Codec Contains DNxHD", **Then** DNxHD clips become visible alongside the ProRes clips (OR composition). The sift indicator updates.
9. **Given** an active sift showing 50 ProRes + 30 DNxHD clips, **When** user invokes "Narrow Sift" with "FPS = 24", **Then** only 24fps clips within the currently visible set remain (AND composition).
10. **Given** an active sift, **When** user invokes "Clear Sift" (Escape or menu/button), **Then** all clips become visible again and the sift indicator is removed.
11. **Given** an active sift hiding 150 clips, **When** user imports new media that matches the sift criteria, **Then** the new clips appear in the sifted view automatically.
12. **Given** an active sift, **When** user performs other operations (rename, delete, relink), **Then** those operations work normally on the visible clips; hidden clips are unaffected but still exist.

#### Timeline Quick Find (Cmd+F when timeline focused)
13. **Given** a timeline with 80 clips across 4 tracks, **When** user presses Cmd+F (timeline focused) chooses the Name attribute, and types “INT” in the search field with “Contains” operator, **Then** a search bar appears, the playhead jumps to the first clip whose name contains “INT”, and that clip is selected.
14. **Given** an active timeline find with 6 matches, **When** user presses Cmd+G, **Then** the playhead advances to the next matching clip and it is selected. The view scrolls to keep the playhead visible.
15. **Given** an active timeline find with 6 matches, **When** user presses Select All, **Then** the playhead remains untouched and all matching clips are selected.
16. **Given** a timeline find with matches on multiple tracks, **When** cycling through matches, **Then** matches are visited in timeline order (by timeline_start position), regardless of track.
17. **Given** a timeline find with no matches, **When** user submits the query, **Then** "No matches found" is indicated and playhead/selection are unchanged.

#### Timeline Index Panel
17. **Given** a timeline with clips, **When** user opens the Timeline Index panel, **Then** a sortable table lists every clip event with columns: #, Clip Name, Track, Source In, Source Out, Record In, Record Out, Duration. The columns shown are selectable by the user by right-clicking on a column header and choosing Customize Columns...
18. **Given** a Timeline Index, **When** user types in the filter bar, **Then** the list filters to show only rows where any text column contains the search text. The same column and operation filter choosers as above are present.
19. **Given** a filtered Timeline Index, **When** user clicks a row, **Then** the playhead moves to that clip's position and the clip is selected on the timeline.
20. **Given** a selected row, the up and down arrows move from row to row. Shift+arrow selects multiple rows, also selecting corresponding clips in the timeline. Cmd+click and Shift+click on rows select items and contiguous items respectively. As in the Finder, multiple contiguous areas can be selected with gaps between.
21. **Given** a Timeline Index, **When** user clicks a column header, **Then** the list sorts by that column. Clicking again reverses sort order.

#### Find & Replace (Cmd+H)
21. **Given** a project browser with selected clips, **When** user presses Cmd+H, selects column "Name", enters Find "v1" and Replace "v2", and clicks "Replace All", **Then** all selected clips with "v1" in their name have it replaced with "v2". The operation is a single undoable command.
22. **Given** a Find & Replace dialog in the project browser, **When** user clicks "Replace" (single), **Then** only the current match is replaced and the highlight advances to the next match.
23. **Given** a Find & Replace dialog, **When** user clicks "Skip", **Then** the current match is left unchanged and the highlight advances to the next match.
24. **Given** a timeline context, **When** user presses Cmd+H, **Then** Find & Replace operates on clip names of clips in the active timeline.
25. **Given** a Replace All that modifies 15 clips, **When** user presses Cmd+Z, **Then** all 15 replacements are undone in a single undo step.
26. **Given** a Find & Replace with no matches, **When** user submits the query, **Then** "No matches found" is indicated and Replace/Replace All buttons are disabled.

#### Smart Bins
27. **Given** the project browser, **When** user creates a Smart Bin with criteria "Codec Contains ProRes AND FPS = 24", **Then** a new bin appears with a distinct icon that dynamically shows all matching clips.
28. **Given** a Smart Bin, **When** new media is imported that matches the criteria, **Then** the Smart Bin contents update automatically without user action.
29. **Given** a Smart Bin, **When** a clip's metadata changes so it no longer matches, **Then** it disappears from the Smart Bin automatically.
30. **Given** a Smart Bin, **When** user double-clicks a clip in it, **Then** the clip behaves identically to a clip in a regular bin (can be edited, loaded in source viewer, etc.).

### Edge Cases
- Empty bin Find: immediate "No matches found."
- Sift where all clips match: all visible, sift indicator still shown (filter is active, just happens to match everything).
- Sift where no clips match: bin appears empty with sift indicator; "No matches" message shown.
- Sifted clip deleted: removed from both visible and hidden sets.
- Find & Replace on read-only column (Duration, FPS): only editable metadata columns appear in the column selector; computed/read-only columns excluded.
- Timeline Quick Find during playback: playback stops, then find executes.
- Cmd+F in timeline with no active sequence: Find is disabled / not available.
- Sift persistence: sift criteria persist with the project and are re-applied on reopen.
- Smart Bin scope: user chooses scope at creation (project-wide or specific bin); modifiable after via scope switch.

---

## Requirements

### Functional Requirements

#### Query Engine (shared by Find, Sift, Smart Bins)
- **FR-001**: System MUST support searching any editable metadata column: Name, Duration, Resolution, FPS, Codec, Date Modified, and all custom metadata fields (Scene, Take, Shot, Comments, etc.).
- **FR-002**: System MUST support the following match operators for text fields: Contains, Begins With, Ends With, Matches Exactly.
- **FR-003**: System MUST support the following match operators for numeric fields: Equals, Greater Than, Less Than.
- **FR-004**: All text matching MUST be case-insensitive.
- **FR-005**: The query engine MUST be shared across Find, Sift, Smart Bins, and Timeline Index filtering — one matching mechanism, multiple result actions.

#### Bin Find
- **FR-010**: System MUST provide a Find command (Cmd+F) when the project browser is focused.
- **FR-011**: Find MUST accept a column selector, match operator, and search value.
- **FR-011a**: Find MUST include a prominent scope selector: "Visible (Sifted)" vs "All Clips" when a sift is active. When no sift is active, scope defaults to all clips.
- **FR-011b**: Find MUST have a button to extend it into Find & Replace
- **FR-012**: Find results MUST be expressed as clip selections in the project browser — matches are selected, non-matches are deselected.
- **FR-013**: System MUST support Find Next (Cmd+G) and Find Previous (Cmd+Shift+G) to cycle through matches.
- **FR-014**: The browser view MUST scroll to reveal the current match when cycling.
- **FR-015**: Find MUST wrap around: after the last match, Find Next returns to the first.
- **FR-016**: Dismissing Find (Escape) MUST restore the selection state that existed before Find was invoked.

#### Bin Sift
- **FR-020**: System MUST provide Sift, Expand Sift, Narrow Sift, and Clear Sift as commands — accessible via menu, keyboard shortcuts, and as buttons on the sift dialog when a sift is active.
- **FR-021**: Sift MUST hide all clips that do not match the criteria. Hidden clips are not deleted — they remain in the project.
- **FR-022**: The bin header MUST display a "(Sifted)" indicator when a sift filter is active.
- **FR-023**: System MUST support "Expand Sift" — add clips matching new criteria to the visible set (OR composition).
- **FR-024**: System MUST support "Narrow Sift" — hide clips within the visible set that don't match new criteria (AND composition).
- **FR-025**: "Clear Sift" (Escape or explicit action) MUST clear all sift state and make every clip visible.
- **FR-025a**: Sift criteria MUST persist with the project file and be re-applied on project reopen, maintaining identical editor state across sessions.
- **FR-025b**: Sift (and all other dialogs in this spec) MUST persist their settings
- **FR-026**: Sift MUST be non-destructive: all standard operations (rename, delete, relink, import) work normally on visible clips; hidden clips remain in the project.
- **FR-027**: When new clips are added (import, create) while a sift is active, they MUST appear if they match the current sift criteria, and be hidden if they don't.

#### Timeline Quick Find
- **FR-030**: System MUST provide a Find command (Cmd+F) when the timeline is focused.
- **FR-031**: Timeline Find MUST search clip attributes across all tracks in the active sequence.
- **FR-032**: When a match is found, the playhead MUST move to the matched clip's position and the clip MUST be selected.
- **FR-033**: Find Next (Cmd+G) and Find Previous (Cmd+Shift+G) MUST cycle through matches in timeline order (by timeline_start), regardless of track.
- **FR-034**: The timeline view MUST scroll to keep the matched clip visible.
- **FR-035**: If playback is active when Find is invoked, playback MUST stop before executing the find.

#### Timeline Index Panel
- **FR-040**: System MUST provide a Timeline Index as a floating dialog window. (Future: becomes a dockable panel when the dockable panel system is implemented.)
- **FR-041**: The Timeline Index MUST display columns: #, Clip Name, Track, Source In, Source Out, Record In, Record Out, Duration modifiable by the user as detailed earlier.
- **FR-042**: The panel MUST include a text filter bar that filters rows by substring match across text columns.
- **FR-043**: Clicking a row MUST navigate the playhead to that clip's timeline position and select the clip.
- **FR-044**: Column headers MUST be clickable for ascending/descending sort.
- **FR-045**: The Timeline Index MUST update when the timeline changes (clips added, removed, moved, renamed).

#### Find & Replace
- **FR-050**: System MUST provide a Find & Replace command (Cmd+H) in both project browser and timeline contexts.
- **FR-051**: Find & Replace MUST allow selection of which metadata column to search and replace within.
- **FR-052**: Only editable metadata columns MUST appear in the column selector. Computed/read-only fields (Duration, FPS, Resolution) MUST be excluded.
- **FR-053**: System MUST support "Replace" (single — replace current match, advance to next), "Replace All" (replace every match), and "Skip" (advance without replacing).
- **FR-054**: "Replace All" MUST execute as a single undoable command — one Cmd+Z undoes the entire batch.
- **FR-055**: Individual "Replace" operations MUST each be a separate undoable command.
- **FR-056**: In timeline context, Find & Replace MUST operate on clip names within the active sequence.
- **FR-057**: In project browser context, Find & Replace MUST include a prominent scope selector: "Selected Clips" vs "All Visible". Defaults to "Selected Clips" when a selection exists, "All Visible" otherwise. Respects any active sift.

#### Smart Bins
- **FR-060**: System MUST support creating Smart Bins with one or more criteria rows (AND logic between rows).
- **FR-060a**: Smart Bins MUST include a scope selector at creation: "Entire Project" vs a specific bin. Scope is modifiable after creation via the same switch.
- **FR-061**: Smart Bins MUST dynamically update their contents as media is added, removed, or modified.
- **FR-062**: Smart Bins MUST appear in the project browser with a visually distinct icon.
- **FR-063**: Clips in Smart Bins MUST behave identically to clips in regular bins (load in source viewer, edit, etc.).
- **FR-064**: Smart Bin definitions MUST persist with the project.
- **FR-065**: Users MUST be able to edit and delete Smart Bin criteria after creation.
- **FR-066**: Multiple Smart Bins serve as the mechanism for OR across different criteria sets (each bin is AND; multiple bins provide OR).

### Key Entities
- **Query**: A column + operator + value triple. The atomic unit of search. Shared by Find, Sift, Smart Bins.
- **Sift State**: The set of currently active filter criteria on a bin, composed through Sift/Expand Sift/Narrow Sift operations. Determines clip visibility.
- **Smart Bin**: A named, persistent collection of Query criteria (AND logic) that dynamically resolves to matching clips.
- **Match Result**: A clip that satisfies a query. In Find context: selected. In Sift context: visible. In Smart Bin context: member.
- **Timeline Index Entry**: A row representing one clip event on the timeline, with its positional and metadata fields.

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
