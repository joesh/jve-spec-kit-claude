# Feature Specification: Full-Fidelity Sequence Export to DaVinci Resolve

**Feature Branch**: `026-full-fidelity-drt`
**Created**: 2026-06-23
**Status**: Draft
**Input**: User description: "Full-fidelity DRT/DRP export — send ANY JVE sequence to DaVinci Resolve with confidence, not just the single-A005-video spike."

---

## User Scenarios & Testing *(mandatory)*

### Primary User Story

An editor working in JVE has a finished sequence containing a mix of footage:
arbitrary camera video (not the one baked-in test clip), standalone audio files
(e.g. a stereo `.wav` mix), and clips whose audio is synced to a separate
recording. They invoke **Send to Resolve** to continue in DaVinci Resolve for
grading. The exported timeline opens in Resolve with every clip online, playing
the correct picture and sound, at the correct source range and channel routing,
with the editor's clip markers intact —
indistinguishable from a timeline Resolve itself authored. Nothing is silently
dropped, offline, or misrouted. (Grades are not re-sent — they came from Resolve;
transitions/titles/generators, compound/nested clips, and sequence markers are
out of scope until JVE models them end-to-end.)

Today this only succeeds when every clip in the sequence is the single baked-in
test video. Any real sequence — the kind the editor actually cuts — fails: a
sequence with standalone audio crashes the export outright, and a sequence with
non-test video exports a file whose media shows offline in Resolve. This feature
closes that gap so the editor can trust Send to Resolve for any sequence.

### Acceptance Scenarios

1. **Given** a sequence whose only media is standalone audio (a stereo `.wav`
   with a real timecode origin), **When** the editor sends it to Resolve,
   **Then** the export succeeds (no crash) and Resolve imports a timeline whose
   audio clip is online, plays the correct content, starts at the correct
   timeline position, and reads from the correct source range.

2. **Given** a sequence mixing arbitrary video (any resolution / frame rate /
   path, not the baked-in test clip) with standalone audio tracks, **When** the
   editor sends it to Resolve, **Then** every video and audio clip is online in
   Resolve with its own correct file path, native rate, resolution, duration,
   and embedded-audio characteristics — none borrow another file's descriptors.

3. **Given** a video clip that carries synced audio from a separate recording
   (the editor sees them chain-linked as a sync group), **When** the editor
   sends the sequence to Resolve, **Then** Resolve presents the same sync
   relationship: the synced audio appears as a virtual track of the video's
   media-pool item, routed to the correct channel, not as an unrelated sibling.

4. **Given** an audio clip routed as mono, stereo, or synced multi-track in JVE,
   **When** the sequence is exported, **Then** Resolve plays the same channel
   routing the editor heard in JVE — mono stays mono, stereo stays stereo, the
   correct source channel feeds the correct output.

5. **Given** the anamnesis gold timeline (arbitrary video + standalone `.wav`
   audio tracks, including any synced groups), **When** the editor sends it to
   Resolve, **Then** the authored `.drt` passes JVE's own round-trip
   self-validation and matches Resolve-authored fixtures byte-for-byte (where the
   format is fixed) for every clip's video, audio, source range, and routing
   across the whole timeline. *(This is the headline acceptance gate; live-Resolve
   import is an optional spot-check, not the automated gate.)*

### Edge Cases

- **Audio-only media has no video timecode.** Its timecode origin lives in audio
  samples, not video frames. The export MUST read the audio timecode origin for
  audio media and MUST NOT crash demanding a video timecode that legitimately
  does not exist.
- **Two source clips over one physical file** (different trims / timecode
  treatment) must each still produce a distinct, correctly-identified item — the
  existing identity rule must continue to hold for audio and arbitrary-video
  items, not just the baked test clip.
- **A muted, reversed, non-unity-speed, or boundary-spanning clip** must export
  with the same fidelity as a plain clip (these are the configurations that
  break naive exporters).
- **A sequence with no media** must fail clearly and early (it already does);
  this feature must not weaken that.
- **Sub-frame source-in.** Resolve encodes source-in with sub-frame precision;
  JVE's source-in is whole-frame. Per clarification: **video** clip in/out export
  as whole frames (JVE's honest precision; Resolve's rate quantization applies);
  **audio** clip in/out export at sample-accurate fractional precision (audio is
  sample-positioned, not frame-positioned). The export MUST NOT shift content in
  either case.
- **Media offline on disk at export time.** Export proceeds: the media-pool item
  is authored from the file characteristics the JVE model already holds (probed at
  import — rate, resolution, channel layout, duration, timecode origin). The model
  is the authority, so a live file is not required at export. A required
  characteristic genuinely absent from the model is a should-never-happen
  invariant and MUST assert (it is not an expected, recoverable case).

## Clarifications

### Session 2026-06-24

- Q: How should this spec handle gap #5 (synced V↔A linkage, FR-014), which rides on a still-undecoded zstd blob? → A: Decode-spike first, then build — Phase 0 of this spec decodes the linkage region against fixtures; only then is it authored. Gap #5 stays in scope.
- Q: JVE source-in is whole-frame; Resolve encodes a sub-frame fractional double. What should the export emit? → A: Video clip in/out emit whole frames; audio clip in/out emit fractional (sample-accurate) precision.
- Q: When a clip's media file is offline on disk at export time, what should Send to Resolve do? → A: Proceed — author the pool item from the file characteristics the JVE model already holds (probed at import). The model is the authority; a genuinely missing required characteristic is a should-never-happen invariant (assert), not an expected case.
- Q: Should the export artifact stay `.drt`-only? → A: Whole-project `.drp` authoring is wanted but split to its own follow-on spec; **026 stays the single-timeline `.drt` path**. (Refined by the sequencing question below.)
- Q: How should whole-project `.drp` authoring be sequenced vs the per-clip fidelity work? → A: Split `.drp` into its own spec — 026 covers only the five fidelity gaps on `.drt`.
- Q: If the Phase-0 synced-linkage blob decode proves intractable, what's the fallback for gap #5? → A: No fallback — treat decode as must-succeed and keep iterating until cracked; 026 ships gap #5 fully or it is the blocker, never a partial/faked sync.
- Q: How should the FR-021 acceptance gate be verified? → A: Automated round-trip self-validation + byte-equality against Resolve-authored fixtures is the gate; live-Resolve import is an optional spot-check only (honors the no-live-Resolve-in-tests rule).
- Q: Should the `.drt` carry JVE's clip grades (1202 imported from Resolve) outbound? → A: No — grades are out of scope. They originated in Resolve and are not full quality; grading happens in Resolve, so JVE does not re-emit them.
- Q: Should the `.drt` carry markers (111 clip markers + sequence markers) outbound? → A: Yes — markers travel. 026 authors clip and sequence markers per phase0 §E. *(Superseded by the pre-plan audit below: sequence markers descoped — no JVE model; clip markers only.)*
- Q: How many sequences does one export cover? → A: Single active sequence only (the existing `payload_builder.build(sequence_id)` shape). Multi-sequence / whole-project is the deferred `.drp` spec's concern.
- Q: JVE doesn't model transitions/titles/generators — how should 026 handle "include transitions"? → A: Export everything JVE currently models — plain clips AND compound/nested clips. Transitions/titles/generators are deferred (JVE has no editing-model primitive for them); a sequence containing one fails loud rather than exporting it wrong. *(Partially superseded by the pre-plan audit below: compound/nested clips ALSO lack an end-to-end model + fixture and are deferred to their own spec; plain clips remain in scope.)*

### Session 2026-06-24 (pre-plan engineering audit)

Auditing this spec against ENGINEERING.md surfaced three evidence-based
feasibility/scope corrections:

- **Sequence markers descoped.** JVE models per-clip markers only (`clip_markers`
  table; `src/lua/models/clip_marker.lua`, `clip_id NOT NULL`). There is no
  sequence-marker model. Per "cannot export what the model cannot represent"
  (FR-019), FR-015/016 narrow to **clip markers**; sequence markers move to Out of
  Scope pending a JVE sequence-marker model. (Reverses the earlier "clip and
  sequence markers" answer on evidence.)
- **Compound / nested clips deferred.** Authoritative model inspection of the
  imported gold project (`/tmp/jve/anamnesis-gold-timeline.jvp`): the exported GOLD
  timeline places **555 leaf master-clip references and zero compound/nested
  placements** — every clip's `sequence_id` resolves to a leaf master (0 own clips),
  none to a nested timeline. (The media pool's "001_nested sequences" folder DOES
  import as standalone sequences — `timelapse-alt-reality`, `bernards-watch-trim`,
  etc. — but the active timeline references none of them.) So 026's acceptance never
  encounters a compound placement. Compound-placement *export* still has no
  Resolve-authored byte fixture and JVE has no end-to-end compound-placement export
  path, so FR-017 cannot meet the fixtures-only (FR-020) / round-trip (FR-021) gates
  and is **deferred to its own follow-on spec**. (Reverses the earlier "include
  nested" answer; verified against the model, not a raw-`.drp` string grep.)
- **Codec folded into gap #4 (FR-010).** The `<Clip>` descriptor's codec four-CC is
  hard-coded `avc1`/`AAC` at the writer call site (`drt_writer.lua:819/827`) though the
  encoder takes a real `codec` param (`drt_binary.lua:455`; schema `f5=codec` documented
  at `:421`). The model's `media.codec` column exists but is **empty for all imported
  media** (the DRP importer's `<Clip>` decode reads only path fields f1/f2). Folding
  codec into FR-010 therefore carries a bounded **import-side** addition: extend
  `decode_bt_clip_path` to also read `f5` → populate `media.codec` (the
  `importer_core.lua:859/880` passthrough already exists). Ripple to watch:
  `Media.classify_is_still` consumes `media.codec` — populating it can only sharpen
  still-image classification. (A005 stays green: its real codec IS h264/AAC.)
- **Interim acceptance gate added.** Gap #5 (synced linkage) is
  must-succeed/no-fallback and may block the feature; the whole-gold byte-equality
  gate (FR-021) would otherwise hold gaps #1–4 hostage. FR-021 now defines an
  interim gate — the non-synced subset of the gold timeline passing round-trip +
  byte-equality — as a first-class milestone independent of gap #5.

## Requirements *(mandatory)*

### Functional Requirements

#### Timecode & source range (audio media)

- **FR-001**: The export MUST derive each media item's timecode origin from the
  stream that actually carries it — audio samples for audio-only media, video
  frames for video media — and MUST NOT fail an export because audio-only media
  lacks a video-frame timecode.
- **FR-002**: For audio media, the exported source-in offset and clip start
  offset MUST be computed in the media's audio sample units (at the media's
  sample rate) so that the exported clip reads the same audio content the editor
  heard in JVE.
- **FR-003**: The exported source range for every clip — audio or video — MUST,
  when imported into Resolve, address the same source content (same in/out) the
  editor had on the JVE timeline. Video clip in/out MUST export as whole frames;
  audio clip in/out MUST export at sample-accurate fractional precision (audio is
  sample-positioned). Neither MUST shift the content the editor had.

#### Standalone audio media-pool item

- **FR-004**: A standalone audio file used by the sequence MUST export as its own
  audio media-pool item (the artifact Resolve uses for non-embedded audio), so
  that Resolve resolves the clip's media reference instead of dropping the clip.
- **FR-005**: The audio media-pool item's shape MUST match a Resolve-authored
  reference exactly (byte-for-byte where the format is fixed), derived only from
  an existing Resolve-authored fixture — no invented byte forms.
- **FR-006**: The export MUST handle audio file types present in real sequences
  (at minimum `.wav`) rather than rejecting any non-video file.

#### Payload-driven audio routing

- **FR-007**: The exported per-clip audio routing MUST reflect the clip's actual
  routing in JVE (mono, stereo, or synced multi-track) rather than a single
  hard-coded mono routing.
- **FR-008**: The exported source-channel / track selection MUST identify the
  correct source channel of the correct media stream, so the channel the editor
  monitored in JVE is the channel Resolve plays.
- **FR-009**: The three observed routing relationships — embedded channel of a
  video file, a linked channel of a synced recording, and an own-channel of a
  standalone audio file — MUST each export to the routing form Resolve uses for
  that relationship, matched against Resolve-authored references.

#### Arbitrary (non-test-clip) video media-pool item

- **FR-010**: Each video media-pool item MUST carry that file's own file path,
  native rate, resolution, **codec**, duration, and embedded-audio characteristics —
  it MUST NOT borrow another file's descriptors or a hard-coded constant. The codec
  four-CC travels in the `<Clip>` descriptor (phase0 §K3; `f5` of the blob); because
  the DRP importer does not currently populate `media.codec`, closing this gap
  includes extending the importer's existing `<Clip>` decode (path) to also read the
  codec field, so the model holds the real codec to author from. A media item whose
  codec is genuinely unknown MUST fail loud (FR-019), never author a wrong four-CC.
- **FR-011**: A video clip that is not the baked-in test clip MUST export to a
  media-pool item that Resolve treats as online and reads from the correct file,
  with the correct picture characteristics.
- **FR-012**: The synthesized video media-pool item's structure MUST conform to a
  Resolve-authored reference; every field whose value is file-specific MUST come
  from the clip's media, and every field whose form is fixed MUST match the
  reference.

#### Synced-audio video↔audio linkage

- **FR-013**: When a video clip carries synced audio from a separate recording,
  the export MUST encode the sync relationship such that Resolve presents the
  synced audio as a virtual track of the video's media-pool item (not as an
  unrelated clip).
- **FR-014**: A synced group that round-trips through export and re-import MUST
  preserve which audio source is synced to which video, and on which virtual
  track. The linkage carrier is a compressed, not-yet-decoded blob on the video
  media-pool item. This feature's **Phase 0 MUST decode that blob's linkage region
  against Resolve-authored fixtures** before the linkage is authored; the writer
  MUST synthesize the linkage from the decoded structure, not borrow a fixture's
  specific sync verbatim (verbatim-borrow only reproduces one fixture's group, not
  arbitrary ones). The decode is treated as **must-succeed with no fallback**:
  there is no degraded/heuristic synced-authoring path. Until Phase 0 cracks the
  blob, synced authoring is blocked (a synced clip causes a loud failure) — never
  faked or approximated.

#### Markers (outbound)

- **FR-015**: The export MUST carry the sequence's **clip markers** into the `.drt`
  so they appear in Resolve, attaching at the project level by (clip identity,
  marker) per the encoding dissected in phase0 §E. (Sequence markers are out of
  scope — JVE has no sequence-marker model; see Out of Scope.)
- **FR-016**: The clip-marker byte form (the clip-marker lockable blob) MUST be
  traceable to a Resolve-authored fixture — no invented marker encoding.

#### Compound / nested clips

- **FR-017**: *Deferred to a follow-on spec.* Compound/nested-clip export has no
  Resolve-authored fixture to derive byte forms from (FR-020) or round-trip against
  (FR-021), and JVE has no end-to-end compound-placement export path. The acceptance
  gold timeline places zero compound clips (verified: 555 leaf master references, no
  nested-sequence placements on the active timeline), so the feature can ship without
  it. A sequence that *does* place a compound clip MUST fail loud (FR-019) rather
  than export it wrong. See Out of Scope.

#### Export artifact (`.drt` timeline, single active sequence)

- **FR-018**: The export produces a single-timeline `.drt` imported into the
  currently-open Resolve project (the existing path), preserving the round-trip
  self-validation it performs before sending. Whole-project `.drp` authoring is
  **out of scope for this spec** — it is deferred to a separate follow-on spec
  (see Clarifications / Out of Scope). All five fidelity gaps below apply to the
  `.drt` path.

#### Cross-cutting fidelity & safety

- **FR-019**: The export MUST NOT silently drop, skip, or substitute any clip,
  track, or media reference. A clip that cannot be faithfully exported MUST cause
  a loud, actionable failure naming the offending clip/media — never a fallback
  or a quiet omission.
- **FR-020**: Every byte form the export emits MUST be traceable to a
  Resolve-authored fixture; the feature MUST NOT introduce any wire form that
  cannot be pointed to in such a fixture.
- **FR-021**: The full anamnesis gold timeline MUST export to a `.drt` that passes
  JVE's round-trip self-validation and matches Resolve-authored fixtures
  byte-for-byte (where the format is fixed) for video, audio, source ranges, and
  routing — this automated check is the feature's definition of done. Live-Resolve
  import is an optional spot-check, not the gate (per the no-live-Resolve-in-tests
  contract rule). **Interim gate:** the non-synced subset of the gold timeline
  passing round-trip + byte-equality is a first-class milestone, so gaps #1–4 are
  demonstrably complete independent of gap #5 (synced linkage), which is
  must-succeed/no-fallback and may otherwise block the whole-gold gate.
- **FR-022**: Existing single-test-clip exports MUST continue to produce
  byte-identical output (no regression of the cases that already work).

### Key Entities *(include if feature involves data)*

- **Sequence export payload**: The neutral description of a sequence handed to the
  writer — project, sequence (rate, resolution), the set of distinct media items
  it references, and per-track ordered clips with their source ranges, routing,
  and identity. Must now carry audio timecode origin (in samples), per-clip audio
  routing, and synced-linkage information, not just video fields.
- **Media item (video)**: A physical video file referenced by the sequence —
  carries file path, native rate, resolution, codec, duration, and embedded-audio
  characteristics. Each distinct source clip over the file is a distinct item by
  identity.
- **Media item (audio)**: A standalone audio file referenced by the sequence —
  carries file path, sample rate, channel layout, duration (in samples), and
  audio timecode origin (in samples). Has no video characteristics.
- **Clip placement**: A clip on a track — its timeline start, duration, source-in,
  identity, the media item it reads, and (for audio) its routing and source
  channel/track selection.
- **Routing descriptor**: The per-clip statement of how a source channel feeds
  the output — mono / stereo / synced — and which source stream and channel it
  selects.
- **Synced linkage**: The relationship binding a separately-recorded audio source
  to a video media item as a virtual track, so a sync group survives the round
  trip.

### Out of Scope

- **Whole-project `.drp` authoring** (project + media pool + folders + gallery as a
  standalone archive). Wanted, but deferred to its own follow-on spec; 026 is the
  single-timeline `.drt` path only. The `.drp` fixtures remain ground-truth byte
  sources for both specs.
- **Grade outbound.** JVE's clip grades originated in Resolve and are not full
  quality; grading happens in Resolve, so the `.drt` does NOT re-emit grades.
  Grade encoding (phase0 §G `pLmVerTable`) belongs with the color bridge (023).
- **Transitions, titles, generators.** JVE has no editing-model primitive for
  these (no schema/model representation). 026 cannot export what the model can't
  represent; a sequence containing one MUST fail loud (FR-019), never export it
  wrong. Deferred until JVE gains an editing model for them.
- **Sequence markers.** JVE models per-clip markers only (`clip_markers`); there is
  no sequence-marker model. Cannot export what the model cannot represent. Deferred
  until JVE gains a sequence-marker model. Clip markers ARE in scope (FR-015/016).
- **Compound / nested clips.** No Resolve-authored fixture exists to derive or
  round-trip the compound-placement form, and JVE has no end-to-end compound-placement
  export path. The acceptance gold timeline places none (verified against the imported
  model: 555 leaf master references, zero nested-sequence placements). Deferred to its
  own follow-on spec; a sequence that places one MUST fail loud (FR-017 / FR-019),
  never export wrong.
- **Multiple sequences per export.** One active sequence per Send to Resolve.

---

## Review & Acceptance Checklist
*GATE: Automated checks run during main() execution*

### Content Quality
- [x] Focused on user value and editing-domain outcomes
- [x] Written for stakeholders who know the editing / Resolve domain
- [x] All mandatory sections completed
- [x] Describes WHAT the export must achieve, not HOW the writer is coded

### Requirement Completeness
- [x] No [NEEDS CLARIFICATION] markers remain (resolved in Session 2026-06-24)
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable (round-trip + byte-equality on gold timeline)
- [x] Scope is clearly bounded (5 fidelity gaps + clip markers, on `.drt`; grades/transitions/sequence-markers/compound-nested/`.drp` out)
- [x] Dependencies and assumptions identified (Resolve-authored fixtures = truth)

---

## Execution Status
*Updated by main() during processing*

- [x] User description parsed
- [x] Key concepts extracted
- [x] Ambiguities marked
- [x] User scenarios defined
- [x] Requirements generated
- [x] Entities identified
- [x] Review checklist passed (clarifications resolved Session 2026-06-24)

---

## Notes for /clarify and /plan

- Ground-truth fixtures (all in `tests/fixtures/resolve/`): `anamnesis-gold-timeline.drp`
  (mono + stereo audio), `resolve_authored_full.drp` (real standalone-audio
  media-pool item), `retime-test.drt`, plus the dissection in
  `specs/023-resolve-color-bridge/phase0-findings.md` (§B/§C/§F/§K2/§K3/§K3b/§K3c/§K4).
- This feature is a follow-on to spec 023 but is its own deliverable.
- Clarifications resolved (Session 2026-06-24): source-in precision is split
  video=whole-frame / audio=fractional (FR-003); synced linkage needs a Phase-0
  decode spike before authoring, must-succeed no-fallback (FR-014); offline media
  exports from cached model characteristics (Edge Cases); artifact is `.drt` only,
  whole-project `.drp` split to its own follow-on spec (FR-018 / Out of Scope);
  acceptance gate is automated round-trip + byte-equality, not live Resolve (FR-021).
- `/plan` should lead with Phase 0 (synced-linkage blob decode) as the single
  largest unknown and the gate for gap #5; the other four gaps can proceed in
  parallel against fixtures.
