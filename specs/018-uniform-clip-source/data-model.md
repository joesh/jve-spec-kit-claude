# Data Model: Uniform Clip Source Timebase with Canonical-Clock Sub-Frame Primitives

**Phase**: 1 — Design
**Status**: Complete
**Schema version**: V10 → **V11** (bump on landing)
**Spec**: [spec.md](spec.md)

This document describes every schema change, invariant trigger, and on-row value shape for 018. It is the authoritative reference for the implementation tasks and tests that follow. Schema text lives in `src/lua/schema.sql`; this document mirrors and explains it.

---

## Summary of changes (V10 → V11)

| Surface | Change |
|---|---|
| `schema_version` row | `10` → `11`. Hard-error open for V10 and earlier. |
| `clips.source_in_subframe` | **NEW** INTEGER, NULL for video clips, NOT NULL for audio clips. |
| `clips.source_out_subframe` | **NEW** INTEGER, NULL for video clips, NOT NULL for audio clips. |
| `sequences.audio_sample_rate` on kind='master' | CHECK constraint added: MUST be NULL when kind='master'. |
| `media_refs.audio_sample_rate` | **NEW** INTEGER, populated at media_ref insert from the underlying media file. NULL allowed for video-only media_refs. |
| `projects.settings` JSON | New keys `default_fps` (object `{num, den}`) and `master_clock_hz` (integer). |
| Triggers | **NEW**: INV-3 (subframe-presence by clip kind), INV-4 (subframe bound), INV-5 (sequence fps single-writer), INV-6 (projects.settings.master_clock_hz single-writer), INV-7 (sequences.audio_sample_rate NULL when kind='master'). |
| Triggers | **MODIFIED**: INV-2 stale `'nested'` error-message wording corrected to `'sequence'` (FR-018a, already landed in current branch as part of cleanup commit). |

---

## Column reference (full detail)

### `clips` (modified)

```sql
CREATE TABLE clips (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    owner_sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,
    track_id TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,

    -- Source position in the SOURCE sequence's fps timebase. Integer frames.
    source_in_frame  INTEGER NOT NULL,
    source_out_frame INTEGER NOT NULL,

    -- NEW in V11: Sub-frame residual, integer count of project master-clock
    -- ticks within the corresponding frame. Range: 0 .. (ticks_per_frame - 1).
    -- NULL for video clips (by track type); NOT NULL for audio clips.
    -- Enforced by INV-3 and INV-4 (see Triggers).
    source_in_subframe  INTEGER,
    source_out_subframe INTEGER,

    -- (existing columns unchanged)
    sequence_start_frame INTEGER NOT NULL,
    duration_frames INTEGER NOT NULL CHECK(duration_frames > 0),
    master_layer_track_id TEXT REFERENCES tracks(id) ON DELETE SET NULL,
    master_audio_track_id TEXT REFERENCES tracks(id) ON DELETE SET NULL,
    fps_mismatch_policy TEXT NOT NULL
        CHECK(fps_mismatch_policy IN ('resample','passthrough')),
    name TEXT NOT NULL,
    enabled INTEGER NOT NULL,
    volume REAL NOT NULL,
    mark_in_frame INTEGER,
    mark_out_frame INTEGER,
    playhead_frame INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    modified_at INTEGER NOT NULL
);
```

**Rationale for two columns (in + out) rather than a single sub-frame range:** every existing edit operation reads or writes `source_in_frame` and `source_out_frame` independently (slip changes both by the same delta; trim head changes only `source_in_frame`; trim tail changes only `source_out_frame`). The sub-frame mirror columns must be writable on the same independent schedule.

**Rationale for NULL on video clips, NOT NULL on audio clips:** FR-001 makes the schema structurally enforce the audio/video distinction. A video clip has no sub-frame concept (video is frame-quantized); the column simply does not exist as data on those rows. An audio clip has a sub-frame even when it is zero (zero is a legitimate value; the field's *existence* is what differentiates audio from video). A caller that tries `clip.source_in_subframe = 0` on a video clip violates INV-3; a caller that reads `clip.source_in_subframe` on a video clip and gets NULL (rather than 0) is a load-bearing signal — it should branch on clip type, not coerce NULL to zero.

### `media_refs` (modified)

```sql
-- ADD column (V10 → V11):
ALTER TABLE media_refs ADD COLUMN audio_sample_rate INTEGER;
```

`audio_sample_rate` is populated at media_ref insert time from the underlying media's audio sample rate (via `media.audio_sample_rate`). NULL is permitted for media_refs whose source media has no audio (video-only files).

**Rationale for denormalization (vs join through `media`):** the resolver (FR-008) reads this per audio-emit during decode resolution. Joining `media_refs → media` once per emit is workable but adds a SQL round-trip; storing on the media_ref row is a single fetch. Also gives us referential immutability: if a future "replace media" workflow re-points a media_ref at a new file, the audio rate on the existing media_ref row stays semantically correct for any clip already resolved against it; a separate command would update both. (No such workflow exists in 018, but the denormalization is forward-friendly.)

**Note**: per Joe's instruction, schema may be bumped freely (MEMORY: `feedback_schema_bump_freely`). The `ALTER TABLE ADD COLUMN` line above is illustrative — the actual schema.sql edit is a single `CREATE TABLE media_refs` change at the V11 baseline; old `.jvp` files hard-error at open and the user re-imports.

### `sequences` (modified — column constrained, not added)

```sql
-- Existing column:
audio_sample_rate INTEGER CHECK(audio_sample_rate IS NULL OR audio_sample_rate > 0),
-- NEW V11 trigger (INV-7): masters MUST have NULL audio_sample_rate.
```

**Rationale**: A master can hold media_refs at heterogeneous sample rates (a 48 kHz boom mic + a 96 kHz field recorder under one synced-sound master — Acceptance Scenario 2). No single master-level rate is correct. Regular sequences (`kind='sequence'`) retain the column as their **audio monitor rate** (what the playback engine mixes at when this sequence is rendered) — this is a playback concern, not a model-of-content concern, and is unaffected by 018. The constraint surface is asymmetric: masters MUST have NULL; regular sequences MUST have non-NULL (as today).

### `projects.settings` (JSON, new keys)

```json
{
  "default_fps": { "num": 24, "den": 1 },
  "master_clock_hz": 705600000,
  "fps_mismatch_policy": "resample"
}
```

| Key | Type | Range | When written |
|---|---|---|---|
| `default_fps.num` | integer | > 0 | At project creation (default 24). User changes via `SetProjectDefaultFps`. |
| `default_fps.den` | integer | > 0 | At project creation (default 1). User changes via `SetProjectDefaultFps`. |
| `master_clock_hz` | integer | > 0 | At project creation. **Canonically `705600000` (flicks) for every project; not user-settable.** Implementation deviation from draft — see spec.md "Implementation Deviations" §1. INV-6 still enforces "no direct UPDATE" (single-writer would be the never-built `SetProjectMasterClock` command). |

`fps_mismatch_policy` is the existing 015-era key; not changed by 018.

---

## Invariant triggers (new)

All triggers use `RAISE(ABORT, ...)` per Constitution VI fail-fast policy. Every error message names the invariant id, the violated column, and the offending value.

### INV-3 — Subframe-presence by clip kind (FR-001)

A row in `clips` must have NULL subframes iff its track is VIDEO; non-NULL subframes iff its track is AUDIO.

```sql
CREATE TRIGGER trg_clips_subframe_kind_insert
BEFORE INSERT ON clips
BEGIN
    SELECT CASE
        WHEN (SELECT track_type FROM tracks WHERE id = NEW.track_id) = 'VIDEO'
             AND (NEW.source_in_subframe IS NOT NULL OR NEW.source_out_subframe IS NOT NULL)
        THEN RAISE(ABORT, 'INV-3: video clip must have NULL subframes')
        WHEN (SELECT track_type FROM tracks WHERE id = NEW.track_id) = 'AUDIO'
             AND (NEW.source_in_subframe IS NULL OR NEW.source_out_subframe IS NULL)
        THEN RAISE(ABORT, 'INV-3: audio clip must have non-NULL subframes')
    END;
END;

CREATE TRIGGER trg_clips_subframe_kind_update
BEFORE UPDATE OF source_in_subframe, source_out_subframe, track_id ON clips
BEGIN
    -- same body as insert variant
END;
```

### INV-4 — Subframe bound (FR-002)

For audio clips: `0 ≤ subframe < ticks_per_frame`, where `ticks_per_frame = (project.master_clock_hz * source_seq.fps_den) / source_seq.fps_num`. Per Constitution V.21 we enforce at the schema layer:

```sql
CREATE TRIGGER trg_clips_subframe_bound_insert
BEFORE INSERT ON clips
WHEN NEW.source_in_subframe IS NOT NULL
BEGIN
    SELECT CASE
        WHEN NEW.source_in_subframe < 0
        THEN RAISE(ABORT, 'INV-4: source_in_subframe must be >= 0')
        WHEN NEW.source_in_subframe >= (
            (SELECT json_extract(p.settings, '$.master_clock_hz')
               FROM projects p WHERE p.id = NEW.project_id) *
            (SELECT s.fps_denominator FROM sequences s WHERE s.id = NEW.sequence_id) /
            (SELECT s.fps_numerator   FROM sequences s WHERE s.id = NEW.sequence_id)
        )
        THEN RAISE(ABORT, 'INV-4: source_in_subframe >= ticks_per_frame')
        WHEN NEW.source_out_subframe < 0
        THEN RAISE(ABORT, 'INV-4: source_out_subframe must be >= 0')
        WHEN NEW.source_out_subframe >= (
            (SELECT json_extract(p.settings, '$.master_clock_hz')
               FROM projects p WHERE p.id = NEW.project_id) *
            (SELECT s.fps_denominator FROM sequences s WHERE s.id = NEW.sequence_id) /
            (SELECT s.fps_numerator   FROM sequences s WHERE s.id = NEW.sequence_id)
        )
        THEN RAISE(ABORT, 'INV-4: source_out_subframe >= ticks_per_frame')
    END;
END;
```

The UPDATE variant is identical with `BEFORE UPDATE OF source_in_subframe, source_out_subframe, sequence_id`.

**Tick math note**: `ticks_per_frame` is integer for any `master_clock_hz` divisible by `fps_num/fps_den`. At default 192000 and 24/1, ticks = 8000. At 192000 and 23.976 (24000/1001), `192000 * 1001 / 24000 = 8008` exact. The SQL integer division `(M * den) / num` is exact for every divisor case; for non-divisor fps (rare — only true for unusual user-set values) the trigger's bound is the floor, which matches the math primitive's bound check (the math primitive computes the same expression).

### INV-5 — `sequences.fps_num/den` single-writer (FR-031)

```sql
CREATE TRIGGER trg_sequences_fps_guard
BEFORE UPDATE OF fps_numerator, fps_denominator ON sequences
WHEN NOT EXISTS (SELECT 1 FROM temp.sqlite_master
                  WHERE name = '_conform_sequence_in_progress')
BEGIN
    SELECT RAISE(ABORT,
        'INV-5: sequences.fps_num/den mutable only via ConformSequence');
END;
```

`ConformSequence` opens its transaction with:
```sql
CREATE TEMP TABLE _conform_sequence_in_progress (sequence_id TEXT);
INSERT INTO _conform_sequence_in_progress VALUES (?);
```
and drops the table just before commit. The trigger's `EXISTS` check is per-connection (temp tables are connection-local) and atomic with the transaction.

### INV-6 — `projects.settings.master_clock_hz` single-writer (FR-028)

Mirror of INV-5 for the master-clock setting. SQLite triggers can't easily inspect JSON-key changes, so we trigger on any UPDATE that touches `settings`:

```sql
CREATE TRIGGER trg_projects_master_clock_guard
BEFORE UPDATE OF settings ON projects
WHEN NOT EXISTS (SELECT 1 FROM temp.sqlite_master
                  WHERE name = '_set_master_clock_in_progress')
  AND json_extract(NEW.settings, '$.master_clock_hz')
       != json_extract(OLD.settings, '$.master_clock_hz')
BEGIN
    SELECT RAISE(ABORT,
        'INV-6: projects.settings.master_clock_hz mutable only via SetProjectMasterClock');
END;
```

`SetProjectMasterClock` sets the `_set_master_clock_in_progress` temp table for the duration of its transaction.

### INV-7 — Master `audio_sample_rate` must be NULL

```sql
CREATE TRIGGER trg_sequences_master_audio_rate_null_insert
BEFORE INSERT ON sequences
WHEN NEW.kind = 'master' AND NEW.audio_sample_rate IS NOT NULL
BEGIN
    SELECT RAISE(ABORT,
        'INV-7: sequences.audio_sample_rate must be NULL for kind=''master''');
END;

CREATE TRIGGER trg_sequences_master_audio_rate_null_update
BEFORE UPDATE OF kind, audio_sample_rate ON sequences
WHEN NEW.kind = 'master' AND NEW.audio_sample_rate IS NOT NULL
BEGIN
    SELECT RAISE(ABORT,
        'INV-7: sequences.audio_sample_rate must be NULL for kind=''master''');
END;
```

---

## (Frame, sub-frame) representation in detail

A clip's source position has two storage columns and one derived bound:

| Symbol | Storage | Domain |
|---|---|---|
| `frame` | `clips.source_in_frame` / `source_out_frame` | INTEGER, in **source sequence's** fps timebase. Range: project-wide; negative values legal for clips whose source sequence has a non-zero `start_timecode_frame`. |
| `subframe` | `clips.source_in_subframe` / `source_out_subframe` | INTEGER ticks at project `master_clock_hz`. Range: `0 ≤ subframe < ticks_per_frame`. NULL on video clips. |
| `ticks_per_frame` | derived | `master_clock_hz * source_seq.fps_den / source_seq.fps_num`. |

### Resolution to file-natural sample (FR-008)

The resolver, when emitting an audio entry for a clip, computes the file-natural sample offset as:

```
file_sample = media_ref.source_in            -- file-natural samples for media_ref's first sample
            + frames_to_samples(             -- whole-frame contribution
                clip.source_in_frame - media_ref.sequence_start_frame,
                media_ref.audio_sample_rate,
                source_seq.fps_num, source_seq.fps_den
              )
            + round(clip.source_in_subframe * media_ref.audio_sample_rate
                    / project.master_clock_hz)         -- subframe contribution
```

where `round` is round-half-away-from-zero (Clarifications session 2026-05-18; matches `round_int` in `models/sequence.lua:1995`).

For default `master_clock_hz = 192000` and any divisor `media_ref.audio_sample_rate`:
- 48000: `subframe * 48000 / 192000 = subframe / 4` — exact when subframe is a multiple of 4. The `round` resolves the residual ¼-tick.
- 96000: `subframe / 2` — exact when even.
- 192000: `subframe * 1` — exact always.

For 44100 (non-divisor): `subframe * 44100 / 192000 ≈ subframe * 0.2297`. Max round error: 0.5 sample. At 44.1 kHz that is 11.3 µs — well below human-perceptible drift and within the precision of any plausible editing operation.

---

## Schema version bump

```sql
INSERT OR IGNORE INTO schema_version (version) VALUES (11);
```

`Project.open(path)` reads `MAX(version)` from `schema_version` and asserts it equals 11. The assert message (per Research R5):

```
Schema version mismatch: this project file uses schema vN, this build expects v11.
The 018 sub-frame primitives feature changed how audio clip source positions
are stored; old projects cannot be opened. Re-import from the original source
(DRP / FCP7 XML / etc.) to produce a fresh .jvp file.
```

The assert surfaces through the existing QWidget error-dialog facility. No new UI work.

---

## Crash recovery (Clarification Q3)

`ConformSequence` and `SetProjectMasterClock` both:

1. Open a SQLite transaction.
2. Create their session-flag temp table (`_conform_sequence_in_progress` or `_set_master_clock_in_progress`).
3. Perform all UPDATEs.
4. Drop the temp table.
5. COMMIT.

If the process crashes between steps 1 and 5, SQLite's WAL atomicity rolls the transaction back on the next open. The temp table dies with the connection. The user observes the project in its pre-conform state — no banner, no marker, no prompt.

**Defense-in-depth**: if WAL rollback ever fails to fully restore (impossible by SQLite's guarantees, but FR-001/FR-002/FR-031 invariant triggers fire at the first touched row regardless). The invariant violation is a loud, actionable assert with row context.

---

## Files affected (summary; full source-tree list in plan.md)

- `src/lua/schema.sql` — column additions, trigger definitions, version bump.
- `src/lua/core/database.lua` — schema-version check assert message (R5).
- `src/lua/models/media_ref.lua` — populate `audio_sample_rate` at media_ref insert.
- `src/lua/models/clip.lua` — read/write subframe columns through `clip_position` (FR-009a).

Loading code (`database.load_clips`, etc.) must hydrate the new subframe columns into the in-memory clip table without re-introducing the legacy per-medium-unit ambiguity. The `clip_position` accessor (see `contracts/clip_position.md`) is the sole write API; loading code reads raw column values, but model-layer asserts on read mirror INV-3/INV-4 as a tripwire.

---

*Phase 1 data-model complete.*
