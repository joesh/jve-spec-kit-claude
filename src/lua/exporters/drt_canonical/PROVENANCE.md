# drt_canonical/ — Resolve-authored reference templates

These XML files are **verbatim, byte-identical copies** of the four files inside
`tests/fixtures/resolve/t008_reference_empty_timeline.drp` — a DRP archive that
DaVinci Resolve Studio 20.3.2.9 produced for an **empty single-timeline project**
via `ProjectManager.ExportProject(name, path, False)` (see
`tools/resolve-helper/spikes/t008_export_reference_drp.py`).

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
