# Feature Specification: JVE Color Management

**Feature Branch**: `024-jve-color-management`
**Created**: 2026-06-05
**Status**: Draft
**Input**: User description: see `## Original prompt` at bottom.

---

## ⚡ Quick Guidelines
- ✅ User-visible goal: "what I see in JVE matches what I see in Resolve for the same source"
- ✅ Project-level concept: every project has a *color science mode* that decides whether the renderer applies any color management beyond the per-clip grade
- ✅ Per-clip escape hatch: a clip whose embedded color tag is wrong/missing can be overridden
- ❌ Not in V1: HDR mastering, tone mapping, gamut compression, ACES Reference Gamut Compression, monitor calibration LUTs, scopes/false-color

---

## Clarifications

### Session 2026-06-07
- Q: Project color settings UI — Inspector section or modal dialog? → A: Modal project settings dialog, delivered by a separate feature. Out of scope for 024 — 024 owns the data model, persistence, and read-side renderer wiring; the user-facing dialog is not authored here.
- Q: V1 ambition for `davinci_yrgb_cm` and `aces` modes — record-only, YRGB CM apply, or both apply? → A: YRGB CM applies end-to-end; ACES is record-only with fidelity badge. Full ACES IDT/ODT apply deferred to a later spec.
- Q: Per-clip Input Color Space override + outbound DRT round-trip? → A: **JVE is read-only for color in V1.** No user-facing edit surface — no per-clip ICS override, no project color-settings edit UI, no outbound color writes through the bridge. JVE READS color metadata (source tags, bridge-recorded modes) and applies the correct display pipeline. All color *editing* surfaces deferred to a later spec.
- Q: Pixel-match tolerance — visual A/B vs Resolve, and CPU/GPU mirror? → A: **≤2/255 per channel visual (JVE preview vs Resolve preview); ≤1/255 per channel CPU/GPU mirror.** Visual tolerance sits at the edge of perceptibility on a calibrated display; mirror tolerance reflects what's achievable when both surfaces share tetrahedral interpolation and float32 math.
- Q: Fidelity badge values — reuse `partial`/`unrepresentable` or add new ones? → A: **Reuse `partial`** for both 024 cases (ACES record-only and LUT-color-space mismatch). Each badge case carries a descriptive tooltip naming the specific gap ("ACES mode — IDT/ODT not applied in V1", "LUT expects working color space X, project working space is Y") so the user sees WHY the badge fired, not just that it did.

---

## User Scenarios & Testing *(mandatory)*

### Primary User Story
The colorist opens a Resolve project in JVE via the bridge. The
source media is a mix of:
- BT.709-tagged ProRes 422 (the common case — already works as of 023),
- ProRes 4444 tagged `color_space=gbr` (matrix=identity, planes carry
  RGB) — today JVE shows a green hue cast vs Resolve's preview because
  the renderer assumes BT.709 YCbCr for every source.

After this feature ships, both source families render in JVE
matching Resolve's preview pixel-by-pixel within engineering tolerance,
with no per-clip configuration required for the common case. JVE V1
is read-only for color — the renderer applies the correct pipeline
based on source-embedded tags, bridge-recorded project color science,
and per-clip grade. A user-facing override surface for clips whose
embedded tag is wrong or missing is deferred to a future spec when
JVE supports color writes.

Separately, when the source Resolve project is in a color-managed mode
(YRGB Color Managed or ACES), the bridge must record which mode and
JVE's renderer must produce output that matches Resolve's preview
*for that mode*. In V1 the goal is correctness for the common
"vanilla YRGB" mode used by most Anamnesis-style projects; YRGB CM
and ACES are tracked so future work doesn't break the contract.

### Acceptance Scenarios

1. **Given** an open project with a ProRes 4444 source tagged
   `color_space=gbr` and an active per-clip primary grade,
   **When** the playhead lands on a frame of that clip,
   **Then** the rendered RGB pixels match Resolve's preview of the
   same frame at the same grade within ≤2/255 per channel.
2. **Given** an open project with a BT.709-tagged ProRes 422 source,
   **When** the playhead lands on a frame,
   **Then** the rendered output is unchanged from spec 023's behavior
   (no regression on the path that already works).
3. **Given** a clip whose embedded color tag is `unknown` (no
   per-clip override exists — JVE is read-only for color in V1),
   **When** the renderer pulls a frame for that clip,
   **Then** the renderer uses the project's default Input Color
   Space (FR-009) and the Inspector reads the assumption explicitly
   (e.g. "Rec.709 (project default — source tag missing)").
4. **Given** a Resolve project opened via the bridge,
   **When** the bridge records the link,
   **Then** the project's color science mode (`davinci_yrgb`,
   `davinci_yrgb_cm`, or `aces`) is recorded in the bridge link.
   On subsequent grade pulls the renderer's apply path matches
   Resolve's preview for the recorded mode in V1 for
   `davinci_yrgb` and `davinci_yrgb_cm` (full apply). `aces`
   projects render the per-clip grade only and surface a
   fidelity badge (FR-014) — full IDT/ODT apply deferred.
5. **Given** the source Resolve project's color science mode
   changes (e.g. the colorist switches the Resolve project from
   YRGB to YRGB CM) and the user re-runs `ConnectToResolveProject`
   or a grade-pull command,
   **When** the bridge re-records the link with the new mode,
   **Then** the renderer pulls the next frame through the new
   pipeline. (JVE is read-only for color — the mode change
   originates in Resolve and reaches JVE via the bridge, never
   via a JVE-side edit surface.)
6. **Given** a cold-start of any project with a graded clip at
   the sequence's initial playhead,
   **When** the first frame is rendered,
   **Then** the grade is applied on the first visible frame, not on
   a later frame (the deferred LUT3D upload race fixed 2026-06-05
   stays fixed — regression-guarded by an automated test).
7. **Given** a headless render or test path that exercises the CPU
   surface,
   **When** a clip with a 3D LUT is rendered through both the GPU
   surface and the CPU surface for the same source frame,
   **Then** the two outputs match within ≤1/255 per channel.

### Edge Cases
- A clip with no embedded color tag: the renderer uses the project's
  default Input Color Space (FR-009) and the Inspector reads the
  assumption explicitly ("Rec.709 (project default — source tag
  missing)"). No silent guess.
- The source Resolve project's color science mode changes between
  bridge syncs: the next grade-pull / connect updates the link, and
  the renderer re-pulls every visible clip through the new pipeline
  on the next show-frame. No stale-pixel persistence. (Mid-session
  mutation from a JVE-side edit surface is not possible — JVE is
  read-only for color in V1.)
- A 3D LUT applied at a point in the pipeline where the working
  color space differs from what the LUT expects: the renderer MUST
  surface a `partial` fidelity badge (reusing spec 023 FR-015
  vocabulary) with a tooltip naming the specific gap ("LUT expects
  working color space X, project working space is Y"), rather than
  silently producing wrong pixels.

## Requirements *(mandatory)*

### Functional Requirements

**Project-level color science**

- **FR-001**: A project MUST carry a *color science mode* setting,
  read-only from JVE's side, sourced from the bridge at link time
  (per FR-012) and defaulting to `davinci_yrgb` for projects not
  imported through the bridge. Closed-set enum: `davinci_yrgb`,
  `davinci_yrgb_cm`, `aces`. Persists across project close/open.
- **FR-002**: A project MUST carry a *working color space* and
  *output color space*, read-only from JVE's side, sourced from
  the bridge at link time and defaulting to Rec.709 for both when
  not bridge-imported. These exist for every mode so the model is
  uniform across `davinci_yrgb` / `davinci_yrgb_cm` / `aces`.
- **FR-003**: When the project color settings change (via bridge
  re-sync — the only write channel in V1), every visible clip's
  grade-pull MUST re-run on the next show-frame. No view-side
  cache invalidation gap.

**Per-clip Input Color Space override** *(deferred — JVE is
read-only for color in V1)*

User-facing per-clip ICS override surface is out of scope for 024.
JVE V1 honors the source-tag-derived Input Color Space (FR-008)
and falls back to the project default (FR-009) when the tag is
absent — both read-only. A future spec will add the user-facing
override (clip Inspector edit + outbound DRT round-trip behavior)
when JVE begins to support color writes.

**Decoder routing**

- **FR-007**: When a CVPixelBuffer source is tagged
  `color_space=AVCOL_SPC_RGB` (`gbr`), the decoder MUST allocate a
  hardware frames context that delivers a native RGB pixel buffer
  (skipping the YCbCr round-trip). The renderer's BGRA path then
  consumes it directly — no YCbCr→RGB matrix is applied to RGB
  source data.
- **FR-008**: When a CVPixelBuffer source is tagged with a known
  YCbCr matrix (`bt709`, etc.), the renderer applies that matrix.
  This preserves spec 023 behavior.
- **FR-009**: When a source's color tag is missing or unknown,
  the renderer MUST use the project's default Input Color Space
  (FR-002) and the Inspector MUST display the assumption
  explicitly (e.g. "Rec.709 (project default — source tag
  missing)"). No silent guessing — the Inspector readout is
  read-only in V1 and is the user's only visible signal that the
  renderer is assuming, not deriving.

**Renderer parity (CPU vs GPU)**

- **FR-010**: The CPU LUT3D apply path MUST match the GPU LUT3D
  apply path within per-channel tolerance. GPU was upgraded to
  tetrahedral on 2026-06-05; the CPU mirror MUST also be tetrahedral
  so headless renders and CPU/GPU comparison tests are pixel-aligned.
- **FR-011**: The GPU `setLut3D` upload MUST be safe across the
  cold-start init-race fixed on 2026-06-05 (a View pushing a grade
  before `initMetal` completes was previously dropped on the floor).
  An automated regression test MUST guard the cold-start path with
  a graded clip at the sequence's initial playhead.

**Bridge interaction**

- **FR-012**: The bridge `resolve_bridge_link` MUST record the
  source Resolve project's color science mode at link time.
- **FR-013**: On grade-pull, the renderer's apply path MUST honor
  the recorded mode such that the output matches Resolve's preview
  for that mode. V1 apply coverage:
  - `davinci_yrgb` (vanilla): correct end-to-end.
  - `davinci_yrgb_cm` (Color Managed): correct end-to-end —
    working-space → output-space transforms applied alongside the
    per-clip grade.
  - `aces`: **record-only**. Mode is persisted on the link and
    surfaced to the Inspector; pixel apply uses the per-clip grade
    only (no IDT/ODT). Clips in ACES projects MUST surface a
    `partial` fidelity badge per FR-014 with the tooltip
    "ACES mode — IDT/ODT not applied in V1" so the user sees
    why the preview is incomplete, not just that it is.
- **FR-014**: When the renderer can't faithfully reproduce Resolve's
  preview for a recorded mode (V1: `aces` mode) OR a 3D LUT is
  applied across a working-color-space mismatch (Edge Case), the
  affected clip MUST surface a `partial` fidelity badge (reusing
  spec 023 FR-015 vocabulary). Each badge case MUST carry a
  descriptive tooltip naming the specific gap (e.g. "ACES mode —
  IDT/ODT not applied in V1", "LUT expects working color space X,
  project working space is Y"). Never a silent fallback.

**UI surface**

- **FR-015**: The project color settings (FR-001/002) MUST be
  readable by any consumer (renderer, bridge, inspector readouts)
  via the project model. **User-facing edit UI is out of scope for
  024** — delivered by the separate Project Settings dialog feature.
  024 owns the data model, persistence, default values, and the
  read-side wiring; the dialog feature owns the write surface.
- **FR-016**: The clip Inspector MUST display the effective Input
  Color Space the renderer is using for the selected clip (derived
  from the source tag per FR-008, or the project default per
  FR-009 when the tag is absent), as a read-only readout. No edit
  control in V1 — overrides are deferred to a later spec.

**Invariants**

- **INV-1** (renderer pipeline): For every visible frame, the
  rendered RGB pixel is a function of (source pixels, source color
  tag, project color science mode, working color space, output
  color space, per-clip grade). No hidden state. (A future spec
  will reintroduce per-clip override as an input here once color
  writes are supported.)
- **INV-2** (no silent guesses): When a color decision can't be made
  from explicit data, the renderer MUST assert or surface a fidelity
  badge — never pick a plausible default and proceed silently.
- **INV-3** (CPU/GPU parity): For any non-pathological input, CPU
  and GPU surfaces produce pixels matching within tolerance.

### Out of Scope (V1 — explicit, do not expand)
- **All JVE-side color editing.** JVE V1 is read-only for color:
  no project-color-settings edit UI, no per-clip Input Color Space
  override, no outbound color writes through the bridge. The only
  write channel is bridge ingest (Resolve → JVE link records).
  Reintroduced by a future spec when JVE begins to support color
  writes.
- HDR mastering / tone mapping (HDR1000 timeline, PQ output, etc.)
- Gamut mapping / ACES Reference Gamut Compression
- Monitor calibration LUTs (`videoMonitorLUT`, `videoMonitor3DLUT`
  — these stay project-recorded only)
- Scopes, false-color, waveform monitor
- Full ACES IDT/ODT apply (V1 records `aces` mode + surfaces
  fidelity badge; clips render with per-clip grade only.
  Full IDT/ODT pipeline deferred to a later spec.)
- Custom OFX / OpenColorIO integration
- Sub-2.4 gamma offset tuning (BT.1886 etc.)

### Key Entities

- **ProjectColorSettings**: per-project. Attributes: color science
  mode (closed-set enum, V1 = `davinci_yrgb` | `davinci_yrgb_cm`
  | `aces`), working color space (default Rec.709), output color
  space (default Rec.709), default Input Color Space for untagged
  sources (default Rec.709). Persists in project file. **Read-only
  from JVE in V1**: populated by bridge ingest, never mutated by
  JVE-side commands.
- **ResolveBridgeLink** *(extended from spec 023)*: gains
  `source_color_science_mode`, `source_working_color_space`, and
  `source_output_color_space` — copied from Resolve's project
  settings at link time. Used by the renderer's apply path to pick
  the right pipeline and by ProjectColorSettings ingest to populate
  the project-level fields.

---

## Dependencies & Assumptions

- Builds on spec 023 (Resolve Color Bridge): the grade-pull
  machinery, fidelity badge vocabulary, and `resolve_bridge_link`
  table all come from 023. This spec extends them.
- macOS / Metal / VideoToolbox — same platform constraints as 023.
- ProRes 4444 + ProRes 4444 XQ are the immediate target source
  families for the gbr-decode-routing fix (FR-007).
- Source-of-truth for "what should it look like" is Resolve's
  preview on the same machine, with the QT-player gamma fudge OFF
  and "Use Mac display color profiles for viewers" OFF (project
  observations recorded in `todo_023_lut_color_mismatch.md`).
- Schema may bump freely (per project rule); project file is
  regenerated. No migration story required.

---

## Review & Acceptance Checklist

### Content Quality
- [x] No implementation details that bind to a specific framework
      (decode routing described by observable behavior, LUT
      interpolation by parity not code structure)
- [x] Focused on what the colorist sees and what the renderer guarantees
- [x] Mandatory sections completed

### Requirement Completeness
- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable (each FR has an observable
      acceptance condition)
- [x] Scope is clearly bounded (Out of Scope section explicit)
- [x] Dependencies on spec 023 identified

---

## Execution Status

- [x] User description parsed
- [x] Key concepts extracted
- [x] Ambiguities marked
- [x] User scenarios defined
- [x] Requirements generated
- [x] Entities identified
- [ ] Review checklist passed (gated on clarifications)

---

## Unresolved questions

- For YRGB CM apply (FR-013): does Resolve's `ExportLUT` in CM mode bake the full working→output transform, or only the node graph? Affects whether YRGB CM apply is "load baked LUT" (cheap) or "ship the transforms" (more work). Plan-phase spike.
- Default Input Color Space for untagged sources when project is `davinci_yrgb` — Rec.709 obvious, confirm?
