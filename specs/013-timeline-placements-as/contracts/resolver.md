# Contract: Clip Resolver

**Feature**: 013-timeline-placements-as — Phase 1 contract

The resolver is the single Lua-side function that walks the clip → nested sequence → (recurse) → media_ref → media chain for a given sequence and time range. It is the only code path both playback and export use (FR-019).

---

## Signature

```lua
---@param seq_id string               Sequence to resolve (any kind)
---@param start_frame integer         Inclusive start, in `seq_id`'s own timebase
---@param end_frame integer           Exclusive end, same timebase
---@param context ResolutionContext   Caller-scoped state (export mode, fps policy, cycle guard)
---@return ResolvedEntry[]
function Sequence:resolve_in_range(seq_id, start_frame, end_frame, context)
```

### `ResolutionContext`

```lua
{
    recursing_into: set[sequence_id],    -- cycle guard; mutated during recursion
    depth: integer,                      -- current nesting depth; for logging only
    export_mode: boolean,                -- false for preview, true for export; does NOT affect resolution
    project_fps_mismatch_policy: 'resample' | 'passthrough',  -- default for clips whose own policy is NULL
}
```

### `ResolvedEntry`

```lua
{
    media_path: string,                  -- Absolute filesystem path of the underlying media file
    media_id: string,                    -- For observability / relink diagnostics
    media_kind: 'video' | 'audio',
    source_in: integer,                  -- Start frame/sample in the media file's native units
    source_out: integer,                 -- End frame/sample, exclusive
    timeline_start: integer,             -- Start position in the OUTERMOST requested sequence's timebase
    duration: integer,                   -- timeline_end - timeline_start
    track_role: string,                  -- 'video' | 'audio'
    channel_index: integer | nil,        -- Audio only: 0-based into the outermost clip's referenced-seq channel list
    volume: number,                      -- Composite of all clip + media_ref volumes in the chain
    enabled: boolean,                    -- false iff any override or clip in the chain disabled this stream
    effects: table,                      -- Composite of all effects (empty in first landing)
    provenance: string[],                -- Chain from outermost clip → leaf media_ref, as row IDs
}
```

---

## Resolution algorithm

On entry to a sequence at a given range:

1. If `seq_id ∈ context.recursing_into`: loud assert with the provenance chain. (Mutation-time cycle check already rejected this, so arriving here means DB corruption or external mutation.)
2. Add `seq_id` to `context.recursing_into`.
3. Inspect `sequences[seq_id].kind`:

   - **`kind='master'`**: iterate `media_refs` where `owner_sequence_id = seq_id` and `[source_in, source_out]` overlaps the requested range. For each overlapping media_ref, clip to the requested range and emit one `ResolvedEntry` per row, following the `media_id → media` FK for `media_path` and applying the master's `media_refs_channel_state` for audio entries' `volume`/`enabled`.

   - **`kind='nested'`**: iterate `clips` where `owner_sequence_id = seq_id` and `[timeline_start, timeline_start + duration]` overlaps the requested range. For each overlapping clip, apply overrides (see below) then recursively resolve the clip's `nested_sequence_id` over the clip's clamped source window. Translate returned entries' `timeline_start` by `(clip.timeline_start - clip.source_in)` so they land in the outermost sequence's timebase.

4. Remove `seq_id` from `context.recursing_into`.

### Override application order during clip recursion

For each clip encountered while resolving a non-master sequence:

1. **Track selectors** applied first — symmetric for video and audio:
   - **Video**: if `clip.master_layer_track_id` is non-NULL, restrict the recursion into the nested sequence to that specific video track. If NULL, restrict to the nested sequence's `default_video_layer_track_id` (alternative-stack semantics — exactly one video track exposed per clip).
   - **Audio**: if `clip.master_audio_track_id` is non-NULL, restrict the recursion into the nested sequence to that specific audio track (expanded mode — exactly one audio track exposed per clip; FR-023/FR-024). If NULL, all of the nested sequence's audio tracks pass through (composite mode — all tracks composited; FR-005).
2. **Recurse** into `clip.nested_sequence_id` with the clamped range and the filtered track sets (one V track or none; one A track or all A tracks).
3. **Channel state** applied to the recursion's audio results — for each returned audio entry, look up `(clip.id, channel_index)` in `clip_channel_override`; if present, its `enabled/gain_db` override the inherited state from the nested sequence. In expanded mode the override applies to channels of the selected audio track only; in composite mode it applies across all returned channels (channel_index addresses the master's full channel layout in either mode).
4. **Gain composition** — clip's volume × inherited volume (from the nested sequence's resolution) × any media_ref volume at the leaf. Multiply through the chain.

Reversing this order (channel state before track selection) would apply channel mutes to tracks the selector would then discard — incorrect.

---

## Behavior guarantees

### G-R1: Deterministic

Given the same `(seq_id, start_frame, end_frame, context)` and the same DB state, the output is byte-identical across calls.

### G-R2: Cycle safety

The mutation-time check (INV-3) refuses cycles at write time. The resolver's `recursing_into` set is defense-in-depth; it asserts loudly (with full provenance) if it ever encounters a cycle.

### G-R3: Master-vs-nested dispatch

The resolver branches exactly once per level on `sequences.kind` — `'master'` reads `media_refs`, `'nested'` reads `clips`. Both branches emit the same `ResolvedEntry` shape; callers don't need to know which level they're inspecting.

### G-R4: fps-mismatch policy

When a clip's nested sequence has a different fps from the calling sequence, the resolver reads `clip.fps_mismatch_policy` (or `context.project_fps_mismatch_policy` if NULL). Output entries' `timeline_start` and `duration` reflect the chosen policy:

- `resample`: positions scaled by the fps ratio; consumer retimes at decode.
- `passthrough`: positions treat inner frames as if already at the outer sequence's fps — duplicates or drops frames at decode.

The resolver provides the information; the choice of retime vs pass-through is performed in the consumer (TMB / export pipeline), not the resolver.

### G-R5: Offline / missing nested sequence / broken override

If a clip's `nested_sequence_id` no longer exists, or its leaf media_refs point at media rows whose files are offline, the resolver emits synthetic `ResolvedEntry` rows with `media_path = nil`, `enabled = false`, and a `provenance` chain identifying the broken link. The renderer surfaces these via FR-022's loud-fail overlay.

If `clip.master_layer_track_id` points at a deleted track, the resolver asserts loudly with the clip id and the dangling track id. The FK `ON DELETE SET NULL` already NULL's this column when its referent is deleted through the ordinary command path, so arriving here with a live-but-dangling id means the DB has been corrupted or mutated outside the command layer — a fallback would silently paper over that (rule 2.13 / rule 1.14). NULL is the inherit signal and resolves to the referenced sequence's `default_video_layer_track_id`; that is inheritance, not a fallback.

The same rule applies to `clip.master_audio_track_id`: a live-but-dangling non-NULL value asserts loudly. NULL is the composite signal — explicitly "play all audio tracks" — and is the default state for audio clips that haven't been Expanded.

### G-R6: Export parity

When called with `context.export_mode=true`, the resolver's OUTPUT is identical to a `context.export_mode=false` call for the same `(seq_id, range, DB state)`. Export-only policies (proxy-vs-source media selection, colorspace, codec, resample filter quality) are applied in the pipeline ABOVE the resolver per FR-019, never inside it.

### G-R7: Clamping and range translation

Clips/media_refs straddling the requested range are clamped. Inner recursion's `timeline_start` is translated by `(clip.timeline_start - clip.source_in)` so that all outputs are in the outermost sequence's timebase.

---

## Contract tests (TDD gates)

Each of these is a failing Lua test written before the resolver implementation. Black-box: the test constructs a minimal sequence graph via the DB, calls `Sequence:resolve_in_range`, and asserts on output shape + values. No internal-function mocking.

### CT-R1: Master resolution (leaf)

Given a `kind='master'` sequence with one video and two audio media_refs, when resolving the full range, the resolver returns 3 entries (1 video + 2 audio), each with the correct `media_path` (from the media_ref's `media_id → media.file_path`), correct `source_in/out` in file-native units, and `provenance` chain of length 1 (the media_ref id).

### CT-R2: Nested resolution (one level)

Given a `kind='nested'` sequence containing one clip that references a `kind='master'` sequence, when resolving a range through the clip, the resolver returns entries whose `media_path` comes from the master's media_refs, with `provenance` chain of length 2 (clip id + media_ref id), and `timeline_start` translated through the clip's window.

### CT-R3: Deep nested resolution

Given a three-level chain (nested → nested → master), the resolver returns entries with `provenance` chain length 3. Depth recursion is transparent to the caller.

### CT-R4: Multicam layer override

Given a `kind='master'` multicam sequence with V1/V2/V3 (each a separate media_ref referencing a different file) and `default_video_layer_track_id = V1`, and a clip with `master_layer_track_id = V2`, when resolving, the returned video entry's `media_path` is V2's file, not V1's.

### CT-R5: Audio channel disable override

Given a synced master with 5 audio channels and a clip with `clip_channel_override(clip_id, channel_index=2, enabled=0, gain_db=0)`, when resolving, the entry for channel 2 has `enabled=false`; other channels have `enabled=true`.

### CT-R6: Channel gain composition

Given a clip with `clip_channel_override(channel_index=0, gain_db=-6)` and a master with `media_refs_channel_state(channel_index=0, default_gain_db=-3)`, when resolving, the entry for channel 0 has `volume` reflecting -6 dB (override wins).

### CT-R7: Cycle asserted at resolution time

Given a DB where (via direct SQL bypassing the model's cycle check) two non-master sequences reference each other through clips, when resolving across one, the resolver asserts with a message naming both sequence IDs and the provenance chain.

### CT-R8: fps-mismatch `resample` vs `passthrough` output

Given a 24fps master nested inside a 25fps non-master sequence, when resolving with `fps_mismatch_policy='resample'` vs `fps_mismatch_policy='passthrough'`, the entries differ by the 25/24 ratio in `resample` and are identical to the nested sequence's native frame counts in `passthrough`.

### CT-R9: Offline leaf yields broken entry

Given a clip whose nested sequence contains media_refs pointing at offline media, when resolving, the result contains synthetic entries with `media_path=nil`, `enabled=false`, and `provenance` identifying the chain.

### CT-R10: Export mode equals preview mode

Given any sequence, when resolving twice with the same args except `context.export_mode` flipped, the two outputs are byte-identical.

### CT-R11: Deterministic ordering

Given a sequence with multiple clips overlapping the same frame, the resolver returns the arrays in the same order on repeated calls.

---

## Non-goals (this contract)

- Keyframed automation: `media_refs_channel_state.default_gain_db` is static in first landing; keyframed curves are deferred.
- Effects composition: `effects` field returns `{}` in first landing.
- Caching: resolver is uncached in first landing. Cache policy is a separate performance concern.
