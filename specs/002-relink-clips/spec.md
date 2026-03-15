# Feature Specification: RelinkClips

**Feature Branch**: `002-relink-clips`
**Created**: 2026-03-14
**Status**: Draft
**Input**: Clip-level media reconnection with TC verification, offset adjustment, and segment file support. Replaces RelinkMedia.

---

## User Scenarios & Testing

### Primary User Story

An editor opens a project whose media files have moved, been media-managed (trimmed copies with shifted timecode), or split into segment files. They invoke Reconnect Media (Cmd+Shift+R), select a search directory, optionally configure matching rules, and the system reconnects each clip to the correct file — matching by the configured criteria, adjusting source offsets when needed, and leaving clips offline when no candidate contains their required frames.

### Dialog Flow

1. User triggers Reconnect Media (Cmd+Shift+R or File menu)
2. System determines scope: if clips are selected in the project browser, only those clips' offline media are included; otherwise all offline media in the project
3. Main dialog appears with:
   - List of clips to relink (scrollable)
   - Search directory picker (persists last-used)
   - **"Matching Rules..."** button → opens matching rules configuration sub-dialog
   - Relink / Cancel buttons
   - Progress panel (progress bar + status + scrolling results log)
4. User picks search directory, optionally configures matching rules
5. User clicks Relink → system processes clips with live progress
6. Status icons added to List of clips to relink as we progress (check/x)
   Additional detail Results appear in scrolling log as each clip is processed
7. User clicks Apply to commit, or Cancel to discard

### Matching Rules Dialog

Opened via "Matching Rules..." button. Controls which criteria the relinker uses to match and accept candidate files. Settings persist across sessions.

**Match By** (checkboxes — at least one required):
- **Filename** (on by default) — match by basename (case-insensitive)
- **Timecode** (on by default) — match/verify candidate file's start TC against stored start TC
- **Resolution** (off by default) — reject candidates with different width/height
- **Frame Rate** (off by default) — reject candidates with different fps

Look at Premiere's Link media and Resolve's Conform dialog for inspiration

Either Timecode or Filename must be checked. For example, Timecode alone can match transcoded files with different names.

**Options** (checkboxes):
- **Accept Trimmed Media** (off by default) — when enabled, accepts media-managed copies with different start TC and adjusts clip source_in/source_out to compensate. When disabled, candidates with different start TC are rejected.
- **Accept Filename Suffixes** (off by default) — when enabled, matches basename variants with numeric suffixes (e.g., `_001`, `_002`) as media-managed segments

### Acceptance Scenarios

1. **Given** a project with 100 offline clips referencing files on a disconnected drive, **When** the user selects a directory containing the same files at different paths with default matching rules, **Then** all 100 clips reconnect with source_in/source_out unchanged (same TC, same file content).

2. **Given** "Accept Trimmed Media" is enabled and a project has clips referencing `A026_C007.mov` starting at TC 00:40:33:02, **When** the search directory contains a media-managed copy starting at TC 00:41:00:00, **Then** clips whose required TC range falls within the managed copy's range reconnect with adjusted source_in/source_out, and clips whose range extends beyond the managed copy remain offline.

3. **Given** "Accept Trimmed Media" is disabled (default), **When** a candidate file has matching filename but different start TC, **Then** the candidate is rejected and the clip remains offline.

4. **Given** "Accept Filename Suffixes" is enabled and a project has clips referencing `A026_C007.mov`, **When** the search directory contains segment files `A026_C007_001.mov` and `A026_C007_002.mov`, **Then** each clip connects to whichever segment contains its required TC range, with source_in/source_out adjusted.

5. **Given** a project with linked video+audio clips from the same source, **When** reconnecting, **Then** audio clips' source_in (in samples) are adjusted consistently with video clips' source_in (in frames), maintaining sync.

6. **Given** a successful reconnection, **When** the user invokes Undo, **Then** all clips revert to their previous media assignments with original source_in/source_out values, and any newly created media records for segment files are removed.

7. **Given** a reconnection in progress with 1200 clips, **When** processing, **Then** the dialog shows a progress bar, per-clip status text, and a scrolling results log showing each clip as it's processed.

8. **Given** "Resolution" matching is enabled, **When** a candidate file has matching filename and TC but different dimensions, **Then** the candidate is rejected and the clip remains offline.

9. **Given** the user configures matching rules and closes the sub-dialog, **When** they open Reconnect Media in a later session, **Then** the matching rules are restored from the previous session.

### Edge Cases

- What happens when multiple candidate files contain a clip's required TC range (overlapping TC ranges)?
  → Prompt user to choose among ambiguous matches. Minor TC overlap between candidates is tolerated gracefully (not treated as an error).
- What happens when the media-managed WAV has no BWF time_reference?
  → If TC matching is enabled, treat as "no TC available" — accept on filename match only.
- What happens when a clip's source_in after offset adjustment would be negative?
  → The candidate file doesn't contain the clip's required frames. Leave clip offline.
- What happens when the user enables "Allow TC offset adjustment" but the media record has no stored start_tc?
  → Cannot compute offset. Accept on filename only (TC offset adjustment requires knowing the original start TC).

## Requirements

### Functional Requirements

- **FR-001**: System MUST determine each clip's required absolute TC range by combining the media record's stored start_tc with the clip's source_in and source_out.
- **FR-002**: System MUST match candidate files by basename (case-insensitive).
- **FR-003**: When "Search segment files" is enabled, system MUST also match basename variants with numeric suffixes (e.g., `_001`, `_002`).
- **FR-004**: When "Timecode" matching is enabled, system MUST probe each matched candidate's start TC (video: container TC tag; audio: BWF time_reference) and verify it matches the stored start TC (within ±1 frame tolerance).
- **FR-005**: When "Accept Trimmed Media" is enabled and a candidate's start TC differs from stored, system MUST compute the offset and adjust source_in and source_out on all clips reconnected to that candidate.
- **FR-006**: System MUST leave a clip offline if no candidate file passes all enabled matching criteria.
- **FR-007**: When "Resolution" matching is enabled, system MUST reject candidates with different width/height.
- **FR-008**: When "Frame Rate" matching is enabled, system MUST reject candidates with different fps.
- **FR-009**: System MUST create new media records (and corresponding master clips) for segment/trimmed files that don't match an existing media record. Master clip source range MUST reflect the trimmed file's actual content range.
- **FR-010**: System MUST update existing media records' file_path when all clips from that media reconnect to the same new file.
- **FR-011**: System MUST support undo/redo as a single atomic operation — one Undo reverts all clip reassignments, source_in/source_out adjustments, and media record changes from the entire reconnect session.
- **FR-012**: System MUST report progress per-clip via a callback suitable for the progress_panel UI component.
- **FR-013**: System MUST prevent two clips from being assigned to the same media record with conflicting file_paths.
- **FR-014**: System MUST maintain video/audio sync — when adjusting source offsets, audio clips (source_in in samples) MUST be adjusted by the equivalent duration as their linked video clips (source_in in frames).
- **FR-015**: System MUST store the candidate file's start TC on the media record after reconnection (updating metadata).
- **FR-016**: System MUST persist the search directory across sessions.
- **FR-017**: System MUST persist matching rules configuration per-project (in project settings). New projects MUST inherit matching rules from the most recently used project.
- **FR-018**: The main reconnect dialog MUST have a "Matching Rules..." button that opens the matching rules configuration sub-dialog.
- **FR-019**: The matching rules sub-dialog MUST require at least one of timecode or filename
- **FR-020**: When multiple candidate files pass all enabled matching criteria for a clip, system MUST prompt the user to choose among ambiguous matches rather than silently picking one.
- **FR-021**: System MUST respect browser selection scope — if clips are selected in the project browser when invoked, only those clips' offline media are processed. Otherwise all offline media in the project.
- **FR-022**: The existing RelinkMedia command MUST be removed and fully replaced by RelinkClips.

### Key Entities

- **Clip**: Timeline or master clip with source_in, source_out (in native units: frames for video, samples for audio), media_id reference, and clip_kind.
- **Media**: File-path record with stored start_tc (frames at rate) in metadata JSON. One media record per unique file path.
- **Candidate File**: A file on disk matched by basename. Has probed start TC, duration, and TC range.
- **TC Offset**: The difference (in frames at a common rate) between the original media's start TC and the candidate file's start TC. Applied to source_in/source_out when reconnecting to a shifted file.
- **Matching Rules**: User-configurable set of criteria (filename, TC, resolution, frame rate) and options (TC offset adjustment, segment search). Persisted across sessions.

---

## Clarifications

### Session 2026-03-14
- Q: When TC offset adjustment changes source_in/source_out, should undo restore per-clip or per-batch? → A: Single atomic undo — one Undo reverts the entire reconnect session.
- Q: When multiple candidate files' TC ranges overlap a clip's required range (e.g. TC-only matching), how to resolve? → A: Prompt user to choose among ambiguous matches, with tolerance for minor TC overlap between candidates.
- Q: Should reconnect operate on all offline clips or allow user to limit scope? → A: All offline by default, but user can select specific items in the browser first to limit scope.
- Q: Where should matching rules be persisted? → A: Per-project (project settings DB). New projects inherit the previous project's settings.
- Q: Should the existing RelinkMedia command be removed or kept? → A: Remove — RelinkClips fully replaces it.
- Q: When "Accept Trimmed Media" adjusts clips, should master clips also be adjusted? → A: Adjust master clip range + create a new master clip if the trimmed file is a different media record.

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
