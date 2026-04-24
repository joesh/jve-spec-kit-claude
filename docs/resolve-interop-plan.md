# Resolve Interop Plan — Import/Export Channels

Status: PROPOSED (unresolved questions at bottom)
Scope: interop between JVE and DaVinci Resolve — importing Resolve projects into JVE, exporting JVE projects back to Resolve.
Related docs: `DRP_FORMAT_SPEC.md`, `DRP_BLOB_FIELDS.md` (existing DRP import work, spec 009).

## Context

JVE already has DRP import (spec 009). Open questions:
1. Can we import Resolve's `Timeline.<ts>` autosave backup files (protobuf + zstd, v20 & v21)?
2. Can we export JVE projects into a form Resolve can load as a **project** (not just a timeline)?

FCPXML alone is insufficient — it's a timeline description, thin on bins / clip metadata / custom fields / bin hierarchy. Real project transfer needs a richer channel.

## Verified format findings (2026-04-21)

Both **Resolve v20 Timeline backups** (`~/Movies/Resolve Project Backups/<proj-uuid>/<timeline-uuid>/Timeline.<ts>`) and **v21 beta Timeline backups** share the same container and mostly the same schema.

- Container: `[9-byte header][zstd-compressed payload]`
  - First 4 bytes: `00 00 00 01` (format version 1, identical v20 & v21)
  - Bytes 4–8: still undecoded (likely size/CRC — not blocking)
  - Byte 8: `0x81` marker immediately before zstd magic
  - Bytes 9+: zstd frame (magic `28 B5 2F FD`)
- Payload: protobuf wire-format message.
- Inside the payload, **140 additional inline zstd frames** were recovered in a v21 sample — mostly Fusion compositions serialized as Lua-table text, plus small per-track/per-clip sub-messages.

### Schema stability v20 ↔ v21 beta (from wire-format path diff)

- **183 field paths shared** between v20 and v21 samples.
- **27 paths only in v21** (additive — new sub-message at `2.3.18.4.*`, new top-level `2.3.30`/`2.3.32`, new clip-header fields `1.1.1.2`/`.3`/`.10`).
- **64 paths only in v20** — mostly unused-in-this-timeline fields.
- Conforming protobuf parsers ignore unknown fields, so v20's loader can most likely read v21 files cleanly modulo a version gate.

### Implication

The `Timeline.<ts>` format is **Resolve's internal serialization**, not an export format. The same protobuf blobs live inside DRP bundles and inside Resolve's DB BLOB columns. Understanding one format gives us most of the other two for free.

## Interop options — capability matrix

| Requirement | Timeline.* import | FCP7 XML / FCPXML export | Scripting API export | DRT export | DRP export | Direct DB write |
|---|---|---|---|---|---|---|
| Timeline clips + IO + record | Yes | Yes | Yes | Yes | Yes | Yes |
| Bins / folder hierarchy | Yes | Partial | Yes | Partial | Yes | Yes |
| Clip metadata (std + custom) | Yes | Thin | Yes | Yes | Yes | Yes |
| Flags / colors / keywords | Yes | Partial | Yes | Yes | Yes | Yes |
| Clip markers + metadata | Yes | Partial | Yes | Yes | Yes | Yes |
| Subclips | Yes | Partial | Yes | Yes | Yes | Yes |
| Proxy / offline paths | Yes | Partial | Partial | Yes | Yes | Yes |
| Multiple timelines | Yes | No (one per file) | Yes | No | Yes | Yes |
| Color grades | Opaque blob | No | Partial (LUTs/stills) | Yes | Yes | Yes |
| Fusion comps | Opaque blob | No | Reference only | Yes | Yes | Yes |
| Project settings | Yes | Partial | Yes | Partial | Yes | Yes |
| Async handoff (file to user) | N/A (read) | Yes | No | Yes | Yes | No |
| Live handoff (Resolve open) | N/A | No | Yes | No | No | No |
| Documented / supported | No (RE) | Yes | Yes | No (RE) | No (RE) | No (RE) |
| Breaks on Resolve updates | Rare (additive) | Rare | Rare | Likely | Likely | Highly likely |
| Studio + Project Server OK | N/A | Yes | Yes | Yes | Yes | Partial (SQLite only) |
| ToS friction | None | None | None | None | None | Meaningful |

"RE" = requires reverse engineering a format Blackmagic does not document or guarantee.

## Options — analyzed

### 1. Timeline.* backup importer (parallel to DRP import)

Read `Timeline.<ts>` files directly. Useful both for recovering timelines when `.drt`/`.drp` isn't available and for users who back up via Resolve's autosave folders.

Effort estimate: **~4–6 weeks**.

Phases:
- Wire walker + nested zstd peeling (1–2 days)
- Schema inference via controlled Resolve experiments (2 weeks)
- QVariantMap decoder for inline Qt blobs (2–3 days)
- IR bridge to JVE model (1 week) — reuses importer_core (prproj plan)
- Fusion comps (stored as opaque text; 3–4 days)
- Validation harness (1 week) — round-trip vs DRT-imported same project

Why tractable: wire format is self-describing; Resolve v20 itself is the ground-truth oracle for every field (create project → save → diff). Additive schema evolution means code written against v20 likely reads v22+.

Risk: QVariantMap + Fusion Lua semantics are the long tail.

### 2. XML exporters — FCP7 XML vs FCPXML 1.x

Both are timeline-level XML formats with wide NLE support. **Neither satisfies "project transfer"** on its own — both are thin on bin hierarchy and arbitrary metadata. Kept in consideration as secondary interop paths for cross-NLE handoff where timeline-level is acceptable.

Key axes:

| Axis | FCP7 XML | FCPXML 1.x |
|---|---|---|
| Status | Frozen spec (~2009) | Actively evolving, Apple-owned |
| Timeline model | Tracks + clipitems | Primary storyline + connected lanes |
| Model impedance with JVE | **None** (maps 1:1) | **Real** — tracks→lanes translation |
| Time model | Frame-based, NTSC quirks | Rational (clean 23.976/29.97) |
| Bin hierarchy | Flat | 2-deep (library/event) |
| Custom metadata fields | Fixed set | Keywords, ratings, metadata-by-key |
| Subclips | No | Partial |
| Speed / retimes | Yes | Yes |
| Color grades | No | No (keywords only) |
| Resolve import quality | Good, predictable | Good, occasional lane→track surprises |
| Premiere / Avid import | Yes / via 3rd-party | Yes / limited |
| FCP X import | No | Yes |
| Effort to export from JVE | **~1 week** | **~1.5–2 weeks** (translation layer) |

**Recommendation if we pick one: FCP7 XML.** Reasons:
- Track-and-clip model maps 1:1 to JVE's domain — no translation bugs, no information loss on export.
- Half the effort.
- Resolve and Premiere import is predictable; FCPXML's lane→track remapping can produce surprising extra video tracks.
- FCPXML's marginal advantage (keyword + per-key metadata) is moot for JVE once the Scripting API exporter exists, which carries metadata properly via `SetMetadata` / `SetClipProperty`.

Pick FCPXML only if a concrete need for FCP X support or keyword round-trip appears — neither is on the current radar.

### 3. Scripting API exporter (DaVinciResolveScript)

BMD's official Python/Lua API. Documented in `/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/`.

Coverage relevant to project transfer:
- `ProjectManager.CreateProject(name)`
- `MediaPool.AddSubFolder(folder, name)` — bin hierarchy
- `MediaPool.ImportMedia(paths)`
- `MediaPoolItem.SetClipProperty(prop, value)` — Scene, Shot, Take, Reel, Good Take, Keywords, Comments, Description, Flags, Color
- `MediaPoolItem.SetMetadata(dict)` — custom fields
- `MediaPool.CreateSubClip(...)`
- `AppendToTimeline(clips)`, timeline markers, in/out, retimes

Ceiling: color grades (partial via LUTs/PowerGrade import), Fusion comps (reference only), per-effect keyframe automation.

Per CLAUDE.md JVE doesn't model color/Fusion anyway — API ceiling ≈ JVE ceiling, so this is a real project-transfer channel for us.

Effort estimate: **~3–4 weeks**.

Phases:
- Bin tree + media pool + clip metadata + custom fields (1 week)
- Timelines, clips, markers, in/out, speed (1 week)
- Subclips, proxies, project settings (1 week)
- Validation harness (3–5 days)

Advantages: documented, supported, no reverse engineering, works on Studio + Project Server.

Limitation: requires Resolve running during handoff. Only useful for live handoff, not archival file transfer.

### 4. DRT exporter (timeline-only file)

ZIP + `project.xml`. Reverse-engineered schema from Resolve-produced samples. **~3–5 weeks.** Brittle per Resolve release. Strictly a timeline channel — does not satisfy "project transfer" goal on its own. Useful as drag-drop-to-Resolve-bin UX or as a component inside a DRP bundle.

### 5. DRP exporter (full project file)

Full project bundle. Standalone answer: **~6–10 weeks**, brittle, fabricates defaults for subsystems JVE doesn't model.

**However:** if the Timeline.* importer (option 1) is on the roadmap, the protobuf writer is roughly 50% shared with DRP export. Incremental DRP cost drops to **~3–5 weeks** in that sequence.

DRP contents (from existing import work):
```
DRP = ZIP{
  project.xml or project.proto,  # bin tree, media pool, project-level metadata
  Timelines/Timeline.<uuid>,      # protobuf — shared with Timeline.* importer
  MediaPool/...,
  ...
}
```

### 6. Direct DB writes

Resolve's project DB (SQLite free, Postgres Studio). Reject: rich data in BLOB columns is the same protobuf as `Timeline.*`, so no work saved; adds SQL schema + FK + invariant burden; blast radius is runtime corruption across other timelines in the same project; ToS friction; does not work while Resolve is open; Postgres path requires separate effort. Dominated by the Scripting API on every axis we care about. **Don't build.**

## Recommended sequence

**Path C — combined, front-load user value.** Total **~11–15 weeks** for comprehensive import + export coverage.

1. **Scripting API exporter first (3–4 weeks).** Ships interop value immediately. Covers "live handoff" use case fully. Zero reverse engineering. No brittleness to Resolve releases. Gives us time to observe actual user workflows before committing to file-format exports.

2. **Timeline.* importer (4–6 weeks, can overlap phase 1 tail).** Plug with existing DRP importer. Delivers recovery-of-backups feature for users caught by Resolve beta regressions or lost `.drt`/`.drp` files. Produces the protobuf read/write layer that DRP export reuses.

3. **DRP exporter (+3–5 weeks incremental).** Reuses protobuf writer from step 2. Satisfies archival / file-handoff project-transfer use case.

4. **FCP7 XML exporter (~1 week, deferred).** Only if a cross-NLE handoff workflow materializes. Low value compared to 1/3 for the Resolve-specific project-transfer goal, but cheap to add. Pick FCP7 XML over FCPXML: same model as JVE (track+clipitem), half the effort, no translation layer. FCPXML only if FCP X support or keyword round-trip becomes a concrete requirement.

5. **DRT exporter** — skip unless a concrete use case that DRP/Scripting API can't satisfy emerges. DRT is a subset of DRP; building both is duplicative.

6. **Direct DB writes** — don't build.

## Architectural notes

- All file-format work shares `importer_core.lua` (extraction planned in prproj importer plan) as the common IR.
- Protobuf read/write is a shared module that Timeline.* importer, DRP importer, and DRP exporter all use.
- Scripting API exporter is self-contained — emits a Python script, executes via Resolve's bundled interpreter or system Python.
- Per rule 1.14: unknown protobuf fields in wire-type contexts we understand → `event`-level log + skip. Unknown fields in structural slots we depend on → assert with field path.
- Per rule 2.21: importer/exporter format specs live in their own modules; no format-specific logic in command handlers or UI.
- Validation harness (per format) is mandatory, not optional. Round-trip: JVE project → export → Resolve → re-export → compare. Domain-behavior black-box tests per CLAUDE.md (e.g., "after re-import, clip plays same content at same record frame").

## Verified artifacts from today's investigation

- `/tmp/timeline_v21_latest.bin` — decompressed v21 beta Timeline backup payload
- `/tmp/timeline_v20_sample.bin` — decompressed v20 Timeline backup payload
- `/tmp/v21_frames/` — 140 inner zstd frames extracted
- `/tmp/timeline_v21_salvage.txt` — salvage report for a specific v21-beta-can't-load case (recovery use case for the importer)
- `/tmp/v20_raw.txt`, `/tmp/timeline_v21_raw.txt` — protoc raw decode of both payloads (shows schema overlap)

Re-run with: `dd if=<Timeline.xxx> bs=1 skip=9 | zstd -d | protoc --decode_raw`.

## Unresolved questions

- Live handoff vs archival file — which first? (rec: Scripting API first — phase 1 of Path C)
- Must color grade / Fusion round-trip, or is media pool + timelines + metadata enough? (shapes DRP scope)
- Target Resolve versions: v20 only, or v20 + v21 from day 1?
- Round-trip required (JVE ↔ Resolve ↔ JVE), or one-way? (round-trip multiplies validation cost)
- Python-on-host acceptable for Scripting API path, or must be pure-Lua-no-deps?
- Studio + Project Server from day 1, or SQLite-free only first?
- Who owns maintenance when Resolve releases change schemas?
- Timeline.* importer scope: clips+tracks+markers+transitions v1, or full (incl. color/Fusion as opaque blobs)?
- DRP-level import wanted too, or individual Timeline.* backup only?
- Does this effort replace current DRP importer or live alongside it?
