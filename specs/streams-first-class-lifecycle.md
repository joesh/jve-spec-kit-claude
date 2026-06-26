# Streams as First-Class Data — Lifecycle & Model Note

**Status:** design note, pre-spec.
**Captured:** 2026-06-25 thread, branch `per-channel-audio` (Phase 4a follow-on).
**Authors:** Joe (design decisions), Claude (capture + opining where invited).
**Supersedes nothing yet.** Becomes the basis for a numbered spec once Joe assigns a number.

---

## 0. Why this note exists

During an adversarial review of Phase 4a (commit `f6920d4a` — per-channel
override identity `channel_index` → `master_track_id`), Claude confused
"channels visible in the master's Inspector" with "tracks inside the master
sequence" and produced two consecutive wrong reviews before Joe corrected
the framing:

> "jve's core unit of data is a stream. A file has a number of streams in
> them, but we treat each one as a separate stream regardless of what its
> file containment is. The guts of JVE should just deal with streams."

Half of the abstraction is already in code — the "one ref per stream"
invariant is structurally enforced at the write layer
(`src/lua/models/media_ref.lua:92-101`, `src/lua/schema.sql:271-277`) and
the importer commits to it (`src/lua/models/sequence/master_builder.lua:340,415`).
The other half — streams as first-class stored entities — is not.

This note captures the lifecycle decisions Joe made in the interview that
followed and the resulting model.

---

## 1. The model in one paragraph

A **stream** is JVE's atomic data unit: one channel of one file, identified
by `(media_id, source_channel)`. Streams carry **no mix state**. Mix state
(mute, gain, future keyframes) lives on the **master track/channel slot**
that holds the stream, with an **override layer** on a timeline clip that
exposes that slot. Re-importing a file binds to the existing streams (no
duplication); relinking a file preserves stream identity for the channels
that match across the path swap; channel-count changes on relink are
explicitly user-controlled.

---

## 2. Layer cake

```
   Timeline Clip Channel Override   ← per-(clip, master-track) override
                ↓ overrides
   Master Track / Channel Slot      ← default mix state per slot in the master
                ↓ holds
   Stream                            ← (media_id, source_channel), pure data identity
                ↓ resolves to
   File + File-Channel               ← what the decoder reads
```

- **Stream**: stored entity. Identity = `(media_id, source_channel)`.
  Carries an `online`/`offline` flag and any future per-stream metadata
  (probed channel label, normalization presets, etc.). Carries no mix state.
- **Master Track / Channel Slot**: stored as a `tracks` row in a master
  sequence (kind='master'). Holds exactly one stream (via the media_ref on
  that track). Carries the slot's *default* mix state (the row in
  `media_refs_channel_state` keyed by `master_track_id` — Phase 4a).
- **Timeline Clip Channel Override**: stored as a `clip_channel_override`
  row keyed by `(clip_id, master_track_id)`. Overrides the slot's default
  for that one timeline clip.
- **Resolver**: emits `(media_id, source_channel)` per played sample range
  — already what `src/lua/models/sequence/resolver.lua:402-485` does. No
  translation indirection required because the stream's PK IS those fields.

---

## 3. Lifecycle decisions (the four interview questions)

### (a) Identity stability across re-import
**Decision:** Streams are file-identity-shaped, so re-importing the same
file binds to the existing streams. The `file_path UNIQUE` constraint on
`media` (`src/lua/schema.sql:72`) already enforces "one media row per
physical file"; one-stream-per-(media, channel) extends that downward.

Same file imported twice into the same project produces:
- One `media` row (existing one — schema enforces this).
- One set of streams (existing ones — they're already there).
- One *new master sequence* (a duplicate master clip in the user's library)
  whose tracks point at the existing streams.

Joe's verbatim choice (Q3 in the interview): "Allow with a duplicate
master, sharing streams." This means the duplicate master IS a distinct
entity in the project's bin/library, with its own per-slot mix-state
defaults — but the underlying streams are not duplicated.

Cross-project re-import is out of scope for this note — projects are
self-contained `.jvp` files; re-importing into project B mints fresh
streams because B has no knowledge of A.

### (b) Stream survival when the file goes offline
**Decision:** Streams persist with state preserved, but visually flagged
offline. Joe's verbatim choice: "Persist but flagged offline."

Rationale: mix state and slot bindings live UP the cake (on master tracks
and clip overrides). Tearing down streams when a file goes offline would
either (i) cascade-destroy all the upstream state, or (ii) leave dangling
references. The persist-with-flag policy keeps the upstream state intact
and gives relink a clear target.

Open question (downstream of this note): does the offline flag live on the
stream row, or is "offline" computed lazily from the file's filesystem
presence? Recommend stored — explicit makes the state queryable for
relink dialogs and the project browser.

### (c) Channel-count change on relink
**Decision:** User-controlled, with a sane default. Joe's verbatim:

> "The user gets to choose relinking parameters. By default, we should
> require at least as many channels as the file previously had. But we
> should let the user relax that constraint and leave unmatched streams
> offline."

Operationalized:

- **Same channel count:** straight rebind. Each existing stream's
  `media_id` stays the same (the media row's `file_path` changes, but
  `media.id` is stable per `src/lua/schema.sql:73-76`). No stream-side
  identity change.
- **MORE channels on the new file:** auto-add the surplus streams to the
  master sequence that triggered the relink, as new audio tracks at the
  bottom of the audio stack. Joe's verbatim choice (Q2 follow-up):
  "Auto-add to the master that triggered the relink." The new tracks
  carry default mix state (enabled, gain=0).
- **FEWER channels on the new file:** by default the relink is *refused*
  if `new.audio_channels < original.audio_channels`. The user can relax
  this in the relink dialog; relaxed mode marks the affected streams
  offline-with-state-preserved (per decision (b)).

The relink layer today (`src/lua/core/media_relinker.lua` 1933 LOC,
`src/lua/core/relink_planner.lua` 491 LOC, `src/lua/core/commands/relink_clips.lua` 409 LOC)
has **zero per-channel awareness** — `media_relinker.lua` contains zero
mentions of "channel" case-insensitive. Adopting this decision requires
teaching the relink dialog about the channel-count diff and adding the
strict-by-default refusal + relaxation path. This is the biggest concrete
work item from this note.

[unverified] There may be a latent bug today where a relink with FEWER
channels silently leaves `source_channel` values on media_refs that exceed
the new file's `audio_channels`. Not chased; flagged for triage when the
streams refactor lands.

### (d) State scope: per-stream-global vs per-master
**Decision:** State is **per master clip**. Joe's verbatim: "Per master
clip only."

This is consistent with Phase 4a as committed: the per-slot defaults live
in `media_refs_channel_state` keyed by `master_track_id`, and the per-clip
overrides live in `clip_channel_override` keyed by `(clip_id, master_track_id)`.
Both tables remain correct under the streams model — they key off the
*slot*, not the stream. The stream is upstream of the state and carries
none of it.

This decision is the single most consequential one in this note for the
Phase 4a re-key conversation: **Phase 4a's master_track_id keying is the
right key.** The stream doesn't replace it; it lives below it.

---

## 4. What IS a stream as a stored entity?

Claude's opinion (Joe deferred with "opine"): **option (3) — stored streams
table with composite PK `(media_id, source_channel)`.**

Reasoning:
- Decision (b) requires at least one per-stream stored field (the offline
  flag). That alone requires a row.
- `media.id` is already stable across `file_path` changes
  (`src/lua/schema.sql:73-76`). A separate UUID PK would add an
  indirection without buying any stability `media.id` doesn't already
  provide.
- Composite PK makes the "one stream per (file, channel)" invariant
  structural — UNIQUE on PK enforces it at the schema layer.
- The resolver already emits `(media_id, source_channel)` to feed the
  decoder (`src/lua/models/sequence/resolver.lua:484`). A composite-PK
  streams table means no translation layer at the resolver/EMP/TMB seam —
  the keys travel through unchanged.
- Importer + relink + duplicate-master all already think in
  `(media_id, source_channel)` (`src/lua/models/sequence/master_builder.lua:340,415`,
  `src/lua/core/commands/duplicate_master_clip.lua:174`,
  `src/lua/core/commands/grow_master_medium.lua:163`).

**Proposed schema:**

```sql
CREATE TABLE IF NOT EXISTS streams (
    media_id        TEXT    NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    source_channel  INTEGER NOT NULL CHECK(source_channel >= 0),
    online          INTEGER NOT NULL CHECK(online IN (0, 1)),
    -- Future fields hang here:
    --   probed_label TEXT     (iXML / file-derived default name)
    --   metadata     TEXT     (JSON; per-stream normalization, etc.)
    created_at      INTEGER NOT NULL,
    modified_at     INTEGER NOT NULL,
    PRIMARY KEY (media_id, source_channel)
);
CREATE INDEX IF NOT EXISTS idx_streams_media ON streams(media_id);
```

**Implications for existing tables:**
- `media_refs` keeps `(media_id, source_channel)` as today; those columns
  now also act as the FK to `streams`. Add a composite FK
  `(media_id, source_channel) REFERENCES streams(media_id, source_channel)`.
- `media_refs_channel_state` keyed by `master_track_id` — **unchanged**
  (decision (d)).
- `clip_channel_override` keyed by `(clip_id, master_track_id)` —
  **unchanged** (decision (d)).
- Importer / `grow_master_medium` / `duplicate_master_clip` materialize
  the corresponding stream row (or look it up) before creating the
  media_ref. Trivial.

---

## 5. Phase 4a status under this model

Phase 4a's per-channel state keying by `master_track_id` is **correct and
preserved** under decision (d). The stream is *below* the slot in the cake;
the slot is where state lives.

The only Phase 4a artifact that now reads as a minor confusion is the
inspectable's field name `channel_index` (`src/lua/inspectable/master_clip.lua:204`)
— it's the master's slot ordinal, not a file-channel index. Rename to
`slot_index` or `display_index` before Phase 3 wires through the edit
commands; cheap surgical change.

No Phase 4a code needs to be rewritten under this model. Phase 4b
(reorder master channels) proceeds unchanged.

---

## 6. What CHANGES under this model (scope)

| Surface | Change | Approx LOC |
|---|---|---|
| `src/lua/schema.sql` | Add `streams` table | ~30 |
| `src/lua/models/stream.lua` (new) | CRUD + offline toggle + find by (media_id, ch) | ~150 |
| `src/lua/models/media_ref.lua` | Look up / require stream row on insert | ~30 |
| `src/lua/models/sequence/master_builder.lua:322-425` | Materialize stream row alongside media_ref | ~30 |
| `src/lua/core/commands/duplicate_master_clip.lua:174` | Same | ~10 |
| `src/lua/core/commands/grow_master_medium.lua:163` | Same | ~10 |
| `src/lua/importers/importer_core.lua` | Stream materialization at media-insert | ~40 |
| 6 specific importers | Likely no change if `importer_core` is the seam | ~0-20 |
| **Relink (the hard part)** | Channel-count diff in dialog + strict-by-default refusal + relaxed offline-mark path | **~200-400** |
| Resolver | No change (composite PK travels through) | 0 |
| Inspector | Field rename `channel_index` → `slot_index` | ~10 |
| Phase 4a tables | No change (decision (d)) | 0 |
| Tests | Stream materialization + offline-flag + relink-channel-count | ~300-400 |
| Specs | This note + numbered spec | n/a |

**Total: ~12-15 source files, ~6-8 test files, ~750-1100 LOC.**

This is **smaller than** my prior (B) scope estimate (~1200-1700 LOC),
because the per-(stream,master) state stays put — no re-keying of
`media_refs_channel_state` or `clip_channel_override`, no re-touching the
8 Phase 4a command/model files, no test re-surgery on the 18 Phase 4a
tests. The streams refactor is purely additive at the entity layer; the
existing slot-keyed state is left alone.

The relink chapter remains the single biggest concentration of work and
the only place real design effort is needed. The lifecycle decisions (a)-(c)
constrain it tightly; (d) is irrelevant to it.

---

## 7. What stays the same below the JVE/EMP seam

EMP and TMB read at `(media_id, source_channel)` granularity today:
- EMP wraps `AVStream*` (`src/editor_media_platform/src/emp_reader.cpp:60,80,343-354,474-482`)
- TMB / playback feed source_channel through the resolved-entry
  (`src/lua/core/playback/tmb_clip_builder.lua:80`)
- SSE / AOP consume mixed PCM at the output bus and have no per-input-stream
  identity (`src/audio_output_platform/aop.h:12,19,78`,
  `src/scrub_stretch_engine/sse.h:28,112`).

The streams refactor adds NOTHING to this seam. JVE continues to hand the
decoder `(media_id, source_channel)`; the streams table is invisible below
the resolver.

---

## 8. Open questions deferred from this note

1. **Where does the offline flag live exactly?** This note recommends a
   column on the `streams` row, set/cleared by the relink path. Confirm
   when the relink chapter is designed.

2. **Probed channel labels (iXML, BWF, etc.).** Today they're looked up
   per-call (`src/lua/inspectable/master_clip.lua:186` via
   `channel_names.get(...)`). Under the streams model, caching them as a
   stored column on the stream row would be cleaner. Optional follow-on.

3. **Cross-project stream identity.** Out of scope for this note; projects
   are self-contained `.jvp` files. If multi-project workflows ever
   become relevant, revisit.

4. **The latent fewer-channels-on-relink bug.** [unverified] Not chased
   in this session; if a relink today produces a file with fewer channels
   than the original, do any existing media_refs end up with a
   `source_channel` exceeding the new `audio_channels`? Triage when the
   relink chapter lands.

5. **Naming the numbered spec.** When this note becomes a real spec, the
   number lives next to it (probably `specs/0NN-streams-first-class/`).

---

## 9. Recommended sequencing

1. **Now:** finish Phase 4b (reorder master channels) under the current
   model. Reorder is `tracks.track_index UPDATE` — works the same under
   either model.
2. **After 4b lands:** assign this note a spec number, formalize as
   `specs/0NN-streams-first-class/`. Expand section 6's scope into
   plan.md + tasks.md.
3. **Streams refactor execution:** purely additive at the entity layer
   (no re-keying of existing state), with the relink chapter as the only
   real design effort. Estimated 1× Phase 4a's scope by LOC, with the
   bulk of risk concentrated in relink.
