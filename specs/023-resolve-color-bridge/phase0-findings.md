# Phase 0 findings — Connection spike (T002)

**Run:** 2026-05-29, on Joe's Mac (darwin arm64), against the live Resolve already running.
**Status:** Gate 0 — language decision resolved with hard evidence. No production/helper code written (spike deliverable only, per tasks.md T002 + research §10).

---

## Environment (actual, not assumed)

| Fact | Value |
|------|-------|
| Resolve app | `/Applications/DaVinci Resolve/DaVinci Resolve.app` (PID 90875 at spike time) |
| Product | **DaVinci Resolve Studio** — satisfies FR-010 (Studio required) |
| Version | `20.3.2.9` |
| Scripting API dir | `/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting` |
| `fusionscript.so` | `…/Contents/Libraries/Fusion/fusionscript.so` — Mach-O **universal** (x86_64 + arm64) |
| External scripting pref | enabled (connection succeeded ⇒ at least "Local") |
| Live project at spike time | `2026-03-20-anamnesis joe edit`, 127 timelines, current `2026-03-28-anamnesis-GOLD-MASTER-CANDIDATE` |

The spike was **strictly read-only**: `GetProductName`, `GetVersionString`, `GetCurrentProject():GetName()`, `GetTimelineCount()`. No project/timeline mutation, no `CreateProject`.

---

## (a) Helper language: **Python** — external Lua is impossible on this Studio

### Python — connects cleanly (first try)
Documented path: env (`RESOLVE_SCRIPT_API`, `RESOLVE_SCRIPT_LIB`, `PYTHONPATH=…/Modules`) →
`import DaVinciResolveScript as dvr; resolve = dvr.scriptapp("Resolve")`.

Real output:
```
CONNECTED
product: DaVinci Resolve Studio
version: 20.3.2.9
current_project: 2026-03-20-anamnesis joe edit
current_timeline: 2026-03-28-anamnesis-GOLD-MASTER-CANDIDATE
timeline_count: 127
```
- Python: `3.14.3` (homebrew, arm64). `fusionscript.so` loads under 3.14 despite README only promising ≥3.6.
- `DaVinciResolveScript.py` is a 40-line shim that `load_dynamic("fusionscript", RESOLVE_SCRIPT_LIB)` — i.e. the real module is `fusionscript.so`; the Python wrapper just locates+loads it.

### External LuaJIT — **hard segfault** in LuaJIT's own runtime
The Lua module entry point in `fusionscript.so` is `luaopen_dfscript` (confirmed via `nm`: `_luaopen_dfscript`). Loading it from a standalone LuaJIT:
```lua
local loader = package.loadlib(RESOLVE_SCRIPT_LIB, "luaopen_dfscript")  -- returns a function (OK)
loader()                                                                -- SIGSEGV
```
- `pcall(loader)` does **not** catch it — it is a C-level `EXC_BAD_ACCESS`, not a Lua error.
- lldb backtrace, frame #0:
  ```
  stop reason = EXC_BAD_ACCESS (code=1, address=0x5ab9289a547e93ef)
  frame #0: libluajit-5.1.2.dylib`___lldb_unnamed_symbol505 + 200
            ldrb w8, [x1, #0x8]   ; dereferencing the garbage pointer above
  ```
  The fault is **inside LuaJIT's own GC/value handling**, on a garbage tagged pointer, during module init.

**Root cause (evidence-backed, not guessed):** `fusionscript.so` is built against **PUC-Rio Lua 5.1** and assumes its value/stack representation. LuaJIT is Lua-5.1 *source*-compatible but uses NaN-tagged values internally; when `luaopen_dfscript` manipulates the state assuming PUC layout, LuaJIT walks a corrupt `TValue`. The README lists the prerequisite as literal **"Lua 5.1"** (PUC), not LuaJIT.

- LuaJIT on system: `LuaJIT 2.1.1767980792` (arm64) — this is JVE's interpreter.
- Genuine PUC Lua 5.1: **not installed** anywhere (`mdfind`/homebrew `lua@5.1` absent; only homebrew `lua` = 5.4, also ABI-incompatible).

### Decision
**Helper = Python.** This is the spec's pre-declared fallback (research §1: *"Fall back to Python only if Lua cannot make an external connection"*; §1.10 / §10 Phase 2: *"Lua if Phase 0 allows, else Python"*). The spike resolves that conditional — it does **not** contradict the spec.

Consequences, all already anticipated by the design (JVE only ever sees the socket, §4):
- The helper is a Python process under `tools/resolve-helper/`. JVE spawns it via the thin `qt_process_*` FFI; talks to it over `qt_local_socket_*`. Unchanged.
- A Lua helper would have required shipping a separate PUC Lua 5.1 runtime (JVE has none) **and** still wouldn't reuse JVE's LuaJIT — strictly worse than Python, which is present and works.
- The "reusable by a future in-Resolve free-tier Lua script" upside (§1 rationale for preferring Lua) is moot: the in-Resolve path runs inside Resolve's *own* Lua console (PUC), a different runtime from any external helper anyway.

---

## (b) Handle durability across a project/timeline switch — **per-verb revalidation; full UI-switch test deferred to Joe**

What I could verify non-disruptively (without touching Joe's live project):
- `dvr.scriptapp("Resolve")` is **cheap and idempotent** — re-acquiring within a session returns a valid handle pointing at the same current project. This is the mechanism FR-009's per-verb revalidation would use.

What I deliberately did **not** do: switch the active project/timeline in Joe's running Resolve UI to observe whether a *cached* `Project`/`Timeline` object handle goes stale. That mutates Joe's live working session (the anamnesis edit), so it needs Joe to drive the UI switch — folded into the §9 live tests / quickstart "stale handle" edge check (T042).

**Design impact: none / already correct.** FR-009 already mandates that *every verb cheaply revalidates the handle (reacquire via `scriptapp` + `GetCurrentProject`) or returns `handle_stale`*. We adopt that conservatively regardless of the durability answer; the deferred UI-switch test only tells us whether revalidation is strictly *necessary* or merely *defensive* — it cannot invalidate the safe path. No helper code is blocked by it.

---

## Net for Gate 0
- **Proven:** external connection works; this is Studio 20.3.2.9; **Python is the helper language** (external LuaJIT segfaults in its own runtime loading `luaopen_dfscript`; no PUC Lua 5.1 present).
- **Disproven:** the optimistic "Lua-external if possible" branch — not possible with JVE's LuaJIT. (Spec's planned Python fallback now active.)
- **Newly known:** module entry points (`fusionscript.so`: `scriptapp` for Python, `luaopen_dfscript` for Lua); `scriptapp` re-acquire is cheap (good for FR-009); Studio version pin for the helper's `resolve_version` field.
- **Open (needs Joe + live Resolve):** does a cached object handle survive a UI project/timeline switch (b)? — folded into T042's stale-handle live check; not blocking, design already revalidates per verb.

**STOP GATE 0.** Awaiting review before Phase 1 (DRT authoring + identity spike).

---

## T008 spike — Resolve refuses our "minimal-viable" DRT (2026-05-31)

**Run:** Joe drove Resolve Studio 20.3.2.9 to import `/tmp/jve/t008_identity.drt` (authored by `tools/resolve-helper/spikes/t008_author_drt.lua` against the T007 writer). Result: Resolve dialog **"Unable to Import Project — Failed to import project."** Identity carrier readback (T008's actual goal) is **not reachable** until import succeeds.

**Cause (evidence-backed via Resolve-authored reference DRP):** Our writer emits a structurally-tolerable archive for JVE's own DRP importer (T004 self-consistency green) but **not** the shape Resolve insists on. A canonical Resolve-exported DRP — produced via `tools/resolve-helper/spikes/t008_export_reference_drp.py` driving `ProjectManager.ExportProject(name, path, False)` — has the same archive layout (project.xml + MediaPool/Master/MpFolder.xml + SeqContainer/&lt;dbid&gt;.xml) but a much richer schema. Diff (incomplete; see `tests/fixtures/resolve/t008_reference_empty_timeline.drp` for the source-of-truth):

| Element | Our writer | Resolve canonical |
|---|---|---|
| root tag (project.xml) | `<Project>` | `<SM_Project DbId="…">` |
| version header | (none) | `<!--DbAppVer="20.3.2.0009" DbPrjVer="15"-->` |
| project metadata | ProjectName + TimelineFrameRate/Width/Height | LockId/, User, Folder/, UserId, SysId, ProjectId, UpToDate, OrigProjUpToDate, RevivalTaskSetID, PlayHeadsSplitDisplay, LastModTimeInSecs, UpgradeLockSysId/, ProjectAgeInMs, ProjectName, FolderMap/, TimelineVec/, TimelineHandleVec (with `<Element>` per timeline DbId), CurrentTimelineIndex, StreamCursorVector + 4 sibling stream vectors, NumTotalStreams, NumPlayStreams, CurrentStreamId, PlayingStreamId, PlayHeadMode, CommonConfig > SM_Config (with binary settings FieldsBlob), DeletedSsnList, IsADeliverableProject + 2 deliverables siblings, NumReader, ClipInfoSeed, ReelSeed, EDLSeed, RenderText* (3), activeStereoLeft/RightSession/, IsAutoSave, ProjRef/, Thumbnails/, MediaPool > Sm2MediaPool (FieldsBlob carries RootFolderRef UUID), ProjectVersion, GroupList(+Obj), IsLiveCollaborationEnabled, LockableBlobMap > Sm2MediaPoolLockableBlob, PowerNodeList > LmPowerNodeList, Notes/, FaceTaggingClipVec/, FaceTaggingPeopleVec/ |
| project.xml line count | ~5 | 124 |
| MpFolder root | `<Sm2MpFolder DbId="…">` with Name + Sm2MpTimelineClip children | same root, but Sm2MpTimelineClip requires UniqueMediaPoolItemId, MarkIn/Out+Video/Audio (6 empty marks), CurPlayheadPosition, PinsBA/, VirtualAudioTracksBA/, MatteVec/, AudioSource, PTZRPreset > SmPTZRPreset (with ID=100), PTZRPresetType, SlateTC, TimelineSharedHandle > Sm2Timeline { FieldsBlob/, Name, MpTimelineClip (back-ref!), Sequence > Sm2Sequence { LARGE FieldsBlob, UniqueSequenceId, MediaExtents, FrameRate, Resolution, VideoTrackVec/, AudioTrackVec/, Parent (back-ref), pLmVerTable > LmVersionTable { Locals > LmVersion { Body binary }, … }, LastChangedTime, RenderCacheBA, AuxRenderCacheBA, UIElementsState/, NumOutputAudioChannels, OutputAudioGain, PinsBA/, ImportExportMetadataBA/, LockSysId/, DbSavedTime } }, OfflineFrameOffset, PTZRPreset (again), VideoStereoSource, Type, ImportExportMetadataBA/, EnableLTC, LTCSyncDelay, EnableAudio, AudioSyncDelay, ModTimeInSecs, CreateTimeInSecs }, VideoMetadata (binary blob), MediaMetadata/. Plus MediaPool back-ref UUID, Folded, ColorTag, LockSysId/, DbSavedTime |
| MpFolder.xml line count | ~10 | 121 |
| SeqContainer track structure | `<Sm2SequenceContainer><Sm2TiTrack>…clips…</Sm2TiTrack>…</Sm2SequenceContainer>` | `<Sm2SequenceContainer DbId="…">` (filename == container DbId) with `<VideoTrackVec><Element><Sm2TiTrack DbId="…">{FieldsBlob, Type, SubType, Flags, Sequence (back-ref), Items, FusionCompHolderItems/, UserDefinedName/, LayersVec/}</Sm2TiTrack></Element>…</VideoTrackVec>` plus parallel `<AudioTrackVec>`, `<SubtitleTrackVec/>`, `<GeometryTrackVec/>`, `<DbSavedTime>` |
| SeqContainer filename | `seq_001.xml` (N-indexed) | `<container_dbid>.xml` |

In short: **JVE's own DRP importer is tolerant; Resolve's DRP importer demands the full Resolve persistence schema.** The writer's `-- DRT vs DRP: Resolve treats both identically per spec 023` comment is now demonstrably wrong and must be removed.

**Identity-carrier verdict for T008: blocked.** The DBID/NAME/LIS round-trip question can't be tested until Resolve accepts the archive. The writer needs the canonical shape before any carrier readback measurement is meaningful.

**Reference fixture preserved:** `tests/fixtures/resolve/t008_reference_empty_timeline.drp` (Resolve-authored, 17.7 KB, empty timeline). Its unzipped contents are the source of truth for any rewrite.

**Next decision** (Joe): expand `drt_writer.lua` to emit the canonical Resolve shape (significant rewrite — empty FieldsBlobs may suffice for some elements, the Sm2Sequence's big binary blob may need to be either stubbed or copied verbatim from the reference), OR try a different Resolve import entry point (Timeline > Import Timeline from File rather than Project > Import Project — different parser inside Resolve).

---

## T008 kitchen-sink dissection — Resolve-canonical clip/grade/marker/synced-audio encoding (2026-05-31)

**Decision:** Joe chose full canonical rewrite (option 1). Authored a known-content DRP via Resolve UI to map JVE attributes → Resolve XML encoding.

**Fixture:** `tests/fixtures/resolve/t008_kitchen_sink_grade.drp` (89 KB). Built by Joe in Resolve UI: 23.976/1920×1080 project `JVE_KS_v1`, timeline `JVE_KS_SEQ`. 3 imported source files (`A005_C052_0925BL_001.mp4`, `countdown_chirp_30s.mp4`, `test_click_48k_stereo.wav`) + `test_tone_48k_stereo.wav` synced into A005's MediaPoolItem as an extra audio track. Two graded clip-markers (`JVE_MARKER_A/B` + `JVE_NOTE_A/B` + `JVE_KEYWORD_A/B`), one sequence marker (`JVE_SEQUENCE_MARKER_A` + `_NOTE_A` + `_KEYWORD_A`). Distinct grade values on countdown_chirp clip B (Lift/Gamma/Gain/Offset/Sat/Hue/LumMix/Temp/Tint/Contrast/Pivot/MidDetail/ColorBoost/Shadows/Highlights).

### A. Sequence frame-rate and resolution

- `<FrameRate>` on `Sm2Sequence`: two LE IEEE-754 doubles. First = rate (Hz, `23.976023976023978`). Second = 0.0 (unused).
- `<Resolution>` on `Sm2Sequence`: two **big-endian int64**. `0000000000000780 0000000000000438` = width 1920, height 1080. (NOT doubles — this trapped us in the empty-reference reading; bytes 0–7 BE are width, bytes 8–15 BE are height.)
- `<MediaFrameRate>` on each clip: same two-LE-double layout as Sequence FrameRate.

### B. Timeline clip layout (Sm2TiVideoClip / Sm2TiAudioClip)

Children on each clip element, in order:
```
FieldsBlob (zstd-prefixed, sub-32-256B per clip — small, mostly opaque)
PrettyType (empty)
Name (source filename)
Start                ← integer frames at sequence's NON-DROP rate (24 for 23.976)
Duration             ← integer frames at sequence's non-drop rate
LinkedItemSync       ← EMPTY on every clip in this fixture — see §D
WasDisbanded         ← false
MarkersBA            ← EMPTY on every clip — clip markers live elsewhere, see §E
UiMemento Flags PriorityIndex EffectFiltersBA/ ImportExportMetadataBA/
RenderText{Enabled,Ganged,Prefixed}   ← true for video, false for audio
In                   ← see §C
MixedFrameRateAlignment 0
MediaRef             ← UUID → Sm2MpVideoClip/Sm2MpAudioClip in MpFolder.xml
MediaStartTime       ← decimal-string seconds (clip-start offset into the source's TC origin; "0" for tc=0 media)
MediaFilePath        ← absolute path (problematic for portability)
MediaReelNumber/ MediaFrameRate
MediaTimemapBA       ← retime curve data (BE-double seconds-tagged blob)
[pLmVerTable]        ← OPTIONAL; present iff clip has a grade (HasCorrection=true). See §G
LastChangedTime LastRenderedTime IsMarkedForCaching IsForceConformed MatchConflictState
UseOppositeSrcFor{Left,Right}Eye RenderCacheBA/ CurrentSelectorIdx IsPreConformed PreConformMediaExtents MediaMetadata/
Thumbnail (video only)  ThumbnailDirtyFlag (video only)
VirtualAudioTrackBA (audio only)   ← see §F
MediaTrackIdx (audio only)         ← see §F — KEY for synced-audio
```

**Start/Duration are at the sequence's integer rate** (24 for 23.976, 25 for PAL, 30 for 29.97). Verified by clip-A's `Start=86400 Duration=108` → 86400/24 = 3600 sec (01:00:00:00 at the standard 01:00:00 timeline origin); Duration 108/24 = 4.5 sec matches A005's source duration.

### C. `<In>` source-range encoding

Two forms:
- **Untrimmed:** `<In/>` (empty self-closing element).
- **Trimmed:** `<In>71|80f26ce6c3b2ed3f</In>` — format is `<integer_frames>|<hex_LE_IEEE-754_double>`. The integer is the whole-frame source In at the sequence's non-drop rate; the double is the sub-frame fractional part. Verified: `71 + double(0x3fedb2c3e66cf280 BE)` = `71 + 0.928071…` = `71.928 frames` = `3.000003 sec` at 23.976 = exactly the In point Joe set (`00:00:03:00`). The 23.976/24 quantization error is encoded faithfully.

This means JVE's `source_in_frame` integer is **lossy** vs. Resolve's source range. The writer either rounds (acceptable for whole-frame editing) or computes the fractional double and emits both.

### D. `<LinkedItemSync>` is EMPTY for the V/A sync group

Even though Joe's clip-A V+A+synced-audio appears with the chain-link 🔗 icon in the timeline (and all three blocks were selected together as a sync group), every `<LinkedItemSync/>` element in this fixture is empty. The V↔A pair grouping seen in the UI is **not persisted via `LinkedItemSync`** in this fixture; it is either:
- Inferred at load time from `MediaRef` overlap + same `Start`, OR
- Persisted in a higher-level structure (Sm2Sequence FieldsBlob? Sm2TiTrack FieldsBlob? — likely in the Sm2TiItemLockableBlob (§E) or in the per-clip `FieldsBlob`, both zstd-compressed).

This contradicts the prior `project_drp_linked_item_sync` memory if extrapolated to synthetic fixtures — that memory was based on Anamnesis (real-take continuous captures, where Resolve writes the parent-take ID). For UI-built synthetic clips with no parent take, `LinkedItemSync` is empty. **Both encodings exist; the writer must handle both.**

### E. Markers — they do NOT live on `Sm2TiVideoClip.MarkersBA`

Every clip's `<MarkersBA/>` is empty. The marker data lives in:

**Clip markers** → `project.xml` → `<LockableBlobMap>` → `<Sm2LockableBlobMap>` → `<LocableBlobSet>` → `<Element>` → `<Sm2TiItemLockableBlob DbId="…">` → `<FieldsBlob>…</FieldsBlob>`. One Sm2TiItemLockableBlob per (clip-with-markers, that-clip's-markers). 110-byte blob for the single-marker clip A; ASCII strings (NAME, NOTE, KEYWORD) packed at offsets ~68-100. Not zstd-compressed (plaintext ASCII visible). Header layout TBD via further binary dissection.

**Sequence markers** → `project.xml` → root `<SM_Project>` → `<FieldsBlob>` (the big 1013-byte root blob). UTF-16 LE strings prefixed by `<2-byte LE byte-count>00 00`. Sentinels `JVE_SEQUENCE_MARKER_A` (byte 855), `JVE_SEQUENCE_KEYWORD_A` (byte 796). **`JVE_SEQUENCE_NOTE_A` not found in either UTF-16 LE or ASCII** — may be discarded by Resolve on export, or stored in yet another blob; TBD.

**Implication for JVE:** clip markers are attached at the *project* level by (clip-DbId, marker), not on the timeline placement. A clip referenced multiple times on the timeline shares one marker set.

### F. Synced audio — `MediaTrackIdx` is the discriminator (THE finding)

Three audio clips on the timeline reference the SAME `MediaRef = 1665f18c-…` (A005's `Sm2MpVideoClip` DbId), but distinguish themselves by `<MediaTrackIdx>`:
- A1 clip (embedded audio): `<MediaTrackIdx>0</MediaTrackIdx>` + `VirtualAudioTrackBA` with offset `0x010000` (=Embedded Channel 1)
- A2 clip (synced WAV): `<MediaTrackIdx>2</MediaTrackIdx>` + `VirtualAudioTrackBA` with offset `0x012000` (=Linked Channel 1)
- A3 clip (standalone `test_click_48k_stereo.wav`): `<MediaTrackIdx>1</MediaTrackIdx>` + `VirtualAudioTrackBA` with offset `0x010000` (=embedded ch 1 of its OWN MediaRef `50b4735c-…`, a Sm2MpAudioClip)

The synced `test_tone_48k_stereo.wav` IS a separate `Sm2MpAudioClip` in MpFolder (DbId `2bf1db7d-…`), but it is **not** the MediaRef of the synced timeline clip. The linkage "A005 has test_tone synced as track 2" must live in A005's `Sm2MpVideoClip` FieldsBlob (zstd-compressed; TBD). At the timeline level the synced clip simply asserts `MediaRef = A005` + `MediaTrackIdx = 2`.

**This is almost certainly the root cause of JVE's broken synced-audio.** JVE likely treats the synced WAV as a sibling clip with its own MediaRef; Resolve treats it as a virtual track of the master MediaPoolItem. The bidirectional bridge needs to model this.

### G. Grade encoding — `pLmVerTable` + zstd-compressed `Body`

Only clip B (`countdown_chirp_30s.mp4` on V1) has a grade. The clip element's child list includes:
```
<pLmVerTable>
 <ListMgt::LmVersionTable DbId="…">
  <FieldsBlob>…</FieldsBlob>   ← contains LastChangedTime, ActiveVersionType
  <VerType>0</VerType>
  <pActive>cb6b0190-…</pActive>     ← UUID of active LmVersion
  <Locals>
   <Element>
    <ListMgt::LmVersion DbId="cb6b0190-…">
     <FieldsBlob/>
     <Name>Version 1</Name>
     <HasCorrection>true</HasCorrection>   ← grade-presence flag
     <VerType>0</VerType> <ImplVersion>1</ImplVersion>
     <IncludedInRecording>true</IncludedInRecording>
     <FlatPassEnabled>false</FlatPassEnabled>
     <RGBAOutputEnabled>false</RGBAOutputEnabled>
     <Body>8128b52ffd…</Body>     ← THE grade payload, zstd
     <UseVersionClipProcParams>true</UseVersionClipProcParams>
    </ListMgt::LmVersion>
   </Element>
  </Locals>
  <DbSavedTime>9183907540</DbSavedTime>
 </ListMgt::LmVersionTable>
</pLmVerTable>
```

Ungraded clips (clip A on V1, overlay copy of clip B on V2, all audio clips) **omit `pLmVerTable` entirely.**

**Body decoded:** 414 zstd-compressed bytes → 522 bytes plaintext. The leading `0x81` is a Resolve version byte; bytes 1+ are vanilla zstd (`28b52ffd…` magic). Decompressed stream looks protobuf-shaped (varint length-delimited fields, `0a8104080110011a22…` start). Confirmed grade-value hits as **float32 LE**:

| Joe's input | Float32 LE hex | Body offset | Hit? |
|---|---|---|---|
| Lift G 0.22  | `ae47613e` | 0x74 | ✓ |
| Gamma Y 0.20 | `cdcc4c3e` | 0x9e | ✓ |
| Gamma R 0.44 | `ae47e13e` | 0x82 | ✓ |
| Gamma B 0.66 | `c3f5283f` | 0x90 | ✓ |
| Gain Y 0.30  | `9a99993e` | 0xd6 | ✓ |
| Gain R 0.77  | `b81e453f` | 0xac | ✓ |
| Gain G 0.88  | `ae47613f` | 0xba | ✓ |
| Gain B 0.99  | `a4707d3f` | 0xc8 | ✓ |
| ColorBoost 0.19 | `5c8f423e` | 0x192 | ✓ |
| Shadows 0.29 | `e17a943e` | 0x183 | ✓ |
| Highlights 0.39 | `14aec73e` | 0x174 | ✓ |
| Tint 0.24 | `8fc2753e` | 0x1bf | ✓ |
| Contrast 0.340 | `7b14ae3e` | 0x165 | ✓ |
| Pivot 0.440 | `ae47e13e` | aliased w/ Gamma R | ✓ |
| MidDetail 0.54 | `713d0a3f` | 0x1a1 | ✓ |
| **NOT FOUND** | Lift Y 0.10, Lift R 0.11, Lift B 0.33, Gamma G 0.55 (likely overlap or different scaling), Offset RGB (25.11/22/33), Saturation 75.10, Hue 75.20, LumMix 75.30, Temp 0.10 | — | ✗ |

Most non-Offset/Sat/Hue/LumMix values found at predictable positions. The values that did NOT hit (Offset 25.xx, Sat/Hue/LumMix 75.xx, Lift Y/R/B, Gamma G, Temp) suggest those controls are either (a) stored as different scaling (e.g. Sat as 0.751 not 75.1), (b) stored in a separate envelope (Color Page workspace, not per-node Body), or (c) Resolve quantized them differently. JVE's CDL `clip_grade` table needs slope/offset/power/saturation only — a partial decode is sufficient for FR-016 fidelity, with the rest going through opaquely as `fidelity = 'partial'`.

### H. Identity carriers

**`DbId` on every element** — including each timeline-clip element. These are stable UUIDs assigned by Resolve, exactly as needed for FR-011b's "adopt the Sm2Ti DbId as `clip.id`" rule. Carrier survival across round-trip is now testable once the writer emits canonical shape (T008 unblock condition).

`Name` is the source filename (lossy — multiple clips share the same Name when they reuse a source). NOT a viable identity carrier.

### I. Mapping table — JVE field → Resolve XML location

| JVE concept | Resolve element / path | Encoding |
|---|---|---|
| `sequence.frame_rate_num/den` | `Sm2Sequence/FrameRate` | LE double `rate`, second double = 0 |
| `sequence.resolution_width/height` | `Sm2Sequence/Resolution` | **BE int64** `width`, BE int64 `height` |
| `sequence.name` | `Sm2MpTimelineClip/Name` and `Sm2Timeline/Name` | UTF-8 text |
| `clip.id` (== Resolve Sm2Ti DbId) | `Sm2TiVideoClip@DbId` or `Sm2TiAudioClip@DbId` | UUID |
| `clip.sequence_start_frame` | `Sm2Ti*Clip/Start` | int (sequence integer rate) |
| `clip.duration_frame` | `Sm2Ti*Clip/Duration` | int (sequence integer rate) |
| `clip.source_in` (frame portion) | `Sm2Ti*Clip/In` left of `\|` | int (source integer rate) |
| `clip.source_in` (sub-frame) | `Sm2Ti*Clip/In` right of `\|` | hex LE double |
| `media.id` (Sm2Mp*Clip DbId) | `Sm2Ti*Clip/MediaRef` | UUID |
| `media.start_tc_frame` | `Sm2Ti*Clip/MediaStartTime` | decimal-string SECONDS (not frames!) |
| `media.file_path` | `Sm2Ti*Clip/MediaFilePath` | absolute path |
| `media.frame_rate` | `Sm2Ti*Clip/MediaFrameRate` | LE double rate, second double = 0 |
| audio-channel routing (embedded vs linked) | `Sm2TiAudioClip/MediaTrackIdx` | int (0 = embedded ch 1, 2 = linked ch 1, etc.) + `VirtualAudioTrackBA` parallel |
| clip-marker (name, note, keyword, color) | `project.xml/Sm2TiItemLockableBlob/FieldsBlob` | custom packed binary, ASCII strings |
| sequence-marker | `project.xml/SM_Project/FieldsBlob` | custom packed binary, UTF-16 LE strings |
| `clip_grade.slope_*`/`offset_*`/`power_*`/`saturation`/`lut_ref` | `Sm2TiVideoClip/pLmVerTable/.../LmVersion/Body` | zstd → protobuf-shaped, partial decode (see §G) |
| `clip_grade.fidelity` | (derived) `HasCorrection=true` ⇒ at least 'partial'; full CDL decode ⇒ 'primary' | — |

### J. Items deferred (post-rewrite investigation)

- `Sm2TiItemLockableBlob` header layout (offsets of NAME/NOTE/KEYWORD within the 110-byte blob — currently empirical "at offsets ~68/83/98").
- Synced-audio linkage encoding inside `Sm2MpVideoClip` (A005's MediaPoolItem must reference test_tone_48k_stereo.wav's Sm2MpAudioClip somehow; lives in A005's compressed FieldsBlob).
- Sequence-marker `Note` text storage — UTF-16 LE search missed `JVE_SEQUENCE_NOTE_A`. May be in a different blob, may be UTF-16 BE, may be zstd-compressed.
- MediaTimemapBA full layout (BE-double seconds tagged with leading byte type indicators; only the no-retime form needs to round-trip cleanly).
- Sm2Sequence's large color-setup `FieldsBlob` (the 1013-byte one in the empty reference) — the writer can copy this verbatim from the empty reference initially, with a `-- BORROWED, NOT REGENERATED` marker.

**Source-of-truth fixtures:**
- `tests/fixtures/resolve/t008_reference_empty_timeline.drp` (empty timeline; envelope reference)
- `tests/fixtures/resolve/t008_kitchen_sink_grade.drp` (this fixture; clip/grade/marker/synced-audio reference)
- `tests/fixtures/resolve/retime-test.drt` (pre-existing; only-real-clip reference for `Sm2TiVideoClip` shape with `MediaTimemapBA` populated)

