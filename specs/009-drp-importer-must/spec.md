# Feature Specification: File Original TC for Override-Aware Relink & Decode

**Feature Branch**: `009-drp-importer-must`
**Created**: 2026-04-11
**Status**: Draft
**Input**: User description: "DRP importer must carry two timecodes per media row — the file's TC and an optional override TC (set by Resolve's Set Timecode feature). If present, override TC is used except for at file matching level where either the file's TC or override TC are accepted. Follow-up to the retime curve-walking fix (commit 8475976) and dedupe salvage fix (commit b48b446) to unblock the remaining VFX relink failures in the gold master."

## Execution Flow (main)
```
1. Parse user description from Input
   → If empty: ERROR "No feature description provided"
2. Extract key concepts from description
   → Identify: actors, actions, data, constraints
3. For each unclear aspect:
   → Mark with [NEEDS CLARIFICATION: specific question]
4. Fill User Scenarios & Testing section
   → If no clear user flow: ERROR "Cannot determine user scenarios"
5. Generate Functional Requirements
   → Each requirement must be testable
   → Mark ambiguous requirements
6. Identify Key Entities (if data involved)
7. Run Review Checklist
   → If any [NEEDS CLARIFICATION]: WARN "Spec has uncertainties"
   → If implementation details found: ERROR "Remove tech details"
8. Return: SUCCESS (spec ready for planning)
```

---

## ⚡ Quick Guidelines
- ✅ Focus on WHAT users need and WHY
- ❌ Avoid HOW to implement (no tech stack, APIs, code structure)
- 👥 Written for business stakeholders, not developers

This feature closes the last of three gaps that keep gold-master clips offline after a relink to the trimmed-fixture tree. The first two were the retime curve-walking fix (commit `8475976`) and the duplicate-media-row dedupe salvage (commit `b48b446`). This one covers master clips whose TC has been overridden in the authoring NLE via Resolve's "Set Timecode" feature, causing the TC recorded in the DaVinci Resolve project file to differ from the TC probed from the file's own container.

The stored TC on a media row (`start_tc_value`) remains the authoritative value for display, for source-range origin, and for the playback decoder's TC anchor. What this feature adds is a second field on the media row — the file's ORIGINAL container TC — used by the relinker as an additional candidate acceptance criterion and used at playback-open time to tell the media-file subsystem to substitute `start_tc_value` for whatever it probes from the file's container.

---

## Clarifications

### Session 2026-04-11

- Q: How should duplicate-same-file media pool entries (one with override, one without) be keyed? → A: Preserved as two rows. Divergence is encoded by `file_original_timecode` on each row — both rows share the same `file_original_timecode` value (the real container TC), and only the overridden row carries a different `start_tc_value`. No new identity rule.
- Q: At decode time, should source_in be measured from the file's container TC or from the stored `start_tc_value`? → A: From `start_tc_value`. The media-file subsystem must accept a caller-supplied override for its TC origin so the decoder's file-relative arithmetic uses JVE's authoritative value rather than the probed container TC.
- Q: Should source_in be remapped by `(override − file_container)` on a relink that matches via `file_original_timecode`? → A: No. Source_in is always stored in `start_tc_value` space and NEVER remapped on relink. The media-file subsystem substitution handles the delta at decode time.
- Q: Name for the new field? → A: `file_original_timecode`. Names the thing (the file's container TC at authoring time), not its role.
- Q: EMP setter API shape — open-time parameter or separate setter? → A: Exactly one new entry point — a `set_tc_origin_override` method called after open and before the first decode. If not called, today's behavior is unchanged byte-for-byte. The setter MUST assert if decode has already begun.
- Q: Missing `BtAudioInfo.TracksBA` blob on a master clip (e.g. silent video) — fallback to `start_tc_value` or fail? → A: Fail loudly. No fallback. Per CLAUDE.md §1.14 fail-fast policy.
- Q: FR-003 failure scope — halt entire import or error-and-continue when one master clip's TracksBA is missing? → A: Error that media row with a loud named error, continue importing the rest. Skipped media's clips will be offline.

---

## User Scenarios & Testing *(mandatory)*

### Primary User Story

An editor in JVE imports a DaVinci Resolve project where the authoring editor applied "Set Timecode" overrides to some master clips (typically VFX renders or archival footage whose on-disk TC doesn't match the TC the editor wanted to see). When the editor relinks to a set of handoff media, every clip comes online — including the overridden ones, even when the fixture files still carry the original container TC. The TC shown in the source viewer / inspector / timeline ruler matches what Resolve was showing (the override). The playback engine does not crash on an invariant violation when parked on those clips.

### Acceptance Scenarios

1. **Given** a master clip with a Set Timecode override (file container TC = `00:07:35:08`, override TC = `13:16:12:21`), **When** the project is imported, **Then** the media row stores `start_tc_value = 13:16:12:21` (as today) AND additionally stores `file_original_timecode = 00:07:35:08` on the same row.

2. **Given** a master clip with no override (file container TC = `00:07:35:08`, no override), **When** the project is imported, **Then** the media row stores `start_tc_value = 00:07:35:08` (as today) AND either omits `file_original_timecode` or stores it with the same value; absent and equal MUST be treated identically by consumers.

3. **Given** the override master clip from scenario 1, **When** the editor relinks against a candidate file whose probed container TC is `00:07:35:08`, **Then** the relinker accepts the candidate by matching on `file_original_timecode`, and no timeline clip's source range is modified.

4. **Given** the same override master clip after a successful relink, **When** the playback engine opens the relinked file for decode, **Then** the media-file subsystem is told via the override setter to use `13:16:12:21` as the TC origin in place of what it probed from the container, and a clip whose `source_in = 13:16:12:21 + N` decodes at file-relative frame `N` — not the massively wrong frame that would result from using the probed `00:07:35:08`.

5. **Given** a project whose media is all camera footage (no Set Timecode overrides), **When** the project is imported, relinked, and played, **Then** behavior is identical to today: no media row has `file_original_timecode` populated, no callsite invokes the override setter, and the existing decode path runs unchanged.

6. **Given** the user's production "anamnesis" project, where the gold-master sequence currently has approximately 12 VFX clips that fail to relink and/or crash the playback engine because of Set Timecode overrides, **When** the user re-imports the project and runs relink against the trimmed-fixture tree, **Then** those VFX clips relink successfully, their source viewers show a real frame, and the playback engine does not trigger the `file_frame >= 0` invariant assertion.

7. **Given** the two-clips-same-file-different-tc repro fixture (a minimal DRP with the same underlying file referenced twice — once with a Set Timecode override, once without), **When** the project is imported, **Then** both resulting media rows carry the same `file_original_timecode` value (the file's real container TC) and the overridden row additionally has a different `start_tc_value`.

### Edge Cases

- **Camera footage (both TCs agree)**: `file_original_timecode` is either absent or equal to `start_tc_value`. Consumers MUST treat absent as equal. No override setter call. Decode path is byte-for-byte unchanged from today.
- **Candidate matches `start_tc_value` directly** (e.g. a file that has been re-timecoded to bake the override into its container): accepted on the primary match. `file_original_timecode` is not consulted for that candidate.
- **Candidate matches neither field**: the existing trimmed-media containment fallback runs exactly as today, using `start_tc_value` as the containment reference.
- **`BtAudioInfo.TracksBA` blob missing from a master clip** (encrypted blob, stock footage, silent video): the media row imports normally without `file_original_timecode`. Pre-feature relink behavior for that row.
- **Pre-feature imports**: media rows imported under the old behavior have no `file_original_timecode`. Those projects must be re-imported to populate the field. Acceptable because the user's workflow already involves re-importing.
- **Override setter called after decode has begun**: the media-file subsystem MUST assert. The setter's valid window is between open and first decode.

## Requirements *(mandatory)*

### Functional Requirements

**Import**

- **FR-001**: The DRP importer MUST extract the file's original container TC from every imported master clip's `BtAudioInfo.TracksBA.StartTime` blob field and, when that value differs from `start_tc_value`, store it on the media row as `file_original_timecode`. When the two values are equal, the importer MAY omit `file_original_timecode`; consumers MUST treat an absent value as equal to `start_tc_value`.
- **FR-002**: The existing `start_tc_value` continues to carry the master clip's displayed TC — the override when present, the file container TC otherwise. No behavior change for display, source-range origin, or playback anchoring.
- **FR-003**: When `BtAudioInfo.TracksBA` is missing from a master clip's blob (encrypted blob, stock footage, unmatched PMC enrichment), the importer imports the media row normally without `file_original_timecode`. This is expected — those media rows behave identically to pre-feature behavior. No skip, no error, no fallback value.
- **FR-003a**: The DRP importer's media deduplication MUST use both file path and displayed TC (`media_start_time`) as the identity key, so that two master clips pointing at the same file but carrying different Set Timecode overrides produce separate media rows. Two master clips with the same file and the same displayed TC still dedup to one row (unchanged behavior for camera footage).

**Media-file subsystem (EMP)**

- **FR-004**: EMP MUST expose exactly one new entry point on `MediaFile`: a method that sets a TC origin override. When called, the override replaces whatever EMP probed from the file's container in `MediaFileInfo::first_frame_tc`. When not called, EMP's probing and decode behavior MUST be unchanged byte-for-byte from today.
- **FR-005**: The override setter MUST assert if it is called after any decode operation has begun on the `MediaFile`. Its valid window is strictly between `MediaFile::Open` and the first decode. The assertion MUST name the function and the `MediaFile`'s path for actionability.
- **FR-006**: EMP MUST retain its existing container-TC probing capability as a separate, caller-visible query: the relinker continues to use it to read a candidate file's container TC. The new setter is purely additive — it does not replace or alter probing.
- **FR-007**: The override mechanism MUST be codec-agnostic. It lives at the `MediaFileInfo` layer above every backend (FFmpeg, BRAW, future codecs). Backends MUST NOT each reimplement it.

**Relink**

- **FR-008**: When a relink candidate's probed container TC matches (within existing tolerance) EITHER the media row's `start_tc_value` OR its `file_original_timecode`, the candidate MUST be accepted as a TC match.
- **FR-009**: A relink match on EITHER field MUST NOT modify any timeline clip's source range. Source ranges remain in `start_tc_value` space unconditionally.
- **FR-010**: When a candidate matches neither field, the existing trimmed-media containment fallback path MUST execute exactly as today, using `start_tc_value` as the containment reference.

**Playback-open callsites**

- **FR-011**: Every JVE callsite that opens an EMP `MediaFile` for a purpose tied to a specific Media row (playback reader acquisition, source-viewer probe) MUST, when the row's `file_original_timecode` is populated, call the override setter with `start_tc_value` before any decode operation begins on that `MediaFile`. (Waveform peak generation does not use TC-relative seeking and does not need the setter.)
- **FR-012**: When the row's `file_original_timecode` is absent, callsites MUST NOT call the override setter. The code path MUST be identical to today for every camera-footage media row.

**Correctness & re-import requirement**

- **FR-013**: Importing a project whose media is all camera footage MUST NOT change the resulting media rows, source ranges, or post-relink state of any clip that would have worked before this feature was added. Existing regression tests MUST continue to pass with no expected-value changes.
- **FR-014**: Projects imported under the pre-feature behavior MUST be re-imported to populate `file_original_timecode`; the pre-feature rows do not automatically acquire the new field. No migration, no shims. The commit message and `docs/resolve-trimmed-handoff-issues.md` MUST state this explicitly. This is acceptable because the user's workflow already involves re-importing the project.

**Testing**

- **FR-015**: A new regression test MUST cover the two-clips-same-file-different-tc fixture end-to-end, asserting that both resulting media rows share the same `file_original_timecode` value and that the overridden row additionally has a different `start_tc_value`.
- **FR-016**: A new regression test MUST cover relink of a file whose probed container TC matches `file_original_timecode` but not `start_tc_value`, asserting the candidate is accepted without source-range modification AND that subsequent decode via the override setter lands on the correct file-relative frame.
- **FR-017**: A new regression test MUST cover the override-setter-after-decode-begins assertion, verifying that calling the setter once decode has started fails loudly rather than silently.
- **FR-018**: A regression test (or an extension of the existing end-to-end test) MUST cover at least one VFX clip from the production anamnesis gold master after re-import + relink, asserting the clip comes online, the source viewer displays a real frame at the override-space TC, and the playback engine does not trigger the `file_frame >= 0` invariant assertion when the playhead is parked on it.

**Production acceptance**

- **FR-019**: Re-importing the user's production "anamnesis" project followed by relink against the trimmed-fixture tree MUST produce a gold-master sequence where the ~12 VFX clips that currently fail because of Set Timecode overrides are all online and playable.

### Key Entities *(include if feature involves data)*

- **Media**: One imported source file. Key attributes for this feature:
  - **`start_tc_value`** (existing) — the master clip's displayed TC. Equals the Set Timecode override when one was applied in the authoring NLE; otherwise equals the file's container TC. Always present. Authoritative for display, source-range origin, and playback decoder TC anchoring.
  - **`file_original_timecode`** (new, optional) — the file's container TC as it existed at DRP authoring time (extracted from `BtAudioInfo.TracksBA.StartTime`). Populated only when it differs from `start_tc_value`. Plays two roles: (a) additional acceptance criterion for relink candidate matching, and (b) presence-as-signal that an override applies, triggering the EMP override setter at playback-open time.
- **Clip**: A timeline instance of a Media. No schema change, no coordinate-system change. Source ranges remain in `start_tc_value` space in all cases.
- **Relink Candidate**: An on-disk file whose basename matches a Media in the project. Its probed container TC is compared against BOTH the Media's `start_tc_value` and its `file_original_timecode` (when populated) to determine acceptance.
- **MediaFile (EMP)**: EMP's per-file handle. Gains exactly one new method: a TC origin override setter whose valid window is between open and first decode. The override mechanism lives at the `MediaFileInfo` layer and is codec-agnostic.

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

## Execution Status
*Updated by main() during processing*

- [x] User description parsed
- [x] Key concepts extracted
- [x] Ambiguities marked
- [x] User scenarios defined
- [x] Requirements generated
- [x] Entities identified
- [x] Review checklist passed

---
