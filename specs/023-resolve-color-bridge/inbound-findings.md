# Inbound findings — live grade pull + identity (T047 and beyond)

**Run:** 2026-05-29, against live DaVinci Resolve **Studio 20.3.2.9** (read-only on Joe's `2026-03-20-anamnesis joe edit` / `2026-03-28-anamnesis-GOLD-MASTER-CANDIDATE`), plus offline analysis of `tests/fixtures/resolve/anamnesis-gold-timeline.drp` and a scratch project.
**Why:** Joe reprioritized to the **inbound** path — pull the real color from the live gold timeline into JVE, starting by re-importing the gold DRP.

These findings **contradict locked spec assumptions** (esp. FR-011b). Per research §0.2 they are recorded, not worked around.

---

## 1. Grade reading — there is NO `GetCDL`; extraction is via EDL export
- The scripting API is **write-only for grading**: `TimelineItem:SetCDL` exists, **no `GetCDL`**, no per-node CDL getter, no NodeGraph CDL read. Confirmed live + corroborated by docs/community (see web research).
- **CDL numbers are extracted via** `timeline.Export(resolve.EXPORT_EDL, resolve.EXPORT_CDL)` → an EDL with `*ASC_SOP (slope)(offset)(power)` + `*ASC_SAT sat` per event. Verified: **991 graded events** on the gold timeline, real primaries present (e.g. slope `(0.941496 1.021583 0.953876)`), identity grades `(1 1 1)(0 0 0)(1 1 1)` for ungraded clips. `Export` writes a file only — it does **not** mutate the project.
- **Fidelity honesty (FR-015)** comes from `TimelineItem:GetNodeGraph().GetToolsInNode(n)` + `GetNodeLabel(n)`: if a clip's nodes use tools beyond a primary (e.g. "Qualifier", "LocalExposure", power windows), the CDL is a lossy approximation → mark `fidelity = partial/unrepresentable`. The first gold clip has a 10-node graph with Qualifier+LocalExposure → exactly this case.
- **Implication for the helper:** the `read_grades` verb reads CDL by exporting the EDL+CDL and parsing it, and reads fidelity from the node graph. There is no numeric grade getter to call.

## 2. Identity — IDs bridge for a FRESH export, not for a stale one (T047 refined)

**Refined conclusion (controlled 3-clip experiment):** for a DRP **exported from the current live session**, `Sm2Ti DbId == live TimelineItem.GetUniqueId()` — verified **3/3**, all equal. IDs **do** bridge within a consistent snapshot. The original "0/1003" below was an artifact of comparing a **stale, media-managed fixture** (a different project instance) against the live session — not a fundamental namespace gap.

**Practical rule:**
- Fresh export of the live timeline (what the inbound pipeline produces) → `clip DbId == live id` → **id-based connect works directly**.
- Stale / cross-instance / media-managed DRP → ids diverge → fall back to content/position.
- Marker-carried `clip.id` (§3) remains the *durable* channel across re-edits where DbIds may churn.

Original stale-fixture evidence (gold timeline V1, 1003 items, vs the Apr-1 media-managed fixture):
- `id-equal (DRP Sm2Ti DbId == live TimelineItem.GetUniqueId()) = 0/1003`. The live id is **absent** from that fixture entirely.
- Media level also diverges: DRP `Sm2Mp DbId` `829cfc44…`, DRP `UniqueMediaPoolItemId` `120c428c…`, live `GetMediaId()` `91ae8d2e…`, live pool `GetUniqueId()` `bf614cd0…` — all different.
- Root cause (web-confirmed): `GetUniqueId()` is an **undocumented runtime instance handle**, different from the persisted `DbId` *by design* (a timeline item is an instance of a pool item; BMD forum t=162360). **No documented bridge exists.**
- Compounding: the fixture DRP is **stale** vs the live session — only `20/1003` match even positionally (head matches: OldFashioned@89750, LITTLE_SEAGULL@90025; diverges by A040@90200). The fixture path shows `…-mm/…` (media-managed export) — a different project instance.

### FR-011b correction (locked assumption was wrong)
> ~~"JVE adopts the Resolve timeline-item `DbId` as `clip.id`; connect by id."~~

Split into two cases:
- **File ↔ file re-conform** (match a re-imported DRP to a previously-imported DRP): the DRP `DbId` **is** the right persisted key — keep it.
- **Connecting JVE to a *live* Resolve session** (Joe's actual goal): IDs don't bridge → join by **content/position** — `(media identity + record-TC + source-TC + clip name)`, the NLE-standard conform key (what Resolve's own ColorTrace uses). This is the correct design, not a compromise. Fragile only for clips at `00:00:00:00` (slugs/graphics) — which are ungraded, so harmless here.

## 3. Marker-carried identity — the durable id channel (replaces id-adoption)
Joe's proposal, **validated**:
- `TimelineItem:AddMarker(frame, color, name, note, duration, customData)` creates a **per-instance clip marker**. Stamp `clip.id` (ASCII) into the marker **name** (Joe's pick — simplest/safest) and/or `customData`.
- **Round-trips through DRP export→import** — proven by scratch: stamp → `ExportProject` → `ImportProject` → `GetMarkers` returns the identical `{name, note, customData}`. Survives save/export/reimport.
- **Live read/write is trivial** (`GetMarkers` / `GetMarkerByCustomData`) and has **no linkage problem** — you ask each clip for its own markers. This is the bridge's identity mechanism.

### Bootstrap nuance
Existing live grades sit on **unmarked** clips, so the *first* connect is positional (§2). On that first connect JVE can stamp markers (clip.id) so every subsequent sync is id-anchored. Stamping the live project is a **mutation** (adds markers) — requires Joe's consent.

## 4. The inbound grade-pull pipeline (proven, ready to build)
1. From the live gold timeline at one instant: `Export(EXPORT_EDL, EXPORT_CDL)` (grades) + a fresh `Export(EXPORT_DRT)` (structure) — same snapshot. (Read-only to the project.)
2. Import the DRT into JVE → clips at exact record positions.
3. Join CDL→clip by `(clip name + record-TC + source-TC)` — exact within one snapshot.
4. Write `clip_grade`; set fidelity from the node graph.

## 5. DRP clip-marker IMPORT (separate feature — markers shown to the user) — FORMAT FULLY CRACKED
A user's clip markers in any imported DRP must be read and displayed in JVE. Storage, container, protobuf schema, and clip-linkage are **all solved** (controlled 3-clip experiment):

**Location:** `project.xml → LockableBlobMap → Sm2LockableBlobMap → LocableBlobSet → Element → Sm2TiItemLockableBlob`. **NOT** in the clip's `MarkersBA` (always empty) nor the clip's own `FieldsBlob`. `Sm2TiItemLockableBlob` is a general per-item state container (gold: 411; full edit: 11 679); markers are one payload type.

**Marker→clip linkage = `<BlobOwner>`** — each `Sm2TiItemLockableBlob` has a `<BlobOwner>` child = the owning clip's `Sm2Ti DbId`. Verified 3/3, and (per §2) that DbId == the live `GetUniqueId()` for a fresh export. So markers attach to clips by `BlobOwner`.

**FieldsBlob container format:**
```
[BE32 version][BE32 size]  Fusion "Fields" container
  key "BlobData" (UTF-16BE)  →  value = [0x81 marker][zstd frame]
    zstd frame decompresses to the marker protobuf
```
(Same `0x81`+zstd wrapper as media FieldsBlobs — reuse `qt_zstd_decompress`.)

**FieldsBlob outer wrapper** (verified): a Fusion "Fields" TLV container —
```
[BE32 version=1][BE32 field_count=1]
  TLV field name="BlobData" (UTF-16BE), type 0x000c, payload = the marker blob
    payload = [BE32 ver=10001][BE32 size][0x81][zstd frame]   ← same shape decode_fields_blob handles
```
Decode path reuses existing code: `decode_tlv_fields(bytes, 8, count)` → `raw_payloads["BlobData"]` → `decode_fields_blob_bytes()` (strip 9-byte `[ver][size][0x81]` wrapper + zstd) → marker protobuf.

**Marker protobuf schema** (verified against ALL fields with distinct values + 111 real gold markers, 0 parse failures):
```
f2 LEN  = marker collection
  repeated f1 LEN = one per marker:
    f1 varint = FRAME (relative to clip start)
    f2 LEN    = record = [BE32 ver=2][BE32 size] + f1 LEN color-message:
        f1 varint = COLOR VALUE
        f3 str    = note            (strs[1] — empty note IS present as "")
        f3 str    = duration string  (strs[2] — decimal, parse to int; "duration markers" span)
        f3 str    = name            (strs[3] — Resolve rejects empty-name markers)
        f6 str    = customData      (OMITTED when empty → treat absent as "")
```

**Color enum** (exhaustive 16-color export — explicit table, NOT a clean formula; note the **gap at 256 / 2^8**):
`Blue=2 Cyan=4 Green=8 Yellow=16 Red=32 Pink=64 Purple=128 Fuchsia=512 Rose=1024 Lavender=2048 Sky=4096 Mint=8192 Lemon=16384 Sand=32768 Cocoa=65536 Cream=131072`

**Discriminator** (no type tag in the XML): an `Sm2TiItemLockableBlob` is a marker blob ⟺ its `BlobData` payload is `[ver][size][0x81][zstd]` decompressing to a structurally-valid marker collection (top tag `f2 LEN`). In the gold timeline 30/411 blobs are markers; the other 381 lack the `0x81`+zstd `BlobData` → cleanly rejected (decoder returns nil).

**Status: CLIP markers SHIPPED (decode → import → persist).** Decoder `drp_binary.decode_clip_markers(fields_blob_hex)` → array of `{frame,color,name,note,duration,custom_data}` | nil. `clip_markers` table + `ClipMarker` model. `drp_importer.parse_resolve_markers` scans raw project.xml, attaches by `BlobOwner == clip.clip_id` (Sm2Ti DbId); `importer_core` persists after `Clip.create`. Verified on synthetic (16 colors + edges) AND production (111 real gold markers, 0 parse failures); integration test `tests/test_drp_marker_import.lua` green (18 persisted). Fixtures: `tests/fixtures/resolve/markers_16color_edge.drp` + `.truth.json`.

**DEFERRED:** (a) UI rendering of markers on the timeline clip; (b) **SEQUENCE/timeline-level markers** (Resolve `Timeline:GetMarkers()`, distinct from clip markers) — separate RE: those live elsewhere in the DRP (not Sm2Ti clip items) and need their own `sequence_markers` table/model/importer/test.

## 6. Connection facts (reusable)
- Helper language = **Python** (Phase 0). Read-only ping confirmed Studio 20.3.2.9.
- `Export` writes files only (never mutates the project). `CreateProject`/`LoadProject` switch the *current* project (visible UI flip) — restore the user's project after. `DeleteProject` **fails unless the project is closed first** (`CloseProject`), even if non-current.
- Marker-color enum and EDL `M2` retime lines (`037.5`, `-025.0` = retime fps) observed in exports.

---
**Net:** the inbound grade pull is fully proven and ready to implement via positional join + EDL/CDL export. Marker-carried `clip.id` is the durable bidirectional identity channel (live API). Offline DRP marker *import* is a separate feature gated on the marker→clip linkage RE.

## 7. Dual-system audio mediaseq construction (landed 2026-06-13)

**Finding:** DRP pool items with `AudioSource=AUDIO_SOURCE_CUSTOM` have a `FieldsBlob` carrying ordered BtAudioInfo DbId UUIDs — external WAV refs first (× N channels), then camera's own BtAudioInfo (× M channels). When the DRP importer created the mediaseq for such a clip it ignored all sync data: only the camera scratch tracks were placed, and they were not muted.

**Fix shipped:**
- `drp_importer.resolve_synced_audio_linkage` — builds a `btai_dbid → owning_pmc` reverse index after all pool items are parsed; for each `AUDIO_SOURCE_CUSTOM` video pmc walks `audio_refs`, separates own vs. external UUIDs, ensures each external audio file is in `media_items`, stamps `video_entry.synced_audio_pool_ids = [...]`.
- `importer_core.build_synced_audio_map` — after the media import loop, resolves `synced_audio_pool_ids` (pool UUIDs) → DB media record IDs; passed to `Sequence.ensure_master` as `opts.synced_audio_media_ids`.
- `master_builder.add_synced_audio_streams` — creates one AUDIO track per channel of each external audio file, TC-aligned (`sequence_start_frame = floor(audio_tc * fps_num / (fps_den * sample_rate) + 0.5)`), `muted=false`; camera tracks are built with `muted=true` when `synced_audio_media_ids` is present.

**Test:** `tests/synthetic/lua/test_synced_audio_master_tracks.lua` (6 assertions, green). Verified TDD-first (test failed before implementation).
