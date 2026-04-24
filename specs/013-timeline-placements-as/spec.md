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

## Clarifications

### Session 2026-04-23
- Q: When the user exports/renders the edit sequence, how should the export path resolve clips into source media? → A: Same recursion as playback (one shared resolver; export-only policies like codec/bit-depth/colorspace/proxy-vs-source/resample-quality applied in the processing pipeline ABOVE the resolver, not inside it).
- Q: Undo granularity for clip-level override changes (channel enable, gain, layer selector)? → A: One undo step per change (no coalescing); descriptive labels per entry.
- Q: User-facing terminology — "Master Clip" vs "Master Sequence" vs "Source" vs "Multi-Clip"? → A: "Master sequence" across all UI surfaces. We are not doing what other NLEs do with "master clips"; the label should reflect that masters are real sequences.
- Q: Rendering contract when a clip's master is in an intermediate state (still importing, offline, cycle-errored)? → A: Same as the existing preview contract for intermediate/offline state — fail loudly with visible indicators; never silently hide the condition. A user preference to suppress loud indicators MUST exist.

## User Scenarios & Testing *(mandatory)*

### Primary User Story

A film editor works with heterogeneous source material — solo-camera masters with embedded audio, multicam bundles of N synchronized angles, field-recorded dailies where camera footage has been synced to an external audio recorder, and previously-edited sequences that the editor wants to reuse as source (nested back into another sequence). In today's NLEs these appear as four distinct primitives with four different behaviors, four different icons, and four different places the editor learns to look. The editor wants one uniform model: every piece of source material is either a master sequence (containing files directly) or a non-master sequence (containing clips that reference other sequences). Placing any sequence onto another creates one linked video+audio pair of clips where the audio carries whatever channels the referenced sequence had and the video shows whichever track the editor picks. Choosing between multicam angles and enabling/disabling audio channels is an edit-level decision the editor makes per clip, not a property of the referenced sequence — but by default the clip tracks the referenced sequence so that upstream edits (change the default angle, tweak a channel gain on the master) propagate to every clip that hasn't been explicitly overridden for that property.

### Acceptance Scenarios

1. **Given** a single-file video with embedded audio has been imported, **When** the editor drags it onto the edit timeline, **Then** exactly two linked clips appear (one video, one audio), the video plays from the file's video stream, and the audio plays from the file's embedded audio channels.

2. **Given** a synced source (a camera .mov plus a separate multi-track WAV from a field recorder), **When** the editor places it on the timeline, **Then** the video clip plays from the .mov and the audio clip plays from the WAV's channels — the camera's scratch audio is not heard unless explicitly enabled either on the clip or as the master's default.

3. **Given** a multicam master containing three camera angles on internal video tracks V1/V2/V3 whose master-level default angle is V1, **When** the editor places it on the timeline, **Then** the video clip plays V1, and the editor can change the exposed angle on this clip to V2 or V3 via a per-clip control without affecting other clips of the same master.

4. **Given** a synced clip is on the timeline and inherits its channel state from the master, **When** the editor opens the audio clip's per-clip controls and disables channels 3 and 4, **Then** during playback channels 3 and 4 are silent for that clip only; other clips of the same master continue to reflect the master's channel state.

5. **Given** a clip is on the timeline, **When** the editor trims the head of the video clip by 10 frames, **Then** playback of that clip starts 10 frames later into the underlying master, and no other clip of the master is affected.

6. **Given** the same master is placed on the timeline ten times, **When** the editor performs a content edit inside the master (e.g., trims one of its media refs, relinks to a different file), **Then** the change is reflected in all ten clips.

7. **Given** a video-only master is placed on the timeline five times, **When** the user later syncs audio to that master (turning it into a video+audio master), **Then** the five existing clips gain a linked audio clip tracking the master's new audio channels (per the track-the-master default), and any clip-scoped overrides the user had applied to other properties on those clips are preserved.

8. **Given** a clip referencing a master is on the timeline, **When** the editor performs a ripple-delete on that clip, **Then** downstream clips on the same track shift upstream by the deleted clip's duration and any link-group relationships on neighboring clips remain intact.

9. **Given** an importer reads a source project (Resolve DRP, FCP7 XML, Premiere .prproj), **When** the import completes, **Then** every clip on every imported timeline is a reference to a master sequence (not a direct media reference).

10. **Given** a master whose master-level default layer is V2, **When** the editor places it on the timeline, **Then** the clip's exposed layer is V2 by default; the editor can override to any other layer on that clip without affecting the master's default or other clips.

11. **Given** a master sequence and the user opens the master in its own editor view, **When** the user adjusts channel gain on the master's audio channels (including by keyframes/automation), **Then** every clip referencing that master that has not explicitly overridden the corresponding channel reflects the new state on next playback.

### Edge Cases

- **Mixed fps between edit sequence and referenced sequence**: the clip's window is expressed in the referenced sequence's timebase. A project-level user setting selects the default rendering behavior for clips whose referenced sequence's fps differs from the containing sequence: either resample (retime to the containing sequence's cadence) or pass-through (treat the referenced sequence's frames as if they were already at the containing fps). The user can override the project default per clip.

- **Referenced-sequence deletion with live clips**: same behavior as today's deletion-of-a-referenced-entity flow. The editor warns that N clips will be removed and offers the user the choice to delete-all-clips-and-the-sequence or abort the deletion.

- **Nesting depth**: unbounded. The editor must detect cycles (direct or transitive) and refuse to create them with a clear user-facing error. There is no hard depth cap.

- **Self-reference cycles**: the editor must refuse any operation that would cause a sequence to appear, directly or transitively, inside itself. The refusal surfaces as a normal error; playback never hangs or stack-overflows as a result of user input.

- **Referenced sequence's internal track reordering**: a clip stores a reference to the target track by stable track identity (not by track index). When the user reorders tracks inside the referenced sequence, existing clips continue to expose the track they were configured to expose.

- **Relink replaces a master's file with one of different duration or channel count**: content propagates; a clip's window may extend past the new content's end (existing offline-tail behavior applies). If the new file has MORE audio channels than the previous, clips that track the master (i.e., have not overridden channel state) gain the new channels automatically; clips that have overridden a channel keep their override and get default state for the new channels. If the new file has FEWER channels, a clip-level override on a now-removed channel is discarded.

- **Clip-level override vs master-level keyframed automation**: the clip's override remains in force for that property and ignores the master's keyframes for that property only. All non-overridden properties continue to track the master, including its keyframe automation.

## Non-Goals

- **Output-time tiling / PiP / multi-layer compositing.** Showing multiple camera angles simultaneously in the finished frame (e.g., a 2×2 sports grid, split-screen effects, picture-in-picture overlays) is not part of this feature. The multicam master exposes exactly one angle per clip (alternative stack). Tiling is achievable in principle by dropping the master N times on separate video tracks of the edit sequence with different per-clip layer selectors and transform effects (position/scale/crop) — the same pattern Premiere and Resolve users use — but it requires a true alpha-blending compositor at the edit-sequence track level, which the current renderer does not provide ("topmost non-empty track wins"). A real compositor is a separate future feature; when it lands, tiled multicam falls out of this design without further changes.

- **Editing-time multicam viewer.** The grid-view UI that lets the editor preview all angles simultaneously during a live switch is orthogonal to this feature. The per-clip layer selector (FR-013) is what such a viewer would write to; the viewer itself is a separate UX surface.

- **Keyframed layer switching.** First landing ships a static per-clip layer selector only. Multicam-style over-time angle cutting (keyframed layer selector) is deferred.

- **Migration of legacy project files.** See FR-018. Existing .jvp files from the pre-refactor timeline model will not open; users re-import from source.

- **Advanced operations inside master sequences.** The command surface for editing a master's interior is limited in first landing (window trim on media refs, media relink, channel state). Commands that would violate "masters hold only media refs" — e.g., nesting a clip inside a master — are refused. A richer master-interior editor is a follow-up.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST represent every clip (user-visible row on a non-master sequence's track) as a reference to another sequence. No clip may directly reference a media file; media references live only in media refs inside master sequences.
- **FR-002**: Placing a sequence onto another sequence's track MUST create exactly one clip per medium the referenced sequence contains: one video clip if the referenced sequence has at least one video track, one audio clip if at least one audio track.
- **FR-003**: When a single drop produces both a video and an audio clip, the two MUST be linked by default so that slip, slide, roll, ripple, and other editing commands treat them as one unit until the editor explicitly unlinks them. Unlinking leaves each clip as an independent reference to the same sequence.
- **FR-004**: A video clip MUST expose exactly one of the referenced sequence's video tracks at a time (alternative-stack semantics). The exposed track is determined by a per-clip layer selector that initializes from the referenced sequence's user-modifiable default-video-layer property at drop time. The editor can change the clip's layer selector at any time without affecting the referenced sequence.
- **FR-005**: An audio clip MUST play all of the referenced sequence's audio channels together (composite semantics), subject to a per-channel enable/gain state. By default the clip's channel state tracks the referenced sequence's live; the editor may override any specific channel on the clip, and overrides are scoped to that clip.
- **FR-006**: The editor MUST be able to set channel enable/gain at the master level (on `media_refs_channel_state`), including as keyframed automation over the master's timebase. Clips that have not explicitly overridden a given channel reflect the master's state (including automation) at playback time.
- **FR-007**: Sequence-level changes propagate by default. When a referenced sequence gains or loses tracks/channels, or when its default-layer property changes, existing clips reflect the change for any property they have not explicitly overridden. A clip only diverges from the referenced sequence on the specific properties the editor has overridden on that clip; all other properties continue to track.
- **FR-008**: When a referenced sequence's CONTENT changes (media-ref trims, media relinks, inner clip edits), every clip that references it MUST reflect the change on next playback/render.
- **FR-009**: Editing commands on a non-master sequence's tracks (trim, ripple, slip, slide, roll, split, blade, extend, delete — both ripple and non-ripple variants — and duplicate) MUST operate on the clip's window into its referenced sequence's timebase, never on the referenced sequence's internal rows.
- **FR-010**: The system MUST support referencing any sequence (master or non-master) from a clip in another non-master sequence, nested to arbitrary depth. The system MUST refuse to create a cycle (direct or transitive) and surface a clear user-facing error if the editor attempts one. There is no fixed nesting depth cap.
- **FR-011**: All source-project importers (DaVinci Resolve project files, FCP7 XMEML, Premiere .prproj, and the drag-drop/media-import flow for loose files) MUST emit clips on target non-master sequences, referencing master sequences the importer creates. A synced Resolve source MUST be represented as one master sequence whose internal media refs pull from the appropriate files (video file for V, external WAV for A).
- **FR-012**: Playback of a clip MUST produce correct decoded video and audio by following the reference chain from the clip through its referenced sequence's internal rows (clips or media refs) to the underlying media files. The playback engine MUST recurse through any depth of nested sequences transparently and apply clip-level overrides during recursion.
- **FR-013**: When a referenced sequence has multiple internal video tracks, the editor MUST present a per-clip control for selecting which track (angle) is exposed. Changing the selection on one clip MUST NOT affect other clips referencing the same sequence or the referenced sequence's default-layer property.
- **FR-014**: The editor MUST present a control for enabling/disabling and adjusting gain on each audio channel. The control MUST operate on both master sequences (affecting all tracking clips) and individual clips (scoping the change to that clip).
- **FR-015**: The editor MUST expose a project-level user setting for fps-mismatch behavior (resample vs pass-through) when a referenced sequence's fps differs from its containing sequence's fps. Each clip MUST be able to override the project default.
- **FR-016**: A clip's reference to a track inside its referenced sequence MUST be stored by stable track identity, not by track index. Reordering tracks inside the referenced sequence MUST NOT change which track a clip exposes.
- **FR-017**: Every sequence MUST have user-modifiable "video start timecode" and "audio start timecode" properties, defaulting from the first video media ref / first audio media ref (for masters) or the first video clip / first audio clip (for non-masters). Both are editable via the inspector.
- **FR-018**: The system MUST NOT retain compatibility with project files saved under the previous timeline model. Users with older project files MUST re-import from their source project (DRP/XML/prproj) or media. The old model's code paths MUST be removed, not gated behind a flag or coexistence layer.
- **FR-019**: Export/render MUST use the same resolver as playback (one shared resolver that walks clip → referenced sequence → media refs → media files, applying per-clip overrides). Export-specific policies (codec, bit depth, colorspace conversion, proxy-vs-source selection, resample filter quality, audio bit depth, scrub/preview-only-effect toggles) MUST be applied as parameters or post-resolution pipeline stages ABOVE the resolver, never by forking the resolver itself.
- **FR-020**: Each clip-level override change (enabling/disabling a channel, adjusting a channel's gain, changing the layer selector) MUST be a single undoable command with a descriptive human-readable label. Override changes MUST NOT be coalesced into grouped undo entries; five channel toggles in rapid succession produce five undo steps.
- **FR-021**: The user-facing term for a master sequence is "master sequence" across every UI surface (pool, inspector, timeline labels, menus, dialogs, error messages). The terms "master clip", "source", and "multi-clip" MUST NOT be used to refer to a master sequence in user-visible text. The user-facing term for what the user drags on a non-master sequence's timeline is "clip." The user-facing term for a row inside a master sequence is "file."
- **FR-022**: When a clip's chain is in an intermediate state (referenced sequence being imported, underlying file offline, or refused due to a detected cycle), the renderer MUST surface the state with the same visible treatment the editor already uses for offline/intermediate direct-media clips — never silently hide the condition behind a blank or black frame. A user preference MUST exist to suppress these loud indicators for delivery/presentation scenarios, but the default is loud-fail.

### Key Entities

- **Sequence**: The system's top-level composable unit. Every sequence has tracks, a timebase, dimensions, marks, and user-editable start-timecode + default-video-layer properties. Two structural kinds:
  - **Master sequence** (`kind='master'`): a sequence whose tracks hold **media refs** — direct references to media files. A single-camera master has one video track and one audio track per channel, each holding a media ref for the imported file. A multicam master has N video tracks (one per angle), each a media ref pointing at a different file; audio tracks hold media refs for synced audio. A synced master's video track points at the camera file and its audio tracks point at the external-recorder file's channels. Masters are created by import; editing them is restricted to operations that don't violate the "contains only media refs" invariant.
  - **Non-master sequence** (`kind='nested'`): a sequence whose tracks hold **clips** — references to other sequences. The user's edit timelines are non-master sequences. A sequence the user composed by nesting a selection is also non-master. Any non-master sequence can itself be nested inside another non-master sequence (recursive composition, cycle-prevented).

- **Clip**: The user-visible unit on a non-master sequence's track. Every clip references another sequence (master or non-master — FR-010) via its `nested_sequence_id`, carries a window (start and end in the referenced sequence's timebase), a video layer selector (pointing at a track of the referenced sequence — NULL inherits the sequence's default), and sparse per-channel audio overrides that materialize only when the editor explicitly modifies them. For any property the clip has not overridden, it tracks the referenced sequence live. A clip does not hold its own media reference — all media resolution flows through the referenced sequence down to the media refs at its leaves.

- **Media ref**: A row on a master sequence's track. Directly references a media file (via `media_id`) with an in/out range in the file's native units (video frames or audio samples). Media refs are the only rows in the system that hold media references directly; they are the leaves of the resolution chain. Users see them as "files" in the inspector/interior view of a master.

- **Link group**: An association between the V and A clips of a single drop (both referencing the same sequence), making them move, trim, and ripple together until the editor unlinks them.

- **Nested sequence (role)**: Any sequence — master or non-master — while currently placed inside another sequence. Nesting is a usage, not a kind. A sequence becomes "nested" when a clip references it and ceases to be nested if the last referencing clip is deleted.

---

## Review & Acceptance Checklist
*GATE: Automated checks run during main() execution*

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

## Resolved Clarifications

From user edits:
- Master deletion with live clips → existing delete-all-or-abort UX (Edge Cases).
- Nesting depth policy → unbounded with cycle detection (FR-010).
- Master internal track reordering → snapshot by stable track identity (FR-016).
- Shape-change propagation → clips track the master by default; only explicitly-overridden properties diverge (FR-007).
- Audio channel changes on relink → clips tracking the master gain new channels automatically (Edge Cases).
- fps-mismatch behavior → project-level user setting with per-clip override (FR-015).

From `/clarify` session 2026-04-23:
- Export/render resolver → shared with playback; export-only policies applied above the resolver (FR-019).
- Override undo granularity → one undo per change, descriptive labels, no coalescing (FR-020).
- User-facing terminology → "master sequence" everywhere (FR-021).
- Rendering contract for intermediate/offline masters → same loud-fail treatment as direct-media offline, with a user preference to suppress (FR-022).

## Orthogonal / Out-of-Scope for This Spec

The following were on earlier "open" lists but belong to separately-tracked work streams, not this spec's data model / commands / playback / export contract:

- **Partial-drag trigger** (V-only / A-only / V+A targeting): belongs to the insert/overwrite targeting enhancement (separate track; existing Resolve/Premiere/Avid targeting affordances).
- **Per-clip audio channel UI surface location**: a UX surface decision. Where the control sits does not affect the data model, commands, playback, or export; it will be resolved when that UI is built.
- **Per-clip video layer selector UI surface location**: same argument.
- **Default-layer editing UX location**: the master has the property (FR-004 + entity definition); where the user edits it is a UX surface decision, not a spec-level decision.

---

## Execution Status
*Updated by main() during processing*

- [x] User description parsed
- [x] Key concepts extracted
- [x] Ambiguities marked
- [x] User scenarios defined
- [x] Requirements generated
- [x] Entities identified
- [x] Review checklist passed (all clarifications resolved or deferred to orthogonal work streams)

---
