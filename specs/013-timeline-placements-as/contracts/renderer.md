# Contract: Timeline Renderer & Inspector (Pull Surfaces)

**Feature**: 013-timeline-placements-as — Phase 1 contract

The timeline view renderer and the inspector are pull surfaces: they query model state and render. This contract defines what they read from the model so that clips and media_refs display correctly under the new three-table model.

---

## Timeline View Renderer (`src/lua/ui/timeline/view/timeline_view_renderer.lua`)

The renderer is shown the currently-focused sequence. It queries different tables based on that sequence's kind.

### When rendering a `kind='nested'` sequence (edit timeline or any composed sequence)

Rows come from `clips`. Per clip:

| Field | Purpose |
|---|---|
| `id` | Selection key, render identity |
| `nested_sequence_id` | Follow to the nested sequence for waveform/offline lookup |
| `master_layer_track_id` | Determines which V track of the nested sequence contributes |
| `owner_sequence_id`, `track_id` | Routing |
| `timeline_start_frame`, `duration_frames` | Position + width |
| `source_in_frame`, `source_out_frame` | Window into the nested sequence's timebase (drives waveform viewport clipping) |
| `enabled` | Dim indicator |
| `name` | Label text |
| `volume` | Not displayed at the clip rectangle level in first landing |

### When rendering a `kind='master'` sequence (user opened a master to inspect its contents)

Rows come from `media_refs`. Per media_ref:

| Field | Purpose |
|---|---|
| `id` | Selection key |
| `media_id` | Direct FK to `media` for waveform/offline (trivial lookup — no chain) |
| `owner_sequence_id`, `track_id` | Routing |
| `timeline_start_frame`, `duration_frames` | Position + width |
| `source_in_frame`, `source_out_frame` | Window into the media file's native units |
| `enabled`, `volume`, `name` | Standard |

### Derived lookups

| Derivation | Source |
|---|---|
| Media file path for a clip's waveform/offline indicator | Follow `nested_sequence_id` → the nested sequence → its `media_refs` on the `master_layer_track_id`-selected track (or the inferred default) → `media.file_path`. Multi-level recursion if the nested sequence is itself non-master. |
| Waveform source range for a clip | Recurse one level: the nested sequence's `media_refs` on the clip's audio channels, windowed by the clip's `source_in/out` converted through any intermediate fps changes. |
| "Is this clip offline?" | Walk the chain to a media_ref; check the referenced `media` row's offline state. If the chain is broken at any level (missing nested sequence, deleted track), the clip itself is broken. |
| "Is a content change pending inside?" | `sequences.mutation_generation` cache on the chain + last-seen generations, triggers re-resolve. |

### What the renderer MUST NOT do

- **MUST NOT read `clips.media_id`** — that column doesn't exist on `clips` under the new model. Any code asking for a timeline clip's media directly must follow the chain.
- **MUST NOT cache resolved media paths across `mutation_generation` bumps** on any sequence in the chain — a content change in an intermediate nested sequence invalidates downstream caches.
- **MUST NOT silently hide** any offline/broken/loading state per FR-022. Indicators are mandatory unless the user has opted out via preferences.

### Contract tests

**CT-RN1** (waveform path through a clip): Given a clip whose nested sequence is a master, the waveform data resolves through `clips.nested_sequence_id` → master's audio `media_refs` → `media_id` → peak file.

**CT-RN2** (layer selection affects color): Given a clip with `master_layer_track_id = V2` on a multicam master where V1 and V2 have distinct track colors, the clip rectangle shows V2's color.

**CT-RN3** (offline propagates through chain): Given a clip whose nested sequence's media_ref's media is offline, the clip shows the offline overlay.

**CT-RN4** (override edits trigger redraw): Given a clip displayed on the timeline, when `SetClipLayer` mutates its layer, the renderer re-resolves and reflects the new layer within one frame.

**CT-RN5** (broken chain loud-fail): Given a clip whose `nested_sequence_id` references a deleted sequence, the clip shows a "broken reference" loud-fail indicator.

**CT-RN6** (master-interior view): Given a master sequence opened in the renderer, its tracks show `media_refs` rows, not `clips` rows. The waveform comes directly from each media_ref's `media_id` without any chain traversal.

---

## Inspector (`src/lua/ui/inspector/schema.lua`)

### Clip inspector (for selection on a non-master sequence)

| Field | Editable? | Source |
|---|---|---|
| Nested sequence name | No (read-only; click-through to open the nested sequence) | `sequences.name` via `clips.nested_sequence_id` |
| Window start (timeline) | Yes (drives TrimHead) | `clips.timeline_start_frame` |
| Window duration | Yes (drives TrimTail/Slip) | `clips.duration_frames` |
| Source in (nested seq's timebase) | Yes | `clips.source_in_frame` |
| Source out | Yes | `clips.source_out_frame` |
| Exposed video layer | Yes — dropdown of nested seq's V tracks + "Default" | `clips.master_layer_track_id` (NULL = default) |
| Channel enables + gains | Yes — toggle/slider per channel; "Revert to default" button per channel | `clip_channel_override` joined with inherited state |
| fps-mismatch policy | Yes — {Resample, Pass-through, Project default} | `clips.fps_mismatch_policy` |
| Offline indicator | Read-only | Derived via chain |

### Master-sequence inspector (for selection on a master sequence — opened in browser)

| Field | Editable? | Source |
|---|---|---|
| Video start TC | Yes | `sequences.video_start_tc_frame` |
| Audio start TC | Yes | `sequences.audio_start_tc_samples` |
| Default video layer | Yes — dropdown of master's V tracks | `sequences.default_video_layer_track_id` |
| Master channel state (per channel) | Yes | `media_refs_channel_state` rows |

### Sequence inspector (for selection on any non-master sequence)

Same shape as the master inspector but exposes the defaults that apply when THIS sequence is nested inside another:
| Field | Editable? | Source |
|---|---|---|
| Video start TC | Yes | `sequences.video_start_tc_frame` |
| Audio start TC | Yes | `sequences.audio_start_tc_samples` |
| Default video layer (for when this sequence is itself nested) | Yes | `sequences.default_video_layer_track_id` |

### Media ref inspector (for selection on a master-sequence view)

| Field | Editable? | Source |
|---|---|---|
| Media file name + path | Read-only | `media` joined via `media_id` |
| Window start / duration | Yes | `media_refs.timeline_start_frame`, `duration_frames` |
| Source in / out (in file's native units) | Yes | `media_refs.source_in_frame`, `source_out_frame` |
| Enabled / volume | Yes | `media_refs.enabled`, `volume` |

### Inspector contract tests

**CT-IN1** (override field dispatches command): Given the inspector on a clip, toggling channel 2 dispatches `ToggleClipChannel`, not a direct DB write.

**CT-IN2** (master-level edit propagates): Given two clips of the same master and the inspector on the master, when the user changes master default layer, both clips reflect the new default on next playback (unless they have their own layer overrides).

**CT-IN3** (revert-to-default button): Given the inspector on a clip with an overridden channel, when the user clicks "Revert", the override row is deleted and the displayed value becomes the inherited value.

**CT-IN4** (same inspector surface across any sequence's own defaults): Inspector shape for `sequences.default_video_layer_track_id` + start TCs is identical whether the selected sequence is `kind='master'` or `kind='nested'` — both kinds expose those defaults.

---

## User preference: loud-fail indicators

FR-022: a user preference controls whether offline/broken/loading state renders with loud indicators or is suppressed.

**CT-PREF1**: With the default preference (loud-fail on), an offline clip renders with the offline overlay. With the preference flipped to suppress, it renders without the overlay but loud logging persists.
