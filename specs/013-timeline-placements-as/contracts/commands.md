# Contract: Commands

**Feature**: 013-timeline-placements-as — Phase 1 contract

All timeline commands rewired to operate on `clips`; new override commands introduced; nest / unnest commands added. Every entry below includes args, preconditions, mutations, undo state, and emitted signals. Commands are TDD-gated: each has a failing contract test before implementation.

---

## Existing commands — rewired (stop flattening)

### `Insert`

**Args**: `{ sequence_id, nested_sequence_id, timeline_start_frame, tracks_mask, fps_mismatch_policy? }`. `fps_mismatch_policy` is optional; when absent, effective policy = `sequences[sequence_id].fps_mismatch_policy` (if non-NULL) else `projects.fps_mismatch_policy`.

**Pre**: `sequence_id` refers to a `kind='nested'` sequence (you can only insert into non-master sequences); `nested_sequence_id` refers to any existing sequence (master or nested); cycle check (`would_create_cycle`) passes; `timeline_start_frame` is valid; `tracks_mask` names the video and/or audio target tracks.

**Mutations**:
- Compute effective policy per args above; compute `duration_frames` (in owner sequence's timebase) from `nested.duration` (in nested's timebase) per the policy:
  - `resample`: `duration_frames = round(nested.duration * owner.fps / nested.fps)`
  - `passthrough`: `duration_frames = nested.duration` (treated as if already in owner fps; plays faster/slower by the ratio)
- Insert 1 or 2 rows into `clips` (V entry + A entry, one per track the nested sequence contains) with `nested_sequence_id` set, `source_in_frame=0`, `source_out_frame=nested.duration_in_nested_timebase`, `master_layer_track_id=NULL`, `fps_mismatch_policy` = the computed effective policy.
- Ripple any clips on the target tracks at or past `timeline_start_frame` forward by the computed `duration_frames`.
- If 2 rows inserted, insert two `clip_links` rows sharing a new `link_group_id`.

**Undo capture**: inserted row ids + ripple delta + link_group_id.

**Signals**: `sequence_content_changed(sequence_id)`.

**Contract test (CT-C1)**: Given a master with video and stereo audio, when Insert at frame 100, the `clips` table has exactly 2 new rows (one on V track, one on A track), both with the correct `nested_sequence_id`, NULL `master_layer_track_id`, non-NULL `fps_mismatch_policy`, and one `clip_links.link_group_id` groups them. Parametrized over both policies: a 25fps master dropped onto a 24fps timeline produces `duration_frames = 96` under `resample` and `duration_frames = 100` under `passthrough`; `source_out_frame = 100` in both cases (nested-sequence timebase).

---

### `Overwrite`

**Args**: same as `Insert` (including optional `fps_mismatch_policy`).

**Behavior**: same as Insert — effective policy computed, `duration_frames` computed per policy, new clip rows written with the policy frozen on the row — except overlapping clips on target tracks are removed or trimmed instead of rippled.

**Undo capture**: full before-state of modified/removed rows + new rows.

**Contract test (CT-C2)**: Given a timeline with an existing clip from frame 50–150, when Overwrite at frame 100 with a 60-frame nested sequence, the existing clip is trimmed to [50, 100) and the new clip occupies [100, 100 + duration_under_policy). Parametrized over both policies.

---

### Trim commands (`TrimHead`, `TrimTail`)

**Behavior**: mutate the clip's `source_in_frame` (trim head) or `source_out_frame` (trim tail), and adjust `timeline_start_frame` / `duration_frames` accordingly. Ripple variants additionally shift downstream clips.

**Key change**: `source_in/out_frame` are in the nested sequence's timebase, not media-file units. Math otherwise unchanged: trim by N frames means shift in/out by N frames in the nested sequence's fps.

**Contract test (CT-C3)**: Given a clip with `[timeline 100–200, source 0–100 in the nested sequence's timebase]`, when TrimHead by 10, the clip becomes `[timeline 110–200, source 10–100]`.

---

### Slip / Slide / Roll

**Slip**: move `source_in/out_frame` by ±N in the nested sequence's timebase; `timeline_start_frame` and `duration_frames` unchanged. Window must stay within `[0, nested.duration_in_nested_timebase]` per INV-4.

**Slide**: move `timeline_start_frame` by ±N; window unchanged; ripple adjacent clips.

**Roll**: between two adjacent clips on the same track, shift the edit point by ±N, adjusting outgoing's `source_out/duration` and incoming's `source_in/timeline_start/duration`.

**Contract tests (CT-C4/C5/C6)**: one per command; verify source/timeline arithmetic and that the window stays within the nested sequence's bounds (loud-fail on out-of-bounds).

---

### Ripple / Split / Blade / Extend / Delete

All operate on `clips` rows unchanged in mechanics. Split/Blade divides one clip row into two at a chosen timeline frame:

- Left half: `timeline_start` unchanged, `duration` = split_offset, `source_in` unchanged, `source_out` = `source_in + split_offset`.
- Right half: `timeline_start` = original_timeline_start + split_offset, `duration` = remaining, `source_in` = `source_in + split_offset`, `source_out` unchanged.
- Per-clip overrides on the original row: copied to BOTH halves (deliberately — splitting preserves the editor's interpretive intent on both sides of the cut).
- Link group: both halves get new `clip_links` entries sharing a new `link_group_id`.

**Contract test (CT-C7 — split with override)**: Given a clip with `master_layer_track_id = X`, when Split at midpoint, both halves have `master_layer_track_id = X`.

---

### `Duplicate`

Copies a `clips` row to a new `timeline_start`. Also copies the source clip's `master_layer_track_id`, `fps_mismatch_policy`, and all `clip_channel_override` rows.

**Contract test (CT-C8)**: Given a clip with 3 channel overrides, when Duplicate, the new clip has 3 matching channel override rows.

---

## New commands — per-clip overrides

### `SetClipLayer`

**Args**: `{ sequence_id, clip_id, track_id_or_null }`. `sequence_id` is the clip's `owner_sequence_id` (required on every sequence-mutating command per rule 2.29).

**Pre**: clip exists and `clip.owner_sequence_id = sequence_id`; `track_id` (if non-NULL) belongs to the clip's `nested_sequence_id`.

**Mutation**: `UPDATE clips SET master_layer_track_id = ? WHERE id = ?`.

**Undo capture**: previous value.

**Signals**: `clip_changed(clip_id)`.

**Label**: `"Set angle to V2"` (using the track's display name).

**Contract test (CT-C9)**: Given a multicam clip with NULL layer override, when SetClipLayer to V2, `clips.master_layer_track_id = V2.id`; undo restores NULL.

---

### `ToggleClipChannel`

**Args**: `{ sequence_id, clip_id, channel_index }`. `sequence_id` is the clip's `owner_sequence_id` (rule 2.29).

**Pre**: clip exists and `clip.owner_sequence_id = sequence_id`; nested sequence has at least `channel_index + 1` audio channels.

**Mutation**:
- No `clip_channel_override` row for `(clip_id, channel_index)`: INSERT row with `enabled = NOT inherited_enabled`, `gain_db = inherited_gain_db`.
- Row exists: UPDATE `enabled` to its opposite.

**Undo capture**: the row's prior state (or absence).

**Label**: `"Disable channel 3"` / `"Enable channel 3"`.

**Contract test (CT-C10)**: Given a clip with no override on channel 2 and the master channel 2 enabled, when ToggleClipChannel(2), a row exists with `enabled=0`; undo deletes the row.

---

### `SetClipChannelGain`

**Args**: `{ sequence_id, clip_id, channel_index, gain_db }`. `sequence_id` is the clip's `owner_sequence_id` (rule 2.29).

**Mutation**: INSERT or UPDATE row with new `gain_db`.

**Undo capture**: prior `gain_db` (or row absence).

**Label**: `"Set channel 3 gain to -6 dB"`.

**Contract test (CT-C11)**: Gain change persists; undo restores prior state (including row-absence if override didn't exist).

---

### `ClearClipOverride`

**Args**: `{ sequence_id, clip_id, channel_index }` (or the `layer` variant; in either case `sequence_id` is the clip's `owner_sequence_id` per rule 2.29).

**Pre**: override row exists.

**Mutation**: DELETE the override row (or set `master_layer_track_id` back to NULL).

**Undo capture**: the deleted row's full state.

**Label**: `"Revert channel 3 to master default"`.

**Contract test (CT-C12)**: Clearing an override removes the row; subsequent playback reflects master channel state.

---

## New commands — master-level properties

### `SetMasterDefaultLayer`

**Args**: `{ sequence_id, track_id }`. `sequence_id` is the master sequence being mutated (rule 2.29).

**Pre**: `sequence_id.kind='master'`; `track_id` belongs to master's video tracks. Non-NULL only (INV-8 forbids NULL for masters with video).

**Mutation**: `UPDATE sequences SET default_video_layer_track_id = ? WHERE id = ?`.

**Undo capture**: prior value.

**Signals**: `sequence_content_changed(sequence_id)` — tracking clips (those with `master_layer_track_id=NULL`) re-resolve.

**Contract test (CT-C13)**: Changing master default from V1 to V2 changes what every non-overridden clip of the master plays. Clips with their own `master_layer_track_id` are unaffected.

---

### `SetMasterChannelState`

**Args**: `{ sequence_id, channel_index, enabled, gain_db }`. `sequence_id` is the master sequence being mutated; rows in `media_refs_channel_state` use it as `owner_sequence_id` (rule 2.29).

**Pre**: `sequence_id.kind='master'`; `channel_index` within the master's audio channel count.

**Mutation**: UPSERT `media_refs_channel_state` row with `owner_sequence_id = sequence_id`.

**Undo capture**: prior row (or absence).

**Label**: `"Disable channel 3 on master X"` / `"Set master channel 3 gain to -3 dB"`.

**Contract test (CT-C14)**: Setting master channel state propagates to all clips tracking that master; clips with their own `clip_channel_override` on that channel are unaffected.

---

### `SetSequenceStartTC`

**Args**: `{ sequence_id, medium ∈ {'video','audio'}, tc_value }`.

**Pre**: sequence exists.

**Mutation**: `UPDATE sequences SET video_start_tc_frame = ?` or `audio_start_tc_samples = ?`.

**Undo capture**: prior value.

**Label**: `"Set video TC to 01:00:00:00"`.

**Contract test (CT-C15)**: TC change propagates to all clips referencing this sequence (affects timeline-position translation).

---

### `SetFpsMismatchPolicy`

**Args**:
- Project scope: `{ scope='project', project_id, policy ∈ {'resample','passthrough'} }` (non-NULL — the project always has a concrete default). Affects future Insert/Overwrite into any sequence that doesn't override. Doesn't mutate existing clips.
- Sequence scope: `{ scope='sequence', sequence_id, policy ∈ {'resample','passthrough',NULL} }` (rule 2.29). NULL = inherit project. Affects future Insert/Overwrite into this sequence; existing clips are unaffected (policy is frozen on each clip at its Insert time).
- Clip scope: `{ scope='clip', sequence_id, clip_id, policy ∈ {'resample','passthrough'} }` where `sequence_id` is the clip's `owner_sequence_id` (rule 2.29). Clip-scope policy is NOT NULL (every clip carries an explicit policy); this command flips between the two values.

**Mutation**:
- Project / sequence scope: single UPDATE to the named row; no effect on existing `clips` rows.
- Clip scope: **structural** — re-compute `clips.duration_frames` under the new policy (per the Insert math: `resample` = `round(nested.duration × owner.fps / nested.fps)`, `passthrough` = `nested.duration`), UPDATE the row, and ripple downstream clips on the same track by the delta. Linked clips in the same `link_group_id` flip together and are rippled as a unit.

**Undo capture**: prior value.

**Contract test (CT-C16)**: Clip-scope `SetFpsMismatchPolicy` on a clip whose master fps differs from the timeline fps mutates `duration_frames` and ripples downstream clips on the track. Linked V+A clips flip and ripple together. Resolver output under each policy follows CT-R8; this test asserts the structural mutation side of the change.

---

## New commands — nest / unnest

### `Nest`

**Args**: `{ sequence_id, selected_clip_ids }`.

**Pre**: `sequence_id.kind='nested'`; all `selected_clip_ids` are in that sequence.

**Mutation**:
1. INSERT new `sequences` row S with `kind='nested'`, timebase/dimensions copied from the parent sequence.
2. For each clip in `selected_clip_ids`: UPDATE `owner_sequence_id = S` (and `track_id` mapped to S's equivalent new track; if necessary create tracks in S).
3. Compute the span covered by the selection on the parent; INSERT one new `clips` row into the parent at the earliest selected `timeline_start`, with `nested_sequence_id = S`, `source_in = 0`, `source_out = S.duration`, linking V+A via `clip_links` if both mediums present.

**Undo capture**: the new sequence S's id; the moved clips' prior `owner_sequence_id`/`track_id`; the new replacement clip's id.

**Signals**: `sequence_content_changed` on both the parent and S.

**Label**: `"Nest N clips"`.

**Contract test (CT-C17)**: Given 3 selected clips in a nested sequence, when Nest, a new `kind='nested'` sequence contains those 3 clips; the original parent has one new clip replacing them.

---

### `Unnest`

**Args**: `{ sequence_id, clip_id }`. `sequence_id` is the clip's `owner_sequence_id` — the parent sequence whose contents are mutated by the expansion (rule 2.29).

**Pre**: `clip_id` exists and `clip.owner_sequence_id = sequence_id`; `clip.nested_sequence_id.kind='nested'` (masters cannot be unnested — their tracks hold `media_refs` which can't live in a non-master).

**Mutation**:
1. For each clip in `clip_id.nested_sequence_id`: UPDATE `owner_sequence_id = clip.owner_sequence_id` (the parent); translate `timeline_start_frame` by `(clip.timeline_start_frame - clip.source_in_frame)`; map `track_id` to the parent's equivalent track.
2. DELETE `clip_id`.
3. If `clip_id.nested_sequence_id` is no longer referenced by any other clip: DELETE the sequence (orphan cleanup).

**Undo capture**: the deleted clip's full state; the moved clips' prior `owner_sequence_id`/`track_id`/`timeline_start_frame`; whether the nested sequence was orphan-deleted.

**Label**: `"Unnest"`.

**Contract test (CT-C18)**: Given a clip whose nested sequence contains 3 clips, when Unnest, the parent sequence has those 3 clips at translated positions; the unnested clip row is gone; the nested sequence is deleted if no longer referenced.

**Contract test (CT-C19 — refusal)**: Given a clip whose nested_sequence is `kind='master'`, when Unnest, the command refuses with a clear error.

---

## Invariants maintained by commands

- **INV-1** (`media_refs.owner_sequence_id` is a master): all commands that insert/move media_refs assert this before write.
- **INV-2** (`clips.owner_sequence_id` is non-master): Insert/Overwrite/Nest refuse when target is `kind='master'`.
- **INV-3** (no cycle): Insert, Overwrite, Duplicate, Nest run `would_create_cycle` before write.
- **INV-4** (window within nested seq's bounds): Slip/Trim/Roll clamp or refuse.
- **INV-6** (master's `default_video_layer_track_id` stays valid): track-delete commands on a master check and refuse if `default_video_layer_track_id` references the victim track without a replacement.
- **INV-8** (`default_video_layer_track_id` non-NULL when master has video): `ensure_master` sets it at creation; any command that adds the first video track sets it.

---

## Global signal contract

All mutating commands emit `sequence_content_changed(sequence_id)` on the sequence whose content mutated. Changes to a nested/master sequence also emit on THAT sequence, prompting tracking clips to re-resolve (via the existing `mutation_generation` mechanism). Override commands additionally emit `clip_changed(clip_id)` for finer-grained UI refresh.
