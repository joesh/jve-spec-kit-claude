# Data Model: Gap-as-Clip Refactor

## Entities

### Gap Clip (in-memory only)

A gap clip uses the same field interface as a media clip. The clip manipulation pipeline does not distinguish them (FR-001a).

| Field | Type | Value for gaps | Notes |
|-------|------|---------------|-------|
| id | string | `"gap_<track_id>_<start>"` | Synthetic, recomputed on change |
| track_id | string | Same as adjacent clips | Required |
| timeline_start | integer | Computed from neighbor clips | Frames |
| duration | integer | Computed from neighbor clips | ≥ 0 |
| clip_kind | string | `"gap"` | Distinguishes from media clips |
| media_id | nil | — | No media |
| source_in | nil | — | No source |
| source_out | nil | — | No source |
| fps_numerator | integer | From sequence | For frame math |
| fps_denominator | integer | From sequence | For frame math |
| enabled | integer | 1 | Always enabled |

### Gap Lifecycle States

```
Sequence Open
    → compute_gaps_for_track() for each track
    → gaps inserted into track clip list

Clip Edit (insert/delete/trim/roll/ripple)
    → update_gaps_after_edit() on affected track(s)
    → local: only changed_region and immediate neighbors

Gap Events:
    CREATE: empty space appears between clips (or before first / after last)
    RESIZE: adjacent clip moved, gap grows or shrinks
    SPLIT:  clip inserted in middle of gap → two gaps
    MERGE:  clip deleted, two gaps become one
    DELETE: gap trimmed to zero duration

Sequence Close
    → discard all gap clips
```

### Invariants

1. Between any two adjacent media clips on the same track, exactly one gap exists (duration ≥ 0)
2. Before the first media clip: one gap from position 0 (if first clip doesn't start at 0)
3. After the last media clip: one gap to sequence end (if applicable)
4. No two gaps are ever adjacent (merge invariant)
5. `gap.timeline_start + gap.duration` = next media clip's `timeline_start`
6. Previous media clip's `timeline_start + duration` = `gap.timeline_start`

### Relationship to Existing Entities

- **Track**: owns an ordered list of clips (media + gap interleaved)
- **Sequence**: owns tracks. Gap computation triggered on sequence open.
- **Command**: modifies media clips. Gap lifecycle reacts to clip changes.
- **Edge**: `in`/`out` on any clip (gap or media). No `gap_before`/`gap_after`.
- **Mutation**: gap changes do NOT produce DB mutations (gaps not persisted). Preview rendering uses the in-memory gap positions directly.
