# Data Model: Resolve Color Roundtrip Bridge (schema V11 → V13)

Two new persisted tables in `src/lua/schema.sql`, plus one new column `sequences.import_uuid` (source-clip identity — see "Source-clip identity" below). No migration — bump `schema_version`; Joe regenerates the `.jvp` (`feedback_schema_bump_freely`). The helper's idempotency ledger is **not** persisted here (process-local). Version goes straight from 11 to 13 because the spec-013 clip-shape changes (clips.media_id removal, media linkage now via `media_refs`) also live in this schema without an interim on-disk bump — V12 never shipped in the post-013 codebase, so this bump syncs `schema_version` to the actual shape (review item #16).

Source: spec.md FR-011..017, FR-013a; clarifications 2026-05-29 (same-machine, read-only, one target, manual sync, cascade+stale). Mirrors research.md §5.1.

---

## Entity: `clip_grade`

A per-clip color grade read back from Resolve. Read-only in JVE.

```sql
CREATE TABLE IF NOT EXISTS clip_grade (
    clip_id     TEXT PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE,
    -- CDL primaries (linear floats). All-NULL when fidelity has no representable CDL.
    slope_r REAL, slope_g REAL, slope_b REAL,
    offset_r REAL, offset_g REAL, offset_b REAL,
    power_r REAL, power_g REAL, power_b REAL,
    saturation REAL,
    lut_ref     TEXT,                       -- local LUT path (same-machine), or NULL
    fidelity    TEXT NOT NULL,              -- 'primary' | 'partial' | 'unrepresentable'
    source      TEXT NOT NULL,              -- provenance, e.g. 'resolve_readback'
    stale       INTEGER NOT NULL,           -- 0/1; writer always sets it (no SQL default — 2.13). 1 = source Resolve item absent at last read-back
    synced_at   INTEGER NOT NULL            -- unix seconds of last successful sync
);
```

**Fields / validation**
- `clip_id` — PK and FK to `clips(id)`; one grade per clip (FR-014 grade-attaches-to-clip, clarification: one target). `ON DELETE CASCADE` ⇒ deleting a clip drops its grade (FR-013a).
- CDL primaries — REAL. Either all nine + `saturation` are present (a representable CDL) or all NULL. Assert this invariant at the model write boundary; never store a partial CDL (constitution VII).
- `lut_ref` — local filesystem path; NULL if the grade has no baked LUT. Cross-machine LUT transport is out of scope (clarification: same-machine).
- `fidelity` — enum, NOT NULL. `'primary'` ⇒ CDL fully represents the grade; `'partial'`/`'unrepresentable'` ⇒ Resolve grade exceeds CDL/LUT (FR-015). The model rejects any other value (assert).
- `stale` — set to 1 when read-back finds the clip's Resolve item gone (FR-013a). Never silently cleared; the grade values are retained. A subsequent successful sync clears it back to 0.
- `source` — provenance string; `'resolve_readback'` for v1 (no JVE-authored grades — read-only).

**Lifecycle**
- **Created/updated**: only by the `SyncGradesFromResolve` command (FR-017) via upsert. Never written outside a `command_event` (`todo_command_bypass_enforcement`).
- **Undo**: the command captures prior rows and restores them.
- **Deleted**: only by FK cascade when the clip is deleted. No standalone delete.

---

## Source-clip identity (media = file, master = source clip — corrected 2026-06-16)

**Superseded model:** earlier drafts pinned the Resolve media-pool item id (`MediaRef DbId`) to `media.id` (`media.id = MediaRef DbId or uuid.generate()`). That conflated two distinct things and broke synced clips: Resolve pools **one physical file under several pool items** (one per sync relationship — e.g. a synced clip and its plain-camera counterpart both wrap one `.mov`). One id pinned to `media.id` forced one media row per pool item; with `media.file_path` UNIQUE, all but one went offline, and relink then collapsed them.

**Corrected model:**
- **`media` = a file.** One row per physical file. `media.id` is a stable file identity (no longer the pool-item id). Bare/offline references (a pool item whose link Resolve severed) resolve to their online same-named sibling at import and dedup onto the one media (`importer_core.resolve_offline_paths_to_siblings`).
- **A `kind='master'` sequence = a source clip** (a media-pool / bin item). Its `sequences.import_uuid` carries the source-clip identity from the imported project — **the Resolve `MediaRef DbId`** for DRP. One master per pool item; several masters may reference the one media (synced + plain over one file). NULL for native masters, whose `id` is the identity on export.
- The synced relationship is a property of the **master** (its `source_kind='sync'` tracks), not the file. A timeline clip binds to a master by the **pool id it references** (`clip_data.file_uuid` → `import_uuid`), so the synced clip lands on the synced master and keeps all its audio.
- **A master's TC origin equals its content origin.** A master sequence's timebase IS absolute timecode space: each media_ref sits at its file's TC origin (`sequence_start_frame = video_tc` for video, `audio_tc` for audio-only) spanning `[tc_origin, tc_origin + duration]`; `[0, tc_origin)` is empty. The master's `start_timecode_frame` (the ruler/view anchor) MUST equal that content origin, or the view anchors at the wrong place and zoom-to-fit blows out to hours of empty space. `create_master_row` sets `start_timecode_frame = has_video ? video_tc : audio_tc` (NOT `video_tc` unconditionally — that left audio-only masters anchored at 0 while their audio sat at its multi-hour sample timecode). The relink TC-sync path (`find_masters_for_media_tc_sync` + `batch_set_master_start_tc`) keeps the two aligned when a probed origin shifts.
- **Synced-audio alignment is offset-based, PER CHANNEL — not timecode-based.** Resolve stores a `SampleOffset` (file sample that plays under the video's first frame) per channel in the synced clip's audio `FieldsBlob`; a free-run field recorder is never jam-synced to the camera, so their timecodes do not coincide. `drp_binary.extract_media_ref_sample_offsets` decodes them (index-aligned with `extract_media_refs`); the importer threads them as `synced_audio_streams = {{media_id, sample_offsets={…per channel}}}` (`importer_core`), and `master_builder.add_synced_audio_streams` places each sync channel **co-located with the video** (`sequence_start_frame = video_tc`, record length = video take) with `source_in_frame = audio_tc + SampleOffset`. Resolve **omits** the field when the offset is zero (jam-synced / no slip) ⇒ absent means 0 (boundary normalization, not a fallback). When the master has **no video stream** (offline/undecoded video — nothing to co-locate against), synced audio anchors at its own TC spanning the whole file and the offset is not applied until the video is present. **OPEN (needs Joe's eyeball in live Resolve):** whether an absent `SampleOffset` truly means 0-offset co-location vs. some other default — see [[todo_023_synced_relink_extent_fix]].
- **One audio clip per source channel — the channel is a media_ref selector, decoded end-to-end.** A multichannel audio file is N streams; each maps to its own master track (synced/Adaptive expand). `media_refs.source_channel` (0-based; NULL for video; required ≥0 for AUDIO refs via `MediaRef.create`) names which file channel a ref reads. The resolver emits one entry per track carrying that channel; `tmb_clip_builder` forwards `source_channel` into the TMB clip; the C++ decode path (`ClipInfo.source_channel` → `Reader::DecodeAudioRangeUS` → `FFmpegResampleContext::init`) honors it via an swr remap matrix that routes that one source channel to BOTH stereo outputs (dual-mono monitoring). `source_channel = -1` is the composite/**Adaptive** default: swr's downmix of all channels (a stereo source stays L→L/R→R). Output is always stereo regardless; the channel only selects the source. A per-clip Reader pool key (`(track, clip_id)`) guarantees one channel per resampler, so the decode cache needs no channel key. Before this, the decoder dropped the channel and downmixed every track identically — soloing any synced track played the same composite. Per-channel **waveforms** match: the peak pipeline is keyed by `(media_id, source_channel)` — `PeakGenerator::RequestPeaks` takes a `source_channel` and decodes through the same swr remap, `peak_cache` uses a job key (`<media_id>` for composite, `<media_id>__ch<N>` for one channel) that doubles as the `.peaks` filename stem, `init_for_project` pre-generates exactly the channels referenced by AUDIO media_refs (`Media.get_audio_channels_for_project`), and the timeline renderer passes the clip's `resolved_media.source_channel` to `get_visible_peaks`. So each track's waveform reflects its own channel, not the composite. See [[todo-023-per-channel-audio-streams]].
- **Composite (Adaptive) clip waveform — on-demand cross-file fold.** A synced/Adaptive clip is placed as ONE timeline audio clip standing for a whole master's audio (N channels, possibly across multiple media files). It is NOT pinned to a single master audio track (`clips.master_audio_track_id` NULL), so it has no single per-channel source window — its `source_in/out` are MASTER-DOMAIN FRAMES, not samples. `load_clips`/`load_clip_entry` attach `clip.composite_audio_refs` (every audio ref of the master: `media_id, source_channel, source_in_frame, sequence_start_frame, audio_sample_rate`) for such clips; an *expanded* per-channel clip pins a master track and keeps the single-channel path. The renderer folds the per-channel `.peaks` on demand via `peak_cache.get_composite_peaks` → `EMP.PEAK_QUERY_COMPOSITE(refs, px)`: each ref's master-frame window maps to its own file-relative samples (`abs = source_in_frame + (vis_frame − sequence_start_frame)·sample_rate·fps_den/fps_num`, then minus the media's TC origin), and the C layer folds per pixel (min-of-mins / max-of-maxes) into a C-owned scratch buffer. The per-channel envelopes remain the single source of truth — there is NO persisted composite peak file. A mono master folds a single ref (identical to the per-channel path). This fixes "no waveform on synced clips": the pre-fix renderer fed the master-frame window to a single arbitrary channel as if it were samples, clamping the query out of range. See [[todo-023-composite-waveform-and-channel-names]].
- **Master audio track names — user override else recorder iXML channel name.** A synced master's **recorder** audio tracks are created **nameless** (`master_builder.add_synced_audio_streams` passes `name=nil`; `tracks.name` is now nullable — NULL = unset) and derive their label by probing the file. The master's **embedded** (camera-file) audio channels are instead labeled `"Embedded N"` (`add_audio_streams` / `duplicate_master_clip`) — a camera file carries no iXML track names, so a stored default is correct there; the user can still rename it. The label resolution below applies to any **channel-backed** audio track (one whose `media_ref` carries a `source_channel`), on the source tab (master clip open) and the record tab alike — the label follows the channel, not the tab. The display layer (`ui/timeline/track_header_label.for_display`, record kind) resolves a label in priority order: (1) `track.name` — the user's rename (override, authoritative); (2) the recorder's channel name probed from the media's BWF/WAV **iXML `<TRACK_LIST>`** (one `<TRACK>` per channel, `<INTERLEAVE_INDEX>` = 1-based interleaved position, `<NAME>` = label; JVE `source_channel` is 0-based so `source_channel N → INTERLEAVE_INDEX N+1`); (3) blank. `core/media/channel_names.get(media_id, path, source_channel)` does the probe — reads only the file's RIFF chunk headers + the iXML chunk body (no audio decode), parses via the `qt_xml_parse_string` binding, and is **session-cached per media_id** (re-derived each launch; a recorder re-label is picked up without persistence). The probe is **lazy**, driven by the timeline view when a master tab's headers build (`timeline_panel` resolves `channel_name` only for nameless tracks via `database.get_track_channel_source`), never by the importer (importers do not probe media). Names are NEVER written into the project — `tracks.name` holds only the user's override; clearing the override reverts to the probed name. The DRP carries **no** channel names (verified by exhaustive FieldsBlob scan), so the file is the only source. Renaming is the undoable `SetTrackName` command (`mutates_clips=false`; empty input → NULL → derived label returns), opened by the `RenameTrack` interactive starter — bound to a double-click on the track name (new `qt_set_widget_double_click_handler` binding) and to F2. The F2 target is resolved by `rename_track.resolve_target` (pure, precedence-ordered): explicit clicked track → the focused track (`timeline_state.get_focused_track_id`, set on track-header click) → the selected clip's track when the whole selection lives on one track (discoverable: select a clip, press F2) → assert (nothing anchors the rename). See [[todo-023-composite-waveform-and-channel-names]].
- **Relink coverage maps through the master media_ref, not by raw frame×rate.** A timeline clip's source range is in master-frame space; `Media.get_source_extent` / `batch_get_source_extents` convert to file units via the master media_ref of the SAME track type (`file_pos = mr.source_in + (frame − mr.sequence_start)·rate_ratio`). The δ term `mr.source_in − scaled(mr.sequence_start)` is exactly 0 for TC-aligned camera audio (so camera extents are unchanged) and exactly the SampleOffset for synced audio — fixing the spurious "file short" the old naive frame×rate scale produced for synced clips.
- **Relink duration-sync leaves synced placements untouched.** When relink re-probes a file and syncs durations, `Media.batch_set_durations` rebases every camera/master media_ref of that media to `[file_tc_origin, +full_file_duration]` (the file's own length is the source of truth for those). A **sync-routed media_ref** (track `source_kind = 'sync'`) is the exception: its placement is *video*-derived (`sequence_start = video_tc`, duration = video take, `source_in = audio_tc + SampleOffset`) and references only a sub-range of the file, so the file's total length has no bearing on where the audio sits under the picture. `batch_set_durations` reads each ref's `source_kind` and skips the rebase for sync refs — otherwise the synced audio is flung to the file's absolute sample timecode (`sequence_start` ~ billions), scattering it off the video and blowing the synced sequence's content extent out to hours.

**Schema:** adds `sequences.import_uuid TEXT` (nullable; masters only). `media.file_uuid` is retired as the identity anchor.

**Outbound (landed 2026-06-16):** the exporter keys the DRT media-pool by the source-clip identity, not the file. `payload_builder` resolves each timeline clip to its master and emits one pool item per master, carrying `file_uuid = master.import_uuid or master.id` (native masters fall back to `master.id`) with the underlying file's path/rate/duration/TC. Two masters over one `.mov` ⇒ two pool items, same path, distinct DbId — the dual of the inbound model, so the synced/plain distinction survives the round-trip. For DRP-imported masters `import_uuid` == the original `MediaRef DbId`, so single-pool-item round-trip bytes are unchanged. The timeline clip's `<MediaRef>` carries the same master identity. `drt_writer` is unchanged (it reads the payload's `file_uuid`/`media_uuid`, whose *values* moved from `media.id` to the master identity). `media.file_uuid` (the column) now has **no behavioral reader** — media dedup is path-based — and is removable; see [[todo_023_outbound_import_uuid_export]]. `identity_ledger.reconcile`'s `content_match` keys on this same identity but is not yet wired into the live sync path (`discovery.match` is marker/position/direct-id).

## Clip identity (inbound adoption — FR-011b)

`clip.id` is **not always a JVE-minted UUID.** Just as a master adopts the Resolve pool-item `MediaRef DbId` as its `import_uuid` (see "Source-clip identity" above), the DRP/DRT importer adopts the Resolve **timeline-item id** (`Sm2TiVideoClip`/`Sm2TiAudioClip` `DbId`) as `clip.id` when present, else mints a UUID. Consequences:

- For an imported clip, `clip.id` **is** the Resolve item id — the identity link is the id itself (no `resolve_bridge_link` row needed to know the mapping; a row is still used to carry fingerprints).
- Video and audio of one synced clip are distinct Resolve items with distinct DbIds → distinct JVE clips, no PK collision.
- Clips JVE creates after import (blades, paste) get fresh UUIDs and match positionally.
- Re-importing the same DRP yields the same `clip.id`s (stable across re-imports — fixes the prior "fresh ids each import" gap).
- No schema change: `clips.id` is already `TEXT PRIMARY KEY` and already holds non-UUID ids for media; a grep confirmed no code assumes `clip.id` is UUID-shaped.

## Entity: `resolve_bridge_link` (identity + sync ledger)

Persisted per-clip bridge state: the Resolve item correspondence plus the fingerprints used for change/conflict detection (FR-011). Bidirectional — see "Clip identity" above: for imported clips `resolve_item_id` equals `clip.id`; for JVE-originated (UUID) clips it is the matched Resolve id. One Resolve target per project ⇒ keyed on clip id alone.

```sql
CREATE TABLE IF NOT EXISTS resolve_bridge_link (
    jve_clip_uuid     TEXT PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE,
    resolve_item_id   TEXT NOT NULL,        -- Resolve timeline-item id; == clip.id for imported clips
    grade_fingerprint TEXT,                 -- hash of last-synced grade, for change detection
    edit_fingerprint  TEXT                  -- hash of last-synced edit state (record/source/track/enabled), for conflict detection (FR-025)
);
```

**Fields / validation**
- `jve_clip_uuid` — PK and FK to `clips(id)`; `ON DELETE CASCADE` drops the link when the clip is deleted (FR-013a).
- `resolve_item_id` — Resolve timeline-item id (NOT NULL). For imported clips it equals `clip.id`; carried explicitly so UUID clips (matched positionally) and imported clips share one schema.
- `grade_fingerprint` — fingerprint of the grade last synced; detects "did the grade change in Resolve since last sync" without diffing full CDLs. NULL until first grade sync. **Contract**: nil-or-non-empty-string only; the model rejects `""` (empty string is a malformed bootstrap signal that would force re-bootstrap forever).
- `edit_fingerprint` — fingerprint of the edit state (record start/duration, source in/out, track, enabled) at last sync; an edit-pull compares the live state and the current JVE clip against this to tell a Resolve-side change from a JVE-side local change (FR-025). NULL until first connect/sync. Same nil-or-non-empty contract as `grade_fingerprint`.

**Spec 024 extension** (color management — draft): adds three
columns copied from Resolve's project settings at link time —
`source_color_science_mode` (`davinci_yrgb` | `davinci_yrgb_cm` |
`aces`), `source_working_color_space`, `source_output_color_space`.
Renderer's apply path uses these to pick the correct pipeline so
the output matches Resolve's preview for the source project's mode
(spec 024 FR-012/013/014). Not present in 023 — added by 024's
data-model update. Pointer here so 023 readers see the extension
exists.

**Algorithmic invariant**: each `resolve_item_id` maps to at most one JVE clip. Blade-inherit fragments do **not** get their own ledger rows — only the parent's row is persisted; fragments inherit the parent's mapping at query time. `identity_ledger.lookup_clip_id` asserts the uniqueness (defensive against reconcile bugs); a future schema bump may enforce it via `UNIQUE(resolve_item_id)`.

**Lifecycle**
- **Created/updated**: by `SendToResolve` (outbound mapping), the sync-time auto-discovery (`core/resolve_bridge/discovery.lua`, runs inside both syncs — marker channel else positional per FR-011c), `SyncGradesFromResolve` (`grade_fingerprint`), and `SyncEditsFromResolve` (`edit_fingerprint`). Always inside a `command_event`.
- **Reconcile (FR-012)**: on re-send / re-connect, for each current JVE clip —
  - `clip.id` matches a live Resolve item id → direct link (the common case for imported clips);
  - else positional/content match (source-clip identity `master.import_uuid` + source TC + timeline position, FR-011c);
  - blade/split fragment of a prior clip → both fragments inherit the parent's `resolve_item_id` and grade (bladed both-inherit). **Resolved 2026-06-10 (Phase-4 de-risk)**: grade inheritance happens **at blade time** — `SplitClip` copies the parent's `clip_grade` row onto the right fragment via `ClipGrade.copy_to` (the left fragment keeps the parent's clip id, hence its row). A blade is render-invariant by domain definition, the View pulls grades by clip id, and self-carrying fragments eliminate the fragment-recognition problem. Ledger rows stay parent-only until the next send (each re-send stamps fragments with their own ids, after which they map directly).
  - unmatched → reported, not silently dropped.
- **Deleted**: only by FK cascade.

---

## Relationships

```
clips (1) ──< clip_grade            (0..1 grade per clip; cascade delete)
clips (1) ──< resolve_bridge_link   (0..1 link per clip;  cascade delete)
clip_grade.clip_id  == resolve_bridge_link.jve_clip_uuid  (both are clips.id)
```

A clip may have a link without a grade (sent but not yet graded) or a grade without a current link (Resolve item later deleted → grade marked `stale`).

## Model layer

`src/lua/models/clip_grade.lua` — mirrors existing model conventions (`models/clip.lua`: no `database.get_connection()` from commands; SQL isolation policy). Public surface:
- `ClipGrade.load(clip_id)` / `ClipGrade.batch_load(clip_ids)` — for the renderer (pull-based, FR-016).
- `ClipGrade.fingerprint(grade)` — stable hash for `grade_fingerprint`.
- write helpers used **only** by the command layer (assert CDL all-or-nothing + fidelity enum at the boundary).

`src/lua/core/resolve_bridge/identity_ledger.lua` — `resolve_bridge_link` read/write + the reconcile algorithm above.

## Non-trivial test values (constitution III)

- A clip at TC `01:00:04:12` @ 23.976 with a CDL of slope `(1.05, 0.98, 0.92)`, offset `(0.01, 0.0, -0.02)`, power `(1.1, 1.0, 0.95)`, sat `0.85` — exercises non-unity per-channel values, not the all-1.0 identity that would hide bugs.
- A `partial`-fidelity clip with a LUT path and NULL CDL — exercises the fidelity/representability branch.
- A graded clip whose Resolve item is removed → `stale=1`, grade retained.
- Delete the clip → both `clip_grade` and `resolve_bridge_link` rows gone (cascade).

**Failure-path tests (ENGINEERING 2.32)** — assert boundaries tested via `pcall`, validating the message is actionable (names the clip id + the violated invariant):
- Writing a partial CDL (e.g. `slope_r` set, `power_b` NULL) → asserts (all-nine-or-none invariant).
- Writing `fidelity` outside the enum → asserts.
- Writing a `clip_grade` outside a `command_event` → asserts (command-only mutation, `todo_command_bypass_enforcement`).

---

## SyncEditsFromResolve — classification + dispatch contract (FR-024 / FR-025)

The `read_timeline` response from the helper (`contracts/helper-protocol.md` §`read_timeline`) is classified into four buckets before any model write happens. `classify_all` is pure data; `apply` translates each `to_apply` entry into existing JVE commands under one undo group — no parallel clip-mutation path (1.9). Source: `src/lua/core/commands/sync_edits_from_resolve.lua`, `src/lua/core/resolve_bridge/edit_diff.lua`, `src/lua/core/resolve_bridge/identity_ledger.lua`.

**Wire shape vs classifier input.** The helper returns `(track_type, track_index)` because track identity is positional, not carried (Resolve preserves DRT track order through import; see `contracts/helper-protocol.md` §read_timeline). `M.translate_wire_response(wire_response, sequence_id)` is the boundary function that walks each wire item, calls `Track.find_at(sequence_id, UPPER(track_type), track_index)`, and produces a classifier-shape item with a JVE `track_id` in place of `(track_type, track_index)`. Items whose Resolve track has no JVE counterpart (user added a track in Resolve) get a sentinel string `"resolve-missing-track:<type>:<index>"` that `classify_track_change`'s existing `Track.load(row.track_id) == nil` check surfaces as a `missing_target_track_in_jve` conflict (the sentinel is carried verbatim through to `conflicts[].live_track_id` for debuggability). `M.execute` calls `M.translate_wire_response` on the helper response and feeds the translated shape to `M.apply`; from `M.apply` and `M.classify_all`'s perspective every input item carries a non-empty `track_id` string (JVE-namespace), so synthetic test fixtures can call those entry points directly without a fake helper response.

### Scope

- **V1 ships VIDEO only.** Audio support — subframe-aware fingerprint, table-typed positional fields, sample-rate mismatch handling — lands separately (`todo_t054_audio_support`).
- **One Resolve timeline per response** (helper-protocol guarantee). The classifier does not detect cross-timeline contamination from response shape alone; it asserts each clip's `owner_sequence_id` matches the supplied `sequence_id`.
- **Schema V13+** required (`resolve_bridge_link` table and its `resolve_item_id` index).

### `classify_all(response, sequence_id, db, take_resolve_set?) → {to_apply, conflicts, skipped, unmatched}`

Inputs:
- `response` — helper `read_timeline` payload.
- `sequence_id` — JVE sequence the response describes.
- `db` — open SQLite connection (clip + ledger reads).
- `take_resolve_set` — optional `{[clip_id] = true}`; clips listed here have their stored fingerprint synthesized from `current` (caller chose Take-Resolve on a prior conflict).

Internal phases:
1. **Response walk** — `classify_row` per item: ledger lookup → clip load + invariant assert → V1 video-only assert → track-change branch → edit-diff branch.
2. **Ledger walk** — for each `resolve_bridge_link` row whose clip belongs to `sequence_id` and whose `resolve_item_id` was not seen in the response, emit a `deleted_in_resolve` conflict.

Iteration order is response order, not contractual; callers key bucket entries by `clip_id` (or `resolve_item_id` for `unmatched`).

### Bucket entry shapes

| Bucket | Required fields | Optional |
|--------|------------------|----------|
| `to_apply[]` | `clip_id, resolve_item_id, kind="resolve_only", live, current, stored_fp, track_id, track_type` | `bootstrapped`, `requires_track_move`, `target_track_id` |
| `conflicts[]` | `resolve_item_id, reason` | `clip_id, kind, live, current, stored_fp, track_id, track_type, live_track_id` |
| `skipped[]` | `clip_id, resolve_item_id, reason, live, current, stored_fp, track_id, track_type` | `bootstrapped` |
| `unmatched[]` | `resolve_item_id, reason` | — |

`kind` (the `edit_diff.classify` outcome) is preserved on `to_apply` entries and on `conflicts` entries whose reason is `diverged_both_sides`; elsewhere `reason` is the sole discriminator. `bootstrapped = true` marks entries whose `stored_fp` was synthesized from `current` (no prior ledger fingerprint); `apply` persists those fingerprints outside the undo group so subsequent syncs have a baseline.

### Closed-set reasons

```
CONFLICT_REASONS = {
    diverged_both_sides, deleted_in_resolve,
    fps_mismatch_unsupported, subframe_unsupported,
    composite_undecomposable,
    mutual_composite, overwrite_absorb_inconsistent,
    slip_unsupported, roll_unsupported,
    multi_mapped_ambiguous, missing_target_track_in_jve,
}
SKIP_REASONS = {
    neither_changed, only_jve_changed,
    no_modal_v1_unhandled_conflict, stale_user_choice,
    phase0_failed, phaseB_failed, unknown_delta_shape,
}
UNMATCHED_REASONS = { ledger_missing }
```

Every emit point asserts its `reason` is in the appropriate set — catches typos and drift between spec and code (2.21). Pass-1 `classify_all` emits a subset; the remainder become reachable in Pass-2 `apply`.

### `apply(response, sequence_id, project_id, db, user_choices?) → {applied, failed, skipped, fingerprints_persisted}`

`user_choices` (V2): `{take_resolve: [clip_id], keep_jve: [clip_id], delete_locally: [{clip_id, flavor: "ripple"|"overwrite"}]}`. The three lists are mutually exclusive per clip; `apply` asserts. V1 MVP path ignores `user_choices` and surfaces conflict entries as `apply.skipped[]` with `reason = no_modal_v1_unhandled_conflict`.

Internal flow:
1. Pre-flight intent resolution (delete-wins, mutual-exclusion assert).
2. Build `take_resolve_set`; `classify_all(response, sequence_id, db, take_resolve_set)`.
3. Persist bootstrap fingerprints for every entry — in `skipped[]` OR `to_apply[]` — with `bootstrapped = true` (outside undo group; metadata-only). Persisting bootstrapped `to_apply` entries up front means a subsequent dispatch failure leaves the baseline fingerprint in place so the next sync diffs against it.
4. V1 MVP path: surface `conflicts[]` entries into `result.skipped[]` with `reason = no_modal_v1_unhandled_conflict`, carrying the classifier's `kind / live / current / stored_fp / track_id / track_type / live_track_id` fields through verbatim (modal shape parity). Also pass through `classified.skipped` entries.
5. If no `to_apply` dispatches planned → return.
6. `command_manager.begin_undo_group("Sync Edits from Resolve")`.
7. Pre-Phase-0 — `delete_locally` dispatches (V2 only; V1 user_choices=nil → no deletes).
8. **Phase 0** — `MoveClipToTrack` per `to_apply` entry with `requires_track_move = true`.
9. **Phase A** — `ToggleClipEnabled` per clip with Δenabled.
10. **Phase B** — pure-trim convergence per `to_apply` entry. Algebra (forward clip): LEFT edge delta L = Δsource_in (also moves record_start by +L, duration by −L); RIGHT edge delta R = Δsource_out (moves duration by +R). So a residual is **trim-decomposable** iff Δrecord_start == Δsource_in AND Δrecord_dur == Δsource_out − Δsource_in; otherwise it's Phase C/D territory and rejected upstream by the staging guard. **V1 dispatches `OverwriteTrimEdge`** (left then right, each only when nonzero) — *not* `RippleTrimEdge`. Rationale: Resolve gives absolute per-clip positions for every clip in the response, so single-clip overwrite converges each entry to its live target independently. RippleTrim would shift other `to_apply` clips off their targets. The earlier "blanket reload after each `RippleTrimEdge`" caveat therefore does not apply in V1; a future variant that infers ripple intent would reintroduce it. Per-clip cascade: `phase0_failed` → skip B (geom on a wrong-track clip is meaningless); `phaseB_failed` → push `phaseB_failed` to skipped[] and cascade-skip C. Within a clip: left dispatched before right; left failure skips right (clip didn't converge).
11. **Phase C** — `Nudge` for residual record_start shift M = (live.record_start − cur.record_start) reloaded *after* Phase B. The combined trim+move algebra is L = Δsource_in, R = Δsource_out, M = Δrecord_start − L; Phase B handles L/R and leaves M as the leftover record_start residual. Dispatched as `Nudge{selected_clip_ids=[clip_id], nudge_amount=M}` per entry where M ≠ 0. Cascade: `phase0_failed` → `skipped_phase0_failed`; `phaseB_failed` → `skipped_phaseB_failed`. Phase C failure does NOT cascade further (Phase D is classification, not dispatch).
12. **Phase D** — **runs first** (before init/begin_undo_group), as a partition: any entry whose deltas are non-decomposable (Δrecord_dur ≠ Δsource_out − Δsource_in) gets surfaced as `apply.skipped[]` with `reason = unknown_delta_shape` immediately; only decomposable entries enter the dispatch ladder. No clip mutation, no fingerprint persist for shape-failed entries — next sync re-classifies and re-surfaces until the user resolves out-of-band.
13. `end_undo_group`.
14. Persist post-dispatch fingerprints for clips whose every dispatched verb succeeded (outside undo group).

### Result bucket shapes

| Bucket | Required fields | Optional |
|--------|-----------------|----------|
| `applied[]` | `clip_id, resolve_item_id, attempted_verbs` (array of verb strings in dispatch order) | — |
| `failed[]` | `clip_id, resolve_item_id, attempted_verb, args, error` | — |
| `skipped[]` | `clip_id, resolve_item_id, reason` | `kind, live, current, stored_fp, track_id, track_type, live_track_id` (carried from classifier) |
| `fingerprints_persisted[]` | `clip_id, resolve_item_id, edit_fingerprint, origin` (`"bootstrap"` or `"phase_success"`) | — |

`failed[]` is per-(clip, verb): one entry per attempted dispatch that returned `success=false`. Per-phase failure cascade: Phase 0 failure cascade-skips A/B/C for that clip (`reason = phase0_failed` added to `skipped[]`); Phase A failure is independent (`enabled` is geometrically inert); Phase B failure cascade-skips C (`reason = phaseB_failed`). Fingerprints persist only for clips whose every attempted phase succeeded; partial-success clips retain their prior fingerprint so the next sync retries.

### Dispatch verbs

```
DISPATCH_VERBS = {
    MoveClipToTrack, ToggleClipEnabled,
    RippleTrimEdge, OverwriteTrimEdge, Nudge,
    DeleteClip, RippleDelete,
}
```

Adding a verb means updating this constant and this section; the dispatcher asserts every `command_manager.execute` verb name is in the set.

### Modal contract

The conflict modal consumes `conflicts[]`, surfaces per-row choices, and returns `user_choices` to `apply`. V1 modal does not show auto-`to_apply` entries — those dispatch by implicit consent; a user can undo the whole sync after the fact. UI layout lives in `src/lua/ui/` and evolves independently of this data contract.
