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

