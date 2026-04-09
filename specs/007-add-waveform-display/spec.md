# Feature Specification: Waveform Display on Timeline Audio Clips

**Feature Branch**: `007-add-waveform-display`  
**Created**: 2026-04-08  
**Status**: Draft  
**Input**: User description: "Add waveform display to audio clips on the timeline"

---

## User Scenarios & Testing *(mandatory)*

### Primary User Story
When a user opens a project with audio clips on the timeline, those clips display a waveform visualization showing the audio content's amplitude envelope. The waveform appears progressively as peak data is generated in the background. The waveform helps the user visually locate transients, dialogue, silence, and edit points without playing back.

### Acceptance Scenarios

1. **Given** a project with audio clips on the timeline, **When** the timeline renders, **Then** each audio clip displays a waveform showing the min/max amplitude envelope inside the clip rectangle.

2. **Given** a newly imported audio clip with no cached peaks, **When** the clip first appears on the timeline or in a monitor, **Then** it renders as a flat colored rectangle (no waveform), and the waveform progressively fills in from left to right as peak generation completes in the background.

3. **Given** a clip whose waveform is fully generated, **When** the user zooms in or out on the timeline, **Then** the waveform redraws at appropriate detail level — coarser at zoom-out, finer at zoom-in — without visible delay.

4. **Given** a clip that has been trimmed (head or tail), **When** the timeline renders, **Then** the waveform shows only the visible portion of the audio, aligned to source time. No peak recomputation occurs.

5. **Given** a clip that has been slipped (source_in changed), **When** the timeline renders, **Then** the waveform shifts to reflect the new source region. No peak recomputation occurs.

6. **Given** a stereo audio file, **When** its waveform is displayed, **Then** left and right channels are summed to a single mono waveform (v1 behavior).

7. **Given** an offline clip (media file missing), **When** the timeline renders, **Then** no waveform is shown — the clip renders with its existing offline appearance.

8. **Given** a project is reopened after peaks were previously generated, **When** the timeline renders, **Then** waveforms appear immediately from the cached peak files (no regeneration).

9. **Given** a media file that has been relinked to a different file, **When** the relink completes, **Then** the old peak cache for that media is invalidated and new peaks are generated but the files remain on disk as long as they’re in the active undo stack path.

10. **Given** a media file whose modification time has changed (re-rendered externally), **When** the project is opened or file watch notices the change, **Then** stale peak caches are detected and regenerated.

### Edge Cases

- **Very short clips** (< 1 pixel wide): No waveform drawn — clip is too narrow.
- **Very long clips** (hours): Peak generation may take seconds; progressive display ensures the UI is never blocked.
- **Muted clips**: Waveform still displayed (mute is a playback concern, not a visual one).
- **Disabled clips**: Waveform drawn in the disabled clip color (dimmed), matching existing disabled appearance.
- **Clips with speed changes**: Waveform is time-stretched from existing peak data at render time — no recomputation.
- **Zero-duration audio files**: No peaks generated; no waveform displayed.
- **Multiple clips from same media file**: All share the same peak data — generated once.
- **Clip placed beyond media duration**: Waveform covers only the region where source audio exists.

---

## Clarifications

### Session 2026-04-08
- Q: Should users be able to toggle waveform display on/off? → A: Per-track toggle (button in track header, like Mute/Solo)
- Q: What minimum track height should suppress waveform drawing? → A: 30px (current minimum) — always show waveform regardless of track height
- Q: When should orphaned peak files be cleaned up? → A: Only after media leaves undo stack. Cleanup on project close or undo history truncation.
- Q: Is monitor waveform (audio strip across bottom of source/sequence monitor) in scope? → A: Yes, spec now but implement after timeline waveform works (lower priority within this feature).
- Q: Should this feature add a file watcher or just detect mtime on open? → A: Both. Existing media_status file watcher already detects changes — hook peak regeneration into it. Also check mtime on project open.

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST display a min/max amplitude envelope waveform inside each audio clip on the timeline.
- **FR-018**: Each track header MUST include a waveform toggle button. When off, clips on that track render without waveforms (flat rectangles as today).
- **FR-019**: System MUST retain peak files on disk as long as the associated media is reachable via any active undo stack path. Orphaned peak files (media fully removed from undo history) MUST be cleaned up on project close or undo history truncation.
- **FR-020**: Source and sequence monitors MUST display a waveform strip across the bottom when viewing audio-bearing media. This shares the same peak data and cache as timeline waveforms. (Lower priority — implement after timeline waveform is working.)
- **FR-002**: System MUST generate peak data in a background thread without blocking the UI or audio playback.
- **FR-003**: System MUST cache peak data as binary files in `<project>.jvp-cache/peaks/` directory, sibling to the `.jvp` project file.
- **FR-004**: System MUST use a base resolution of 256 audio samples per peak bin, with 4 mipmap levels (256, 512, 1024, 2048 samples/peak).
- **FR-005**: System MUST store min and max float32 values per bin, per channel.
- **FR-006**: System MUST sum stereo (or multi-channel) audio to mono for display in v1.
- **FR-007**: System MUST select the appropriate mipmap level based on the current zoom level so that approximately 1 peak bin maps to 1 pixel column.
- **FR-008**: System MUST render waveforms using a batch drawing primitive — not individual per-pixel draw calls — to meet frame-rate targets.
- **FR-009**: System MUST render the waveform color as a darker shade of the existing audio clip color.
- **FR-010**: System MUST progressively display waveforms as peak generation proceeds — showing completed regions immediately.
- **FR-011**: System MUST NOT recompute peaks when a clip is trimmed, slipped, copied, or moved. These operations change only the offset into existing peak data.
- **FR-012**: System MUST invalidate and regenerate peak data when a media file's modification time changes (detected on project open AND via live file watch during session) or the clip is relinked to a different file.
- **FR-013**: System MUST generate peaks per media file (master clip), not per timeline clip instance. All clip instances sharing a media file share peak data.
- **FR-014**: System MUST NOT display waveforms on video tracks.
- **FR-015**: System MUST NOT display waveforms on offline clips.
- **FR-016**: System MUST handle clips with non-unity speed by resampling from base peak data at render time.
- **FR-017**: System MUST load existing peak caches on project open without regenerating.

### Architectural Constraints

- **AC-001**: Peak computation and waveform rendering MUST be implemented in C++, not Lua. Peak generation runs in a C++ background thread; the batch waveform draw command executes inside the existing TimelineRenderer widget's QPainter pass.
- **AC-002**: Lua is responsible for deciding *when* and *where* to draw waveforms (clip geometry, zoom level, toggle state) and for requesting peak data via C++ bindings. Lua MUST NOT iterate raw audio samples or per-pixel peak values.

### Performance Requirements

- **PR-001**: Peak generation MUST NOT block the main thread or cause UI stalls.
- **PR-002**: Waveform rendering MUST NOT measurably increase timeline repaint time compared to the current flat-clip rendering (target: < 2ms additional per full repaint).
- **PR-003**: Peak file I/O MUST NOT block timeline rendering — peaks are loaded asynchronously or memory-mapped.

### Key Entities

- **Peak File**: Per-media-file binary cache containing min/max amplitude data at multiple resolutions. Keyed by media_id (UUID). Source file mtime stored in header for staleness detection. Stored in `<project>.jvp-cache/peaks/<media_id>.peaks`.
- **Peak Bin**: A single data point representing the min and max sample values over a fixed number of source audio samples (base: 256). Stored as two float32 values per channel.
- **Mipmap Level**: A decimation of peak data — each level halves the resolution of the previous. 4 levels total (256, 512, 1024, 2048 samples/bin).

---

## Review & Acceptance Checklist

### Content Quality
- [x] Focused on user value and visual feedback
- [x] All mandatory sections completed

### Requirement Completeness
- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable (PR-002 latency target)
- [x] Scope is clearly bounded (audio tracks only, mono only, no RMS)
- [x] Dependencies identified (existing: timeline renderer, media reader, media cache)

---

## Execution Status

- [x] User description parsed
- [x] Key concepts extracted
- [x] Ambiguities marked and resolved (stereo->mono, RMS->no, color->derived, location->jvp-cache)
- [x] User scenarios defined
- [x] Requirements generated
- [x] Entities identified
- [x] Review checklist passed

---
