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
with no per-clip configuration required for the common case. When a
clip's embedded tag is wrong or missing (rare but real), the colorist
can override its Input Color Space from the Inspector and the renderer
honors the override.

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
   same frame at the same grade, within a per-channel ΔE of
   [NEEDS CLARIFICATION: pixel-match tolerance not specified —
   propose ≤2/255 per channel for visual match, ≤1/255 for
   CPU/GPU mirror].
2. **Given** an open project with a BT.709-tagged ProRes 422 source,
   **When** the playhead lands on a frame,
   **Then** the rendered output is unchanged from spec 023's behavior
   (no regression on the path that already works).
3. **Given** a clip whose embedded color tag is `unknown` or wrong,
   **When** the user opens the Inspector and selects an explicit
   "Input Color Space" override,
   **Then** the renderer honors the override on the next show-frame
   and the value persists across project close/open.
4. **Given** a Resolve project opened via the bridge,
   **When** the bridge records the link,
   **Then** the project's color science mode (e.g. "DaVinci YRGB",
   "DaVinci YRGB Color Managed", "ACES") is recorded in the
   bridge link, and on subsequent grade pulls the renderer's
   apply path matches Resolve's preview for that mode (V1: at
   minimum, the vanilla YRGB case is correct; non-vanilla modes
   are recorded but may render with a fidelity badge per
   spec 023 FR-015).
5. **Given** any project,
   **When** the user opens Project Settings → Color,
   **Then** the user can read the current color science mode,
   working color space, and output color space, and can change them.
   The renderer reflects the change on the next show-frame.
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
   **Then** the two outputs match within
   [NEEDS CLARIFICATION: CPU/GPU pixel-match tolerance — propose
   ≤1/255 per channel given both use tetrahedral interpolation].

### Edge Cases
- A clip with no embedded color tag and no per-clip override under a
  project mode where "auto-detect" can't decide: the renderer MUST
  fall back to the project's default Input Color Space (project
  setting) and surface the assumption to the UI (Inspector reads
  "Input Color Space: Rec.709 (project default)" rather than silently
  guessing).
- A clip whose embedded color tag contradicts the per-clip override:
  the override wins. The Inspector shows the override + a tooltip
  noting the embedded value.
- The project's color science mode changes mid-session (user toggles
  YRGB → YRGB CM in Project Settings): the renderer MUST re-pull
  every visible clip's grade through the new pipeline on the next
  show-frame. No stale-pixel persistence.
- A 3D LUT applied at a point in the pipeline where the working
  color space differs from what the LUT expects: the renderer MUST
  surface this as a "color space mismatch" fidelity warning (badge
  reuses spec 023 FR-015 vocabulary) rather than silently producing
  wrong pixels.

## Requirements *(mandatory)*

### Functional Requirements

**Project-level color science**

- **FR-001**: A project MUST carry a *color science mode* setting,
  with at minimum the values `davinci_yrgb` (default, vanilla), and
  placeholders for `davinci_yrgb_cm` and `aces` so future expansion
  doesn't require schema churn. Persists across project close/open.
- **FR-002**: A project MUST carry a *working color space* and
  *output color space*, defaulting to Rec.709 for both. These exist
  even in `davinci_yrgb` mode (where they are advisory only) so
  the model is uniform across modes.
- **FR-003**: Changing any project color setting MUST cause every
  visible clip's grade-pull to re-run on the next show-frame. No
  view-side cache invalidation gap.

**Per-clip Input Color Space override**

- **FR-004**: A clip MUST be able to carry an optional Input Color
  Space override. Absence means "use embedded tag, falling back to
  project default if no tag".
- **FR-005**: When present, the override is the source of truth for
  the renderer's matrix selection. The Inspector MUST render the
  embedded tag as a tooltip / secondary text when the override
  disagrees.
- **FR-006**: The override persists across project close/open and
  is included in the bridge's outbound DRT serialization
  [NEEDS CLARIFICATION: does Resolve's Input Color Space round-trip
  through DRT? If not, an outbound DRT with an overridden clip
  loses the override on Resolve's side — call out as a known
  limitation or scope it out].

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
- **FR-009**: When a source's color tag is missing or unknown AND
  no per-clip override is set, the renderer MUST use the project's
  default Input Color Space (FR-002 / FR-005) and surface the
  assumption to the Inspector (no silent guessing).

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
  for that mode. V1: vanilla `davinci_yrgb` is correct end-to-end.
  Non-vanilla modes are recorded but render with the existing
  spec 023 FR-015 fidelity-badge framework rather than producing
  silently-wrong pixels.
- **FR-014**: When the renderer can't faithfully reproduce Resolve's
  preview for a recorded mode (e.g. YRGB CM in V1), the affected
  clip MUST surface a fidelity badge (reusing spec 023 vocabulary)
  — never a silent fallback.

**UI surface**

- **FR-015**: The user MUST be able to read and change the project
  color settings (FR-001/002) from a single UI surface
  [NEEDS CLARIFICATION: Inspector section ("Project" inspectable
  gets a Color group) vs modal "Project Settings → Color" dialog.
  Per JVE convention so far, Inspector wins for live state and
  modal wins for one-off config — color settings are read-often,
  written-rarely, so probably Inspector. Confirm.].
- **FR-016**: The user MUST be able to read and change a clip's
  Input Color Space override (FR-004/005) from the clip Inspector.

**Invariants**

- **INV-1** (renderer pipeline): For every visible frame, the
  rendered RGB pixel is a function of (source pixels, source color
  tag, per-clip override, project color science mode, working color
  space, output color space, per-clip grade). No hidden state.
- **INV-2** (no silent guesses): When a color decision can't be made
  from explicit data, the renderer MUST assert or surface a fidelity
  badge — never pick a plausible default and proceed silently.
- **INV-3** (CPU/GPU parity): For any non-pathological input, CPU
  and GPU surfaces produce pixels matching within tolerance.

### Out of Scope (V1 — explicit, do not expand)
- HDR mastering / tone mapping (HDR1000 timeline, PQ output, etc.)
- Gamut mapping / ACES Reference Gamut Compression
- Monitor calibration LUTs (`videoMonitorLUT`, `videoMonitor3DLUT`
  — these stay project-recorded only)
- Scopes, false-color, waveform monitor
- Full ACES IDT/ODT family beyond the placeholder mode value
- Custom OFX / OpenColorIO integration
- Sub-2.4 gamma offset tuning (BT.1886 etc.)

### Key Entities

- **ProjectColorSettings**: per-project. Attributes: color science
  mode (closed-set enum, V1 = `davinci_yrgb` | `davinci_yrgb_cm`
  | `aces`), working color space (default Rec.709), output color
  space (default Rec.709), default Input Color Space for untagged
  sources (default Rec.709). Persists in project file.
- **ClipColorOverride**: per-clip, optional. Attribute: Input Color
  Space override value. Absence = "use embedded tag or project
  default". Persists in project file.
- **ResolveBridgeLink** *(extended from spec 023)*: gains
  `source_color_science_mode` — the value of Resolve's
  `colorScienceMode` setting at link time. Used by the renderer's
  grade-apply path to pick the right pipeline.

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
- [ ] No [NEEDS CLARIFICATION] markers remain (3 outstanding —
      see Unresolved questions below)
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

- pixel tol vs Resolve? (≤2/255 visual / ≤1/255 mirror — propose, confirm)
- CPU/GPU tol? (≤1/255 — propose, confirm)
- Input Color Space round-trip through DRT — supported by Resolve? if no, scope-out outbound override or accept loss?
- Project Color Settings UI — Inspector section or modal? (Inspector recommended)
- V1 ambition for `davinci_yrgb_cm` and `aces` — record-only with fidelity badge, or attempt apply?
- ACES placeholder mode — keep as enum value or drop until V2?
- Per-clip override storage — column on `clips` table or side table?
- Default Input Color Space for untagged sources when project is `davinci_yrgb` — Rec.709 obvious, confirm?
- Fidelity badge — new value for "color-mode-mismatch" or reuse existing "partial"?
