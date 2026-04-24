# Feature Specification: Timeline Placements as Nested Sequence References

**Feature Branch**: `013-timeline-placements-as`
**Created**: 2026-04-23
**Status**: Draft
**Input**: User description: "Timeline placements become uniform nested-sequence references. The only true Clip rows in the system live inside master sequences. This generalizes synced clips, multicam, and compound clips into a single primitive: 'a master sequence placed on a timeline.'"

---

## ⚡ Quick Guidelines
- ✅ Focus on WHAT users need and WHY
- ❌ Avoid HOW to implement (no tech stack, APIs, code structure)
- 👥 Written for business stakeholders, not developers

---

## User Scenarios & Testing *(mandatory)*

### Primary User Story

A film editor works with heterogeneous source material — solo-camera masters with embedded audio, multicam bundles of N synchronized angles, field-recorded dailies where camera footage has been synced to an external audio recorder, and pre-edited compound clips promoted back into the pool. In today's NLEs these appear as four distinct primitives with four different behaviors, four different icons, and four different places the editor learns to look. The editor wants one uniform model: every piece of source material is a "multi-clip" whose internal shape (one video layer vs several, zero audio channels vs many) is just a detail. Placing any source onto the edit timeline always does the obvious thing: one linked video+audio pair per placement, where the audio carries whatever channels the source had and the video shows whichever angle the editor picks. Choosing between multicam angles and enabling/disabling audio channels is an edit-level decision the editor makes per placement, not a property of the source — but by default the placement tracks the master so that master-level edits (change the default angle, tweak a channel gain) propagate to every placement that hasn't been explicitly overridden for that property.

### Acceptance Scenarios

1. **Given** a single-file video with embedded audio has been imported, **When** the editor drags it onto the edit timeline, **Then** exactly two linked entries appear (one video, one audio), the video plays from the file's video track, and the audio plays from the file's embedded audio channels.

2. **Given** a synced source (a camera .mov plus a separate multi-track WAV from a field recorder), **When** the editor places it on the timeline, **Then** the video entry plays from the .mov and the audio entry plays from the WAV's channels — the camera's scratch audio is not heard unless explicitly enabled either on the placement or as the master's default.

3. **Given** a multicam master containing three camera angles on internal video tracks V1/V2/V3 whose master-level default angle is V1, **When** the editor places it on the timeline, **Then** the video entry plays V1, and the editor can change the exposed angle on this placement to V2 or V3 via a per-placement control without affecting other placements of the same master.

4. **Given** a synced placement is on the timeline and inherits its channel state from the master, **When** the editor opens the audio entry's per-placement controls and disables channels 3 and 4, **Then** during playback channels 3 and 4 are silent for that placement only; other placements of the same master continue to reflect the master's channel state.

5. **Given** a placement is on the timeline, **When** the editor trims the head of the video entry by 10 frames, **Then** playback of that placement starts 10 frames later into the underlying master, and no other placement of the master is affected.

6. **Given** the same master is placed on the timeline ten times, **When** the editor performs a content edit inside the master (e.g., trims a stream clip, relinks to a different media file), **Then** the change is reflected in all ten placements.

7. **Given** a video-only master is placed on the timeline five times, **When** the user later syncs audio to that master (turning it into a video+audio master), **Then** the five existing placements gain a linked audio entry tracking the master's new audio channels (per the track-the-master default), and any placement-scoped overrides the user had applied to other properties on those placements are preserved.

8. **Given** a placement of a master is on the timeline, **When** the editor performs a ripple-delete on that placement, **Then** downstream placements on the same track shift upstream by the deleted placement's duration and any link-group relationships on neighboring placements remain intact.

9. **Given** an importer reads a source project (Resolve DRP, FCP7 XML, Premiere .prproj), **When** the import completes, **Then** every placement on every imported timeline is a reference to a master sequence (not a direct media reference).

10. **Given** a master whose master-level default layer is V2, **When** the editor places it on the timeline, **Then** the placement's exposed layer is V2 by default; the editor can override to any other layer on that placement without affecting the master's default or other placements.

11. **Given** a master sequence and the user opens the master in its own editor view, **When** the user adjusts channel gain on the master's audio tracks (including by keyframes/automation), **Then** every placement of that master that has not explicitly overridden the corresponding channel reflects the new state on next playback.

### Edge Cases

- **Mixed fps between edit sequence and placed master**: the placement's window is expressed in the master's timebase. A project-level user setting selects the default rendering behavior for placements whose master fps differs from the edit sequence: either resample (retime to the edit-sequence cadence) or pass-through (treat the master's frames as if they were already at the edit sequence's fps). The user can override the project default per placement.

- **Master deletion with live placements**: same behavior as today's deletion-of-a-referenced-entity flow. The editor warns that N placements will be removed and offers the user the choice to delete-all-placements-and-master or abort the master deletion.

- **Nesting depth**: unbounded. The editor must detect cycles (direct or transitive) and refuse to create them with a clear user-facing error. There is no hard depth cap.

- **Self-reference cycles**: the editor must refuse any operation that would cause a sequence to appear, directly or transitively, inside itself. The refusal surfaces as a normal error; playback never hangs or stack-overflows as a result of user input.

- **Master internal track reordering**: a placement stores a reference to the master's track by stable track identity (not by track index). When the user reorders tracks inside the master, existing placements continue to expose the track they were configured to expose. Reordering is non-destructive to placement-level interpretation.

- **Relink replaces a master's media with a file of different duration or channel count**: content propagates; the placement's window may extend past the new content's end (existing offline-tail behavior applies). If the new media has MORE audio channels than the previous, placements that track the master (i.e., have not overridden channel state) gain the new channels automatically; placements that have overridden a channel keep their override and get default state for the new channels. If the new media has FEWER channels, a placement-level override on a now-removed channel is discarded.

- **Placement overrides a property that is later keyframed on the master**: the placement's override remains in force for that property and ignores the master's keyframes for that property only. All non-overridden properties continue to track the master, including its keyframe automation.

## Non-Goals

- **Output-time tiling / PiP / multi-layer compositing.** Showing multiple camera angles simultaneously in the finished frame (e.g., a 2×2 sports grid, split-screen effects, picture-in-picture overlays) is not part of this feature. The multicam master exposes exactly one angle per placement (alternative stack). Tiling is achievable in principle by dropping the master N times on separate video tracks of the edit sequence with different per-placement layer selectors and transform effects (position/scale/crop) — the same pattern Premiere and Resolve users use — but it requires a true alpha-blending compositor at the edit-sequence track level, which the current renderer does not provide ("topmost non-empty track wins"). A real compositor is a separate future feature; when it lands, tiled multicam falls out of this design without further changes.

- **Editing-time multicam viewer.** The grid-view UI that lets the editor preview all angles simultaneously during a live switch is orthogonal to this feature. The per-placement layer selector (FR-013) is what such a viewer would write to; the viewer itself is a separate UX surface.

- **Keyframed layer switching.** First landing ships a static per-placement layer selector only. Multicam-style over-time angle cutting (keyframed layer selector) is deferred.

- **Migration of legacy project files.** See FR-018. Existing .jvp files from the pre-refactor timeline model will not open; users re-import from source.

- **Compound-clip creation UX** ("nest this selection into a new master"). The data model supports compounds as a natural case of "any sequence is a valid master," but the user-facing command to create one from an existing selection is a follow-up.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST represent every user-placed entry on an edit timeline as a reference to a master sequence. No edit-timeline entry may directly reference a media file.
- **FR-002**: Placing a master sequence on a timeline MUST create exactly one timeline entry per medium the master contains at placement time: one video entry if the master has at least one video track, one audio entry if the master has at least one audio track.
- **FR-003**: When a placement produces both a video and an audio entry, the two entries MUST be linked by default so that slip, slide, roll, ripple, and other editing commands treat them as one unit until the editor explicitly unlinks them. Unlinking leaves each entry as an independent reference to the same master.
- **FR-004**: A video placement MUST expose exactly one of the master's video tracks at a time (alternative-stack semantics). The exposed track is determined by a per-placement layer selector that initializes from the master's user-modifiable default-layer property at drop time. The editor can change the placement's layer selector at any time without affecting the master.
- **FR-005**: An audio placement MUST play all of the master's audio channels together (composite semantics), subject to a per-channel enable/gain state. By default the placement's channel state tracks the master's channel state live; the editor may override any specific channel on the placement, and overrides are scoped to that placement.
- **FR-006**: The editor MUST be able to set channel enable/gain on the master itself, including as keyframed automation over the master's internal timeline. Placements that have not explicitly overridden a given channel reflect the master's state (including automation) at playback time.
- **FR-007**: Master-level changes propagate by default. When a master gains or loses tracks/channels, or when its default-layer property changes, existing placements reflect the change for any property they have not explicitly overridden. A placement only diverges from the master on the specific properties the editor has overridden on that placement; all other properties continue to track the master.
- **FR-008**: When a master's CONTENT changes (stream clip trims, media relinks, inner edits), every existing placement MUST reflect the change on next playback/render.
- **FR-009**: Editing commands on the timeline (trim, ripple, slip, slide, roll, split, blade, extend, delete — both ripple and non-ripple variants — and duplicate) MUST operate on the placement's window into the master's timebase, never on the master's internal clips.
- **FR-010**: The system MUST support masters that are themselves arbitrary sequences, including sequences that contain placements of other masters (nested to arbitrary depth). The system MUST refuse to create a cycle (direct or transitive) and surface a clear user-facing error if the editor attempts one. There is no fixed nesting depth cap.
- **FR-011**: All source-project importers (DaVinci Resolve project files, FCP7 XMEML, Premiere .prproj, and the drag-drop/media-import flow for loose files) MUST emit placements as references to master sequences. A synced Resolve source MUST be represented as one master sequence whose internal tracks pull from the appropriate media files (video file for V, external WAV for A).
- **FR-012**: Playback of a placement MUST produce correct decoded video and audio by following the reference chain from the placement through the master sequence's internal clips to the underlying media files — the editor's playback engine MUST recurse through any depth of nested sequences transparently and apply placement-level overrides during recursion.
- **FR-013**: When a master sequence has multiple internal video tracks, the editor MUST present a per-placement control for selecting which track (angle) is exposed. Changing the selection on one placement MUST NOT affect other placements of the same master or the master's default-layer property.
- **FR-014**: The editor MUST present a control for enabling/disabling and adjusting gain on each audio channel. The control MUST operate on both master sequences (affecting all tracking placements) and individual placements (scoping the change to that placement).
- **FR-015**: The editor MUST expose a project-level user setting for fps-mismatch behavior (resample vs pass-through) when a placed master's fps differs from the edit sequence's fps. Each placement MUST be able to override the project default.
- **FR-016**: A placement's reference to a master's track MUST be stored by stable track identity, not by track index. Reordering tracks inside a master MUST NOT change which track a placement exposes.
- **FR-017**: A master sequence MUST have a user-modifiable "video start timecode" property, defaulting to the start timecode of the first video clip inside the master, and a user-modifiable "audio start timecode" property, defaulting to the start timecode of the first synced audio clip inside the master. Both are editable via the inspector.
- **FR-018**: The system MUST NOT retain compatibility with project files saved under the previous timeline model. Users with older project files MUST re-import from their source project (DRP/XML/prproj) or media. The old model's code paths MUST be removed, not gated behind a flag or coexistence layer.

### Key Entities

- **Master sequence**: A sequence that represents a unit of source material. Internally a master sequence holds leaf clips (direct media references) on one or more video and audio tracks. A single-camera master has one video track with one leaf clip for the video file plus audio tracks with leaf clips for each of the file's audio channels. A synced master has a video track with a leaf clip for the video file plus audio tracks with leaf clips for each channel of the external audio recording. A multicam master has N video tracks (one per angle) plus audio tracks derived from whichever media provide the synced audio. A compound master is an arbitrary previously-edited sequence promoted for reuse as source. From the timeline's perspective all of these are the same primitive and are implemented as such. A master sequence carries a user-modifiable default-video-layer property and user-modifiable video-start-timecode and audio-start-timecode properties (defaulted from its first video clip and first synced audio clip respectively), plus master-level channel enable/gain state (optionally keyframed) that tracking placements inherit.

- **Timeline placement**: One or two linked timeline entries (one per medium the referenced master has at drop time) that represent a single placement of a master sequence on an edit timeline. A placement carries a window (start and end in the master's timebase), a video layer selector (referencing a master track by stable identity — initialized from the master's default-layer property at drop time), and a sparse set of per-channel audio overrides that materialize only when the editor explicitly modifies a channel on that placement. For any property the placement has not overridden, it live-tracks the master. A placement does not hold its own media reference — all media resolution flows through the referenced master.

- **Link group**: An association between the V and A timeline entries of the same placement that makes them move, trim, and ripple as one until the editor unlinks them.

- **Stream clip** (a leaf clip inside a master sequence): A direct reference to a media file with an in/out range in the file's native units. Stream clips are the only place in the system where a clip row holds a media reference directly. They are never visible on an edit timeline; users never interact with them outside a master's internal view.

---

## Review & Acceptance Checklist
*GATE: Automated checks run during main() execution*

### Content Quality
- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

### Requirement Completeness
- [ ] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

---

## Outstanding Clarifications

Resolved via user edits:
- ~~Master deletion with live placements~~ → existing delete-all-or-abort UX (Edge Cases).
- ~~Nesting depth policy~~ → unbounded with cycle detection (FR-010).
- ~~Master internal track reordering~~ → snapshot by stable track identity (FR-016).
- ~~Shape-change propagation~~ → placements track the master by default; only explicitly-overridden properties diverge (FR-007).
- ~~Audio channel changes on relink~~ → placements tracking the master gain new channels automatically (Edge Cases).
- ~~fps-mismatch behavior~~ → project-level user setting with per-placement override (FR-015).

Still open, for `/clarify`:

1. **Per-placement audio channel UI surface**: Inspector sub-section, modal palette, or dedicated "open placement" view?
2. **Per-placement video layer selector UI surface**: same set of options as above.
3. **Display naming in user-facing UI**: "Master sequence" is the internal term; user-visible label choices include "Source", "Master Clip", "Multi-Clip", or "Clip". Consistency across the pool, the inspector, and the timeline needs a ruling.
4. **Partial-drag surface**: when the editor wants to place only the video (or only the audio) portion of a master, what's the trigger? Modifier-drag from the pool? Source-viewer-side mark and drag? Menu command after placement?
5. **Default-layer editing UX**: the master has a user-modifiable default-layer property (FR-004). Is it set via inspector field, via right-click on a master's V track, via the master's internal view, or all three?

---

## Execution Status
*Updated by main() during processing*

- [x] User description parsed
- [x] Key concepts extracted
- [x] Ambiguities marked
- [x] User scenarios defined
- [x] Requirements generated
- [x] Entities identified
- [ ] Review checklist passed (5 UX clarifications remain)

---
