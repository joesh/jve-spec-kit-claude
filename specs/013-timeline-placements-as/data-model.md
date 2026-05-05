# Phase 1 Data Model: Timeline Placements as Nested Sequence References

**Feature**: 013-timeline-placements-as
**Date**: 2026-04-23

Concrete schema + entity fields + invariants derived from spec.md's Key Entities + research.md's decisions.

## Vocabulary

| Term | Meaning |
|---|---|
| Sequence | Any row in `sequences`. |
| Master sequence | A sequence with `kind='master'`. Its tracks hold `media_refs` (direct references to media files). |
| Non-master sequence | A sequence with `kind='nested'`. Its tracks hold `clips` (references to other sequences). The user's edit timelines and any user-created composed sequences are non-master. |
| Nested sequence (role) | Any sequence (master OR non-master) *while currently placed inside another sequence*. Nesting is a usage, not a kind — a clip row in `clips` is what makes a sequence nested at that position. |
| Clip | A user-facing row on a non-master sequence's track. Internally a reference to another sequence. What the user drags around. |
| Media ref | A row on a master sequence's track. Directly references a file via `media_id`. |
| File | User-facing term for a media ref as shown inside a master sequence. |

## Tables

### `sequences` (existing — column changes)

```sql
CREATE TABLE sequences (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK(kind IN ('master', 'nested')),

    -- Timebase
    fps_numerator INTEGER NOT NULL,
    fps_denominator INTEGER NOT NULL,
    audio_rate INTEGER NOT NULL,
    width INTEGER NOT NULL,
    height INTEGER NOT NULL,

    -- Display / editing state
    start_timecode_frame INTEGER NOT NULL DEFAULT 0,
    playhead_frame INTEGER NOT NULL DEFAULT 0,
    mutation_generation INTEGER NOT NULL DEFAULT 0,

    -- NEW: default video layer (meaningful for any sequence that might be
    -- referenced by a clip — i.e. any sequence). Non-NULL whenever the
    -- sequence has at least one video track (INV-8).
    default_video_layer_track_id TEXT REFERENCES tracks(id) ON DELETE SET NULL,

    -- NEW: user-modifiable start TCs (per FR-017).
    video_start_tc_frame INTEGER,
    audio_start_tc_samples INTEGER,

    -- NEW: per-sequence fps-mismatch policy override (FR-015).
    -- NULL = inherit the project-level default.
    fps_mismatch_policy TEXT
);
```

**Kind values reduce from four to two.** The old values `'timeline', 'masterclip', 'compound', 'multicam'` collapse:

| Old kind | New kind | Notes |
|---|---|---|
| `masterclip` | `master` | Same role: source wrapper created by import. |
| `multicam` | `master` | Still a master — it just has N video tracks (one per angle) instead of one. Multicam is a structural shape of a master, not a separate kind. |
| `timeline` | `nested` | User's edit timelines are non-master sequences. They can be nested inside other sequences. |
| `compound` | `nested` | A user-created compound (via "Nest Selection") is structurally the same as any edit timeline. |

### `media_refs` (NEW)

```sql
CREATE TABLE media_refs (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    -- Containment: which master sequence and which track.
    owner_sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,
    track_id TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,

    -- What file is referenced and which portion of it.
    media_id TEXT NOT NULL REFERENCES media(id) ON DELETE SET NULL,
    -- Absolute TC: source_in_frame = file_tc_origin + zero-based file index.
    -- For most files the TC origin is 0 so source_in = file index. For files
    -- with embedded TC (cinema-camera grabs, DPX/EXR sequences, BWF audio)
    -- the TC origin shifts the addressable range. Frames for video, samples
    -- for audio, both at the file's native rate.
    source_in_frame INTEGER NOT NULL,
    source_out_frame INTEGER NOT NULL,

    -- Where on the master's track this portion sits.
    timeline_start_frame INTEGER NOT NULL,
    duration_frames INTEGER NOT NULL CHECK(duration_frames > 0),

    -- Source timebase is the referenced media's (media.fps_numerator /
    -- fps_denominator); not carried on this row to avoid denormalization.
    -- Every query that reads source_in/out also loads the media row for its
    -- path, so the timebase is already in hand.

    -- State (explicit on INSERT; no column defaults — rule 2.13)
    enabled INTEGER NOT NULL,
    volume REAL NOT NULL,
    mark_in_frame INTEGER,
    mark_out_frame INTEGER,
    playhead_frame INTEGER NOT NULL,

    created_at INTEGER NOT NULL,
    modified_at INTEGER NOT NULL
);

CREATE INDEX idx_media_refs_owning_sequence ON media_refs(owner_sequence_id);
CREATE INDEX idx_media_refs_track ON media_refs(track_id);
CREATE INDEX idx_media_refs_media ON media_refs(media_id);
```

**Semantics**:
- One row per track-positioning of a media file inside a master sequence. A single-file A/V .mov appears as 3 rows inside its master (V track + two A channel tracks), all pointing at the same `media.id` via FK.
- `source_in/out_frame` are absolute TC = file's TC origin + zero-based file index, in the file's native units (frames for video, samples for audio) at the file's native fps / sample rate.
- A fresh import of a single file yields one media_ref with `source_in_frame = file_tc_origin`, `source_out_frame = file_tc_origin + file_duration`, and `timeline_start_frame = file_tc_origin` — the master sequence's timebase IS absolute TC space, with the range `[0, file_tc_origin)` empty (no media there).
- C++ decode recovers the file-relative position: `file_pos = source_in_frame - file_tc_origin`.
- `owner_sequence_id` must reference a `kind='master'` sequence (enforced at model layer, validated on write).

**Replaces**: today's `clips` rows where `clip_kind='master'`. Column-for-column near-identical, isolated into its own table per rule 2.21.

### `clips` (existing — semantics narrow, columns change)

```sql
CREATE TABLE clips (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    -- Containment: which non-master sequence and which track.
    owner_sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,
    track_id TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,

    -- What sequence this clip references (master OR non-master — any sequence
    -- can be nested per FR-010).
    nested_sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,

    -- Window into the nested sequence's timebase. When the nested sequence
    -- is kind='master', that timebase IS absolute TC space (file's TC origin
    -- + zero-based offset) — see media_refs above. Forward clips have
    -- source_in < source_out; reverse clips (parser convention) have
    -- source_in > source_out, encoding playback direction by ordering.
    source_in_frame INTEGER NOT NULL,
    source_out_frame INTEGER NOT NULL,

    -- Where on this sequence's track the clip sits. timeline_start_frame and
    -- duration_frames are in the OWNER sequence's timebase; source_in/out are
    -- in the NESTED sequence's timebase. The ratio between them is set by
    -- fps_mismatch_policy below. Neither timebase is carried on this row —
    -- callers dereference owner_sequence_id / nested_sequence_id as needed.
    timeline_start_frame INTEGER NOT NULL,
    duration_frames INTEGER NOT NULL CHECK(duration_frames > 0),

    -- Per-clip video-layer override (NULL = inherit nested sequence's default).
    master_layer_track_id TEXT REFERENCES tracks(id) ON DELETE SET NULL,

    -- Per-clip audio-track selector. NULL = composite (play all of the nested
    -- sequence's audio tracks together; FR-005). Non-NULL = expose exactly one
    -- of the nested sequence's audio tracks (FR-023/FR-024 — Expand/Collapse).
    -- Symmetric to master_layer_track_id but for audio. Set non-NULL only on
    -- audio clips; refused on video clips at the model layer.
    master_audio_track_id TEXT REFERENCES tracks(id) ON DELETE SET NULL,

    -- fps-mismatch policy. NOT NULL — set at Insert time from the effective
    -- default (project → sequence → optional Insert arg). Flipping this
    -- policy is a structural mutation: duration_frames above was computed
    -- under THIS policy at write time, so SetFpsMismatchPolicy re-computes
    -- duration and ripples downstream. Inheritance happens at Insert time,
    -- not at resolve time.
    fps_mismatch_policy TEXT NOT NULL
        CHECK(fps_mismatch_policy IN ('resample','passthrough')),

    -- State (explicit on INSERT; no column defaults — rule 2.13)
    name TEXT NOT NULL,
    enabled INTEGER NOT NULL,
    volume REAL NOT NULL,
    mark_in_frame INTEGER,
    mark_out_frame INTEGER,
    playhead_frame INTEGER NOT NULL,

    created_at INTEGER NOT NULL,
    modified_at INTEGER NOT NULL
);

CREATE INDEX idx_clips_owning_sequence ON clips(owner_sequence_id);
CREATE INDEX idx_clips_track ON clips(track_id);
CREATE INDEX idx_clips_nested_sequence ON clips(nested_sequence_id);
```

**Semantics**:
- Every row references another sequence via `nested_sequence_id`. That sequence can be `kind='master'` (common case — the clip plays a file) or `kind='nested'` (a user-nested compound).
- `source_in/out_frame` are in the nested sequence's timebase (frames at its `fps_numerator/fps_denominator`).
- `owner_sequence_id` must reference a `kind='nested'` sequence (enforced at model layer).
- Cycle detection refuses any write where `nested_sequence_id` would produce a direct or transitive cycle.

**Columns dropped from today's `clips`**: `clip_kind`, `master_clip_id` (renamed to `nested_sequence_id` with clearer semantics), `media_id` (media refs moved to their own table). `offline` is dropped because offline state is a derived property of the chain (clip → nested sequence → eventually a media_ref → media.offline state); the renderer computes it at display time from the media row.

### `media_refs_channel_state` (NEW — was `master_channel_state` in earlier draft)

```sql
CREATE TABLE media_refs_channel_state (
    owner_sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,
    channel_index INTEGER NOT NULL,       -- 0-based into the master's audio channel list
    enabled INTEGER NOT NULL,
    default_gain_db REAL NOT NULL,
    PRIMARY KEY (owner_sequence_id, channel_index)
);
```

Master-sequence-level channel state. Rows exist only for channels the user has explicitly touched at the master level; absent row = the master's default-channel-state contract (enabled, unity gain) applied by the resolver. Both `enabled` and `default_gain_db` are explicit on INSERT (no column defaults — rule 2.13; the resolver's default-channel-state contract lives in one place, not duplicated in the schema). Keyframed automation on this state is deferred per spec non-goals; first landing stores static values only.

### `clip_channel_override` (NEW)

```sql
CREATE TABLE clip_channel_override (
    clip_id TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
    channel_index INTEGER NOT NULL,       -- 0-based into the nested sequence's audio channel list
    enabled INTEGER NOT NULL,
    gain_db REAL NOT NULL,
    PRIMARY KEY (clip_id, channel_index)
);

CREATE INDEX idx_clip_channel_override_clip ON clip_channel_override(clip_id);
```

Per-clip channel overrides. Sparsely populated: a row exists only when the editor has explicitly set enable/gain on that channel for that clip. Absent row = inherit the nested sequence's state (which in turn may come from `media_refs_channel_state` or the resolver's default-channel-state contract). `ON DELETE CASCADE` — delete the clip, overrides evaporate.

Both `enabled` and `gain_db` are explicit on INSERT (no column defaults — rule 2.13). The `ToggleClipChannel` command materializes an override from the currently-inherited effective state, so a row always carries real values rather than silently picking up a schema default that could mask the intended inherited value.

### `clip_links` (existing — scope narrows to clips only)

```sql
CREATE TABLE clip_links (
    id INTEGER PRIMARY KEY,
    link_group_id TEXT NOT NULL,
    clip_id TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
    role TEXT,
    time_offset INTEGER,
    enabled BOOLEAN
);
```

Unchanged structure. Now exclusively references `clips` (media_refs don't have link groups — they're internal to masters). When a single drop produces both a V and an A clip, the two clips get `clip_links` rows sharing a new `link_group_id`.

## Table roles summarized

```
sequences (kind='master')
    tracks hold   →   media_refs  (media_id → media)
                                   + media_refs_channel_state (per-channel state at master level)

sequences (kind='nested')
    tracks hold   →   clips  (nested_sequence_id → sequences, any kind)
                            + clip_channel_override (per-clip channel overrides)
                            + clip_links (V+A link groups)
```

## Invariants

| ID | Invariant | Enforced by |
|---|---|---|
| INV-1 | Every `media_refs` row's `owner_sequence_id` references a `kind='master'` sequence. | Model-layer actionable assert on write; runtime check via JOIN for defense in depth. |
| INV-2 | Every `clips` row's `owner_sequence_id` references a `kind='nested'` sequence. | Same. |
| INV-3 | No cycle in the containment DAG: a sequence reached by walking `clips.nested_sequence_id` cannot contain a clip whose `nested_sequence_id` resolves back to the starting sequence (directly or transitively). | `would_create_cycle` DFS at mutation time per research §3; defense-in-depth assert in resolver at playback time. |
| INV-4 | A clip's source window must satisfy `source_in_frame ≥ 0` (negative bounds forbidden) and `source_in_frame ≠ source_out_frame` (empty window forbidden). Direction-agnostic — forward clips have `source_in < source_out`, reverse clips have `source_in > source_out`. **No upper-bound check** at the model layer: when nested is a master sequence, its duration mirrors a mutable media file (relink to a shorter file would invalidate existing clips retroactively, and the importer must not look at media files at all). Past-extent windows are handled by the runtime path — relinker `partial_coverage` notes, source-viewer offline overlays, decoder silence/black past file end. Per-command preconditions (Trim, Slip, Roll) still clamp/refuse against the current master duration; that's the right scope for the upper bound. | `Clip.assert_window_in_bounds`; editing commands (trim, slip, roll, etc.) clamp or refuse. |
| INV-5 | `clip_channel_override.channel_index` refers to an existing channel in the referenced nested sequence's audio layout at resolution time. | Resolver asserts loudly if the channel has been removed; fallback to master state is NOT silent. |
| INV-6 | On master-track deletion, every `clips.master_layer_track_id` pointing at the deleted track is set to NULL by the DB FK (`ON DELETE SET NULL`). The MASTER's own `default_video_layer_track_id` must still refer to a live track, or be NULL-only-if-the-master-has-no-video-tracks (INV-8). | DB FK + model assertion on master after track-delete. |
| INV-7 | Every `clips` row is in at most one link group (it may have zero or one row in `clip_links`). | `clip_links` table semantics (enforced in link/unlink commands). |
| INV-8 | `sequences.default_video_layer_track_id` is non-NULL whenever the sequence has at least one video track. | Model-layer assertion on every `sequences` write; cross-checked after track-delete commands. |
| INV-9 | `clips.master_audio_track_id`, when non-NULL, references a track that (a) belongs to the clip's `nested_sequence_id` and (b) has `kind='audio'`. NULL means composite (play all of the nested sequence's audio tracks). The column is non-NULL only on clips whose `track_id` is itself an audio track of the owner sequence (you cannot put an audio-track selector on a video clip). | Model-layer assertion on every `clips` write; FK + DB CHECK on the audio-only requirement; `ON DELETE SET NULL` falls the column back to composite when the referenced audio track is deleted. |

## State transitions

### Clip channel state (per channel)

```
(tracking master)       no row in clip_channel_override; playback reads master's media_refs_channel_state
    │
    ├─ ToggleClipChannel / SetClipChannelGain → row inserted
    │
(overridden)            row present with user values
    │
    ├─ ClearClipOverride → row deleted → back to (tracking master)
    │
    └─ (clip deleted) → row cascaded away
```

### Clip layer selection

```
(tracking master default)    clips.master_layer_track_id = NULL
    │
    ├─ SetClipLayer(track_id) → set to track_id
    │
(overridden)                 points at a specific track_id of the referenced master
    │
    └─ SetClipLayer(NULL) → back to (tracking master default)
```

### Clip creation

```
(user drops master M on an edit timeline E's track T at frame F)
    ↓
cycle check (M referenced from E would not cause a cycle)   →   refuse if would
    ↓
INSERT clips row: owner_sequence_id=E, track_id=T,
                  nested_sequence_id=M, source_in=0, source_out=M.duration_in_M,
                  timeline_start=F, duration=M.duration_in_E_timebase (fps-converted),
                  master_layer_track_id=NULL (tracks M's default),
                  fps_mismatch_policy=NULL (tracks project default)
    ↓
If M has both video and audio tracks: INSERT a second clips row (for the other medium)
on the appropriate track of E, plus two clip_links rows sharing a link_group_id.
```

### Nest / unnest

```
(user selects clips C1..Ck in sequence E and issues "Nest")
    ↓
CREATE new sequences row S with kind='nested'; copy timebase/dimensions from E
    ↓
MOVE C1..Ck from E to S (update owner_sequence_id and track_id on each, preserving relative positions)
    ↓
INSERT one new clips row into E replacing C1..Ck's span,
       with nested_sequence_id=S, source_in=0, source_out=S.duration,
       timeline_start=original earliest start

(user issues "Unnest" on a clip K whose nested_sequence_id=S and S.kind='nested')
    ↓
MOVE S's contents back into E at K.timeline_start (shifted appropriately)
    ↓
DELETE clips row K
    ↓
If S now has no other clips referencing it: DELETE S (orphan cleanup)
```

Nest and unnest are inverses. "Master" sequences cannot be unnested (unnesting would require their tracks to hold clips, but masters hold media_refs — the rule refuses).

## Changes from current schema (diff)

| Table | Change |
|---|---|
| `sequences` | `kind` value set narrows to `'master'/'nested'` (was `'timeline'/'masterclip'/'compound'/'multicam'`); add `default_video_layer_track_id`, `video_start_tc_frame`, `audio_start_tc_samples`, `fps_mismatch_policy`. Drop `view_start_frame`, `view_duration_frames`, `video_scroll_offset`, `audio_scroll_offset`, `video_audio_split_ratio` if those are better modeled as UI/view state elsewhere — out of scope for this feature, retained as-is here. |
| `clips` | **Substantial semantic narrowing.** Drop `clip_kind`, `master_clip_id` (renamed), `media_id`, `offline`. Rename `master_clip_id` → `nested_sequence_id`. Add `master_layer_track_id`, `master_audio_track_id` (FR-005/023/024 — NULL=composite, non-NULL=single audio track of nested sequence), `fps_mismatch_policy`. `source_in/out_frame` units shift from file-native to nested-sequence-timebase. |
| (new) `media_refs` | Takes over all responsibility previously held by `clips` rows where `clip_kind='master'`. Structurally near-identical; isolated for type safety (rule 2.21). |
| (new) `media_refs_channel_state` | Master-level per-channel state. Replaces the `master_channel_state` name from an earlier draft; renamed for parallelism with the `media_refs` table. |
| (new) `clip_channel_override` | Sparse per-clip channel overrides. |
| `clip_links` | Unchanged. |

## Decisions deferred to a separate feature

- **Keyframed automation on `media_refs_channel_state`** — post-first-landing feature per spec Non-Goals. No schema provision made; a future feature adds the keyframe table alongside.

## Decisions settled here (not open)

- **fps-mismatch policy is structural at Insert time, not at resolve time.**
  Because `clips.duration_frames` is expressed in the owner sequence's timebase
  but `source_in/out_frame` is in the nested sequence's timebase, the ratio
  between them depends on the chosen policy. Insert/Overwrite must know the
  policy to compute `duration_frames`. Therefore `clips.fps_mismatch_policy`
  is **NOT NULL** (set at Insert, carried on the row). `SetFpsMismatchPolicy`
  (T064) on an existing clip is a structural mutation that re-computes
  `duration_frames` and ripples downstream. `sequences.fps_mismatch_policy`
  is a nullable per-sequence override of the project default; `clips` read
  the effective value at Insert time (project → sequence → optional explicit
  Insert arg) and freeze it on the row.
- **Rounding under `resample`**: when the fps ratio doesn't land on a whole
  frame, round `duration_frames` to the nearest integer. Accept the sub-frame
  wall-clock drift per clip. This matches Resolve and avoids complicating
  Insert with cumulative-remainder state. A future feature could add a
  strict-refuse mode behind a project flag.
- **`fps_numerator`/`fps_denominator` on `clips` and `media_refs`**: NOT CARRIED.
  The source timebase dereferences to `nested_sequence_id` (for clips) or
  `media_id` (for media_refs). Every query that reads source_in/out is already
  loading the target row for other reasons (path, duration, default layer).
  Carrying the timebase on the row would be pure denormalization — staleness
  risk if the target's rate is ever re-measured, extra writes on every Insert
  / Duplicate / Split, and no read-side wins.
- **Project-level `fps_mismatch_policy` default storage**: new `projects.fps_mismatch_policy TEXT NOT NULL` column (CHECK in {`resample`,`passthrough`}).
- **`media_refs.source_in_frame`**: required on INSERT (no column default — rule 2.13). The importer/drag-drop path always knows the value (0 for a fresh file import, or a real offset for a sub-range media_ref); a schema default would silently mask an importer bug that forgot to set it.
