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

## 2. Identity — IDs do NOT bridge DRP ↔ live API (T047 = NO)
Empirical, gold timeline, V1 (1003 items) vs the gold DRP:
- `id-equal (DRP Sm2Ti DbId == live TimelineItem.GetUniqueId()) = 0/1003`. The live id is **absent** from the DRP entirely.
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

## 5. DRP clip-marker IMPORT (separate feature — markers shown to the user)
Distinct from the bridge: a user's clip markers in any imported DRP must be read and displayed in JVE. Storage **fully located**, decode **partially solved**, linkage **OPEN**:
- Markers live in `project.xml → LockableBlobMap → Sm2LockableBlobMap → Element → Sm2TiItemLockableBlob[DbId] → FieldsBlob`. **NOT** in the clip's `MarkersBA` (always empty) nor the clip's `FieldsBlob`.
- The `FieldsBlob` is **raw protobuf** (`[BE32 ver][BE32 size][protobuf]`, `"BlobData"` header — no zstd). Decodes to nested messages; **frame number and note/name/customData strings extract cleanly** (verified against a known scratch marker: `f1 varint 5` = frame 5).
- `Sm2TiItemLockableBlob` is a **general per-item state container** (gold: 411; full edit: 11 679), not one-per-clip; markers are one payload type.
- **OPEN — marker→clip linkage:** the marker blob's `DbId` (`7978b63a…`) does **not** reference the clip `DbId` (`5a30f095…`) — not as string/UTF-16/raw-16-byte. The clip's `FieldsBlob` carries a third UUID (`54259379…`) that also isn't in the marker blob. The link is encoded indirectly (an undecoded protobuf field, or the `LockableBlobMap` container's key structure). **Cracking this is the gate for offline marker→clip attribution.** RE in progress (controlled multi-clip scratch experiment).

## 6. Connection facts (reusable)
- Helper language = **Python** (Phase 0). Read-only ping confirmed Studio 20.3.2.9.
- `Export` writes files only (never mutates the project). `CreateProject`/`LoadProject` switch the *current* project (visible UI flip) — restore the user's project after. `DeleteProject` **fails unless the project is closed first** (`CloseProject`), even if non-current.
- Marker-color enum and EDL `M2` retime lines (`037.5`, `-025.0` = retime fps) observed in exports.

---
**Net:** the inbound grade pull is fully proven and ready to implement via positional join + EDL/CDL export. Marker-carried `clip.id` is the durable bidirectional identity channel (live API). Offline DRP marker *import* is a separate feature gated on the marker→clip linkage RE.
