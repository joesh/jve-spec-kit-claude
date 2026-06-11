# drt_canonical/ — Resolve-authored reference templates

These XML files are **verbatim, byte-identical copies** extracted from two
Resolve-authored DRP archives:

- `empty_reference_*.xml` (4 files) — from
  `tests/fixtures/resolve/resolve_authored_empty.drp`, a single-timeline
  empty project exported via
  `ProjectManager.ExportProject(name, path, False)` (see
  `tools/resolve-helper/spikes/t008_export_reference_drp.py`).
- `full_reference_mp_video_clip_a005.xml` — single-element extract from a
  real Resolve 20.3 DRT export of a PRISTINE A005 pool item
  (`/tmp/jve-ref-trimmed.drt`, t050b probe 2026-06-10: pool clip imported
  from the fixture media, trimmed timeline created via
  `CreateTimelineFromClips`, exported with `timeline.Export EXPORT_DRT`).
  Borrowed verbatim because its `FieldsBlob` payload is zstd-compressed,
  Resolve-version-stamped, and only partially decoded (phase0-findings.md
  §K). An earlier capture from `resolve_authored_full.drp` (kitchen-sink
  fixture) carried a custom-audio channel map (`AUDIO_SOURCE_CUSTOM`,
  marks, PTZR preset, nonzero playhead) whose FieldsBlob `MediaRef`
  pointed at a media item absent from JVE-authored single-media DRTs —
  Resolve materialized the dangling pool item as a broken placeholder
  (name `' import'`, empty File Path), breaking spec-023 position/content
  matching (T050).

The DRT writer in `../drt_writer.lua` uses them as canonical envelope templates:
it loads each file, applies targeted substitutions for the per-export variable
parts (project name, timeline DbIds, sequence DbIds, FrameRate, Resolution,
clip/track content), and stages the result into a new `.drt` archive.

| File | What's varied per export | What stays verbatim |
|---|---|---|
| `empty_reference_project.xml` | `<ProjectName>`, `<TimelineHandleVec>/<Element>` (timeline DbId) | SM_Project DbId, the 1013-byte root `<FieldsBlob>`, `<CommonConfig>/<SM_Config>` with its large settings blob, MediaPool/GroupList/LockableBlobMap/PowerNode/Gallery DbIds — all Resolve-internal infrastructure references that must stay consistent across the archive. |
| `empty_reference_mp_folder.xml` | the whole `<MediaVec>` (media-pool items + Sm2MpTimelineClip rebuilt), `<Sm2Timeline>/<Name>` etc. | Sm2MpFolder DbId, RootFolderRef-style back-refs |
| `empty_reference_seq_container.xml` | filename (matches container DbId), `<VideoTrackVec>` + `<AudioTrackVec>` rebuilt | Outer Sm2SequenceContainer wrapper + empty subtitle/geometry vecs |
| `empty_reference_gallery.xml` | (none — copied byte-for-byte) | Everything. The SM_Project root FieldsBlob carries a `GalleryRef` UUID; this Gallery.xml's `Gallery::GyGallery DbId` must match. |
| `full_reference_mp_video_clip_a005.xml` | outer `Sm2MpVideoClip@DbId` (→ media.file_uuid), embedded `<MpFolder>` back-ref (→ minted mp_folder DbId), `<UniqueMediaPoolItemId>`, `<Name>` if payload media's basename differs from `A005_C052_0925BL_001.mp4`, `<Time>` blob (re-encoded from payload via `encode_bt_video_time`), both `<Clip>` blobs (re-encoded from payload via `encode_bt_clip_blob` — these carry the directory/filename Resolve binds media by) | Everything else — outer FieldsBlob (zstd; single embedded-AAC channel map whose `MediaRef` equals the template's own BtAudioInfo DbId — internally consistent pair, neither is minted), BtVideoInfo (Geometry/Radiometry/Proxy/VideoMetadata blobs), embedded BtAudioInfo TracksBA, internal DbIds for BtVideoInfo/BtAudioInfo. Source: real Resolve 20.3 DRT export of the pristine A005 pool item (t050b probe, 2026-06-10). |

A previous `full_reference_ti_video_clip_a005.xml` was extracted from
`resolve_authored_single_clip.drp` as a verbatim per-clip template; once the
dissection identified each field's encoding the writer switched to
synthesizing the element from payload (phase0-findings §K3c). The shape it
encoded is now pinned in `tests/test_drt_writer_ti_video_clip_shape.lua` via
literal-hex expectations, so the file has been removed.

**Why ship them as data files instead of regenerating from scratch:** the embedded
binary `FieldsBlob` payloads (zstd-compressed, custom Resolve-internal TLV
serialization) carry version metadata + color-setup state that Resolve validates
at import time. Reverse-engineering enough of that encoding to produce
byte-equivalent blobs from JVE state is multi-day reverse-engineering work that
we are explicitly deferring per the **Strategy 1 / first-pass / borrowed
FieldsBlob** plan in `~/.claude/projects/-Users-joe-Local-jve-spec-kit-claude/memory/todo_drt_writer_resolve_canonical_shape.md`.

**Refreshing the templates:** if Resolve's persistence schema changes (new
version, new required field), re-export an empty project via the spike script,
unzip, and replace these files. The DRT writer's substitution markers are
file-position-independent — they target the variable text by tag content, not
by line/byte offset — so as long as the schema is intact the writer should
keep working.

**License / attribution:** these XML files were produced by DaVinci Resolve
Studio 20.3.2.9 and shipped here as test/reference data only. They contain no
proprietary code; they describe the on-wire format for an empty Resolve project.
