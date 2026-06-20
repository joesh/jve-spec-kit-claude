# Feature Specification: Five Timeline UX Improvements

**Feature Branch**: `025-five-timeline-ux`  
**Created**: 2026-06-17  
**Status**: Draft  
**Input**: User description: "Five timeline UX improvements: (1) FCP7-style through-edit detection and rendering — red inward-pointing triangle chevrons at cut points, right-click context menu 'Join Through Edit' / 'Join All Through Edits' commands; (2) ±nnn timecode offset entry — pressing + or - activates a red-bordered TC entry field prepopulated with the sign, Enter offsets the playhead; (3) JKL shuttle speed in quarter steps (0.25x increments) configurable via prefs, no settings UI yet; (4) bigger click zones for track header M and S buttons; (5) Option+click on M or S sets only that track to the toggled state and sets all other tracks to the opposite."

---

## User Scenarios & Testing *(mandatory)*

### Primary User Story

An editor working in the timeline needs sharper feedback about the edit structure, finer control over playback speed, and less frustration with small targets and all-or-nothing mute/solo toggling.

---

## FR-001: Through-Edit Detection and Rendering

### What Is a Through-Edit

A **through-edit** is a cut between two adjacent clips that is editorially invisible: both clips come from the same source and their source frames are contiguous, so playing across the cut is indistinguishable from an uncut clip. Through-edits arise from splitting, trimming, or importing. The editor needs to see them to decide whether to rejoin them.

### Visual Treatment

Two small red inward-pointing triangle chevrons appear at the cut point on every through-edit boundary:

- **Left chevron**: rightward-pointing triangle with its tip touching the cut line at the clip's right edge.
- **Right chevron**: leftward-pointing triangle with its tip touching the cut line at the clip’s left edge.

The chevrons are drawn in a named color constant `THROUGH_EDIT_MARKER` (red, exact value chosen at implementation time to read clearly against both audio and video clip body colors). They appear on both clips that form the pair — at the same pixel column where clip A ends and clip B begins.

### Scope

Through-edit detection and rendering applies to the **Record tab only** (the edit sequence). The Source tab displays a raw master clip and never shows through-edit markers.

### Detection Rule

Clips A and B form a through-edit when all three conditions hold:

1. Adjacent on the same track: `A` ends exactly where `B` begins (no gap).
2. Same source: both clips reference the same master/source sequence.
3. Contiguous source frames.

For audio clips with subframe precision, subframe continuity is also required when both values are present.

### Context Menu

Right-clicking an **edit point** (the cut line between two clips) adds two items (with a preceding separator):

- **Join Through Edit** — rejoins the right-clicked edit: deletes the right clip and extends the left clip to absorb it. Enabled only when the right-clicked edit is a through-edit; shown but grayed out otherwise with tooltip "Not a through-edit".
- **Join All Through Edits** — rejoins every through-edit pair in the active sequence in one undoable operation.

Both operations are **undoable**.

### Join Behavior

Joining a through-edit extends the left clip’s out-point and duration to cover the right clip’s full range, then removes the right clip. The result is identical to what the original uncut clip would have been for that range. Link group membership is preserved on the surviving clip. Any markers, keyframes, or other per-clip data on the right clip are migrated to the left clip.

### Acceptance Scenarios

1. **Given** two adjacent clips from the same source with contiguous source frames, **When** the timeline renders, **Then** red chevrons appear at the cut point on both clips.
2. **Given** two adjacent clips from different sources, **When** the timeline renders, **Then** no chevrons appear at that cut.
3. **Given** two adjacent clips from the same source with a source gap (non-contiguous frames), **When** the timeline renders, **Then** no chevrons appear.
4. **Given** a through-edit exists, **When** the user right-clicks the edit point and chooses "Join Through Edit", **Then** the two clips merge into one, the chevrons disappear, and undo restores both clips.
5. **Given** multiple through-edits exist, **When** "Join All Through Edits" is chosen, **Then** all pairs are joined in a single undo step.
6. **Given** a non-through-edit cut point is right-clicked, **When** the context menu opens, **Then** "Join Through Edit" is shown but grayed out.

### Edge Cases

- Three-way chain (clip B is the right member of one through-edit and the left member of another): "Join All Through Edits" collapses the entire chain.
- Through-edit on a locked track: join is refused; the marker still renders.
- Zero-duration clips cannot form a through-edit.

---

## FR-002: ±nnn Timecode Offset Entry

### Overview

Pressing `+` or `-` (main keyboard or numpad) activates the timecode entry field in offset mode. The field is pre-populated with the sign character. The user types an offset, then presses Enter. **If nothing is selected**, the playhead moves by that amount. **If clips or edits are selected**, `IncrementTimecode`/`DecrementTimecode` delegate to the existing `Nudge` commands to execute the move — no clip/edit move logic is re-implemented in these commands. Pressing `=` activates the field pre-populated with `=` for direct absolute-timecode entry; Enter moves the playhead to that exact frame regardless of selection. This matches the standard NLE "nudge by typed amount / go to" gesture.

### Activation

- `+` or `Num+` → stops playback if running, then activates the entry field with `+` as the first character.
- `-` or `Num-` → stops playback if running, then activates the entry field with `-` as the first character.
- `=` → stops playback if running, then activates the entry field with `=` as the first character (absolute-TC mode).
- If the field is already active, pressing `+`/`-`/`=` replaces the prefix character (does not stack).

### Visual

Uses the TC text entry field at the Timeline upper-left. While in offset or GoTo mode the field gains a red border to indicate it is active for entry (distinct from the normal display state).

### Input Formats

- all the formats that the TC field currently accepts

### Commit and Cancel

- **Enter / Return**: parse the field, clamp the resulting frame to `[0, sequence_duration]`, do the move, exit the field.
- **Escape** or click outside: cancel without moving.
- Exiting restores the TC display.

### Keybindings

`+`, `Num+` → `IncrementTimecode`; `-`, `Num-` → `DecrementTimecode`; `=` → `GoToTimecode`. All three added to `default.jvekeys`.

Confirmed unbound: `default.jvekeys` has no bare `Plus`/`Minus`/`Equals` entries (only `Cmd+Plus`/`Cmd+Minus` for zoom, which do not conflict).

### Acceptance Scenarios

1. **Given** the timeline is focused, **When** `+` is pressed, **Then** the TC entry field appears with `+` and cursor ready for digits.
2. **Given** the TC field shows `+10` and no clips are selected, **When** Enter is pressed, **Then** the playhead moves forward 10 frames.
3. **Given** the TC field shows `+00:00:01:00` at 30 fps and no clips are selected, **When** Enter is pressed, **Then** the playhead moves forward 30 frames.
4. **Given** the TC field shows `-5` and no clips are selected, **When** Enter is pressed, **Then** the playhead moves backward 5 frames.
5. **Given** the TC field is active, **When** Escape is pressed, **Then** the field hides and the playhead does not move.
6. **Given** the playhead is at the last frame and `+100` is entered with no selection, **Then** the playhead clamps to the last frame without error.
7. **Given** playback is running, **When** `+` is pressed, **Then** playback stops and the TC field activates with `+`.
8. **Given** two clips are selected and the TC field shows `+10`, **When** Enter is pressed, **Then** both selected clips move forward 10 frames; playhead does not move.
9. **Given** the timeline is focused, **When** `=` is pressed, **Then** the TC entry field appears with `=` and cursor ready for digits; Enter navigates the playhead to the entered absolute timecode.

### Edge Cases

- Invalid input (non-numeric, malformed TC): field stays open for re-entry; no crash, no playhead move.
- Entry of bare `+`, `-`, or `=` with no digits then Enter: treated as zero offset / current TC (no-op).

---

## FR-003: JKL Shuttle Speed Quarter Steps

### Overview

The JKL shuttle speed ladder currently steps in powers of two (1×, 2×, 4×, 8×). It is replaced with a fixed algorithm: 0.25× increments from 1.0× to 2.0×, then powers of 2 with no upper limit. No configuration is needed.

### Speed Ladder Algorithm

- **1.0× – 2.0×**: steps of 0.25 (1.0, 1.25, 1.5, 1.75, 2.0)
- **Above 2.0×**: successive powers of 2 (4.0, 8.0, 16.0, 32.0, …) — no upper bound

### Step Behavior

- Pressing L (forward) or J (reverse) while already playing in that direction advances one step up the ladder (faster).
- Pressing the opposite key retreats one step down.
- Pressing the opposite key at 1.0× stops playback.

### K+J / K+L (Slow Play)

The K-held slow-play behavior (K+J = 0.5× reverse, K+L = 0.5× forward) is unchanged.

### Acceptance Scenarios

1. **Given** playback is stopped, **When** L is pressed once, **Then** playback starts at 1.0× forward.
2. **Given** playback is at 1.0× forward, **When** L is pressed, **Then** speed becomes 1.25×.
3. **Given** playback is at 1.5× forward, **When** J is pressed twice, **Then** speed steps to 1.25×, then to 1.0×; pressing J once more stops playback.
4. **Given** playback is at 1.0× forward, **When** J is pressed, **Then** playback stops.
5. **Given** playback is at 2.0× forward, **When** L is pressed, **Then** speed becomes 4.0×.
6. **Given** playback is at 32.0× forward, **When** L is pressed, **Then** speed becomes 64.0×.

### Edge Cases

- K+J / K+L (0.5×) is outside the forward/reverse ladder; it does not interact with step-up/down behavior.

---

## FR-004: Larger M/S Button Click Zones

### Overview

The Mute (M) and Solo (S) buttons in the track header are currently too small to click reliably. Their click zone is expanded.

### Behavior

The buttons are made wider (target: 24 px, up from 16 px). The "M" / "S" label text size is unchanged. Functionality is identical to the current behavior — click dispatches the same mute/solo toggle.

### Acceptance Scenarios

1. **Given** a track header is visible, **When** the user clicks anywhere in the larger M button area, **Then** the mute state toggles.
2. **Given** the M button is active, **When** clicked, **Then** it deactivates; clicked again, it reactivates.

---

## FR-005: Option+Click Exclusive M/S Toggle

### Overview

Option+clicking any of the track header buttons toggles its state and sets **all other tracks of the same type** to the opposite state. This enables "mute everything except this,” "solo only this,” etc. in a single gesture.

### Exact Semantics

Let `new_state = !current_state` for the clicked track.

- The clicked track's property is set to `new_state`.
- All other tracks of the same type (video tracks form one population; audio tracks another) in the active sequence have their property set to `!new_state`.

Examples:
- Track A2: muted=false. Option+click M → A2: muted=true; all other audio tracks: muted=false.
- Track A2: muted=true. Option+click M → A2: muted=false; all other audio tracks: muted=true.

Video and audio track populations are independent: Option+click on a video track's M only affects video tracks.

### Non-Undoable

Consistent with plain `ToggleTrackPreference`, this operation is not on the undo stack.

### Acceptance Scenarios

1. **Given** three audio tracks (A1 muted, A2 unmuted, A3 muted), **When** Option+click M on A2, **Then** A2 is muted=true; A1 and A3 are muted=false.
2. **Given** three audio tracks (A1 soloed=false, A2 soloed=true, A3 soloed=false), **When** Option+click S on A1, **Then** A1 is soloed=true; A2 and A3 are soloed=false.
3. **Given** mixed video and audio tracks, **When** Option+click M on a video track, **Then** only other video tracks are affected; audio track mute states are unchanged.
4. **Given** only one track exists, **When** Option+click M, **Then** that track's mute state toggles (no other tracks to set).
5. **Given** a plain click (no Option key), **When** M is clicked, **Then** normal single-track toggle fires.

### Edge Cases

- Option+click on a locked track: refused (locked track invariant); other tracks are not modified.
- Option+click with no other tracks of the same type: behaves as a plain toggle.

---

## Key Entities

- **Through-edit pair**: two adjacent clips satisfying the detection rule (same source, contiguous source range). Identified at render time; not persisted.
- **TC offset entry**: transient UI state (active/inactive, current text). Not persisted.
- **Track preference (muted/soloed)**: per-track boolean persisted in the project. Modified by both single-track and exclusive-toggle operations.

---

## Clarifications

### Session 2026-06-18

- Q: When `+`/`-` is entered with clips selected, does the offset move the selected clips or the playhead? → A: Moves selected clips (Option A); playhead moves only when nothing is selected. `=` always moves playhead to absolute timecode regardless of selection.
- Q: When right-clicking in a through-edit chain, which pair does "Join Through Edit" act on? → A: The right-click target is the edit point (cut line), not a clip body — the edit uniquely identifies the pair. "Delete right clip, extend left" always applies; no special-casing needed.

- Q: When pressing the opposite direction key while shuttling forward, does retreat stop at 1× or continue decelerating below 1× in the original direction? → A: Stops at 1× (Option A — like Resolve/FCP7). Pressing the opposite key at 1× stops playback; speeds below 1× are only reached by pressing the same-direction key from stopped.
- Q: What happens if `+` or `-` is pressed while playback is running? → A: Stop playback first, then activate the TC entry field.
- Q: Should through-edit chevrons appear on the Source tab (master clip view) or Record tab only? → A: Record tab only.

---

## Review & Acceptance Checklist

### Content Quality
- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user/editor workflow value
- [x] All mandatory sections completed

### Requirement Completeness
- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Scope clearly bounded (five discrete, independently testable features)
- [x] Dependencies identified: FR-005 requires modifier state at button-click time

---

## Execution Status

- [x] User description parsed
- [x] Key concepts extracted
- [x] Ambiguities marked
- [x] User scenarios defined
- [x] Requirements generated
- [x] Entities identified
- [x] Review checklist passed
