# Quickstart: Timeline Placements as Nested Sequence References

**Feature**: 013-timeline-placements-as — Phase 1 output
**Prereq**: Implementation complete (tasks.md executed), `make -j4` green, `tests/run_lua_tests_all.sh` green, `tests/run_integration_tests.sh` green.

This quickstart is the human-verifiable end-to-end validation of the 11 Acceptance Scenarios in `spec.md`. Each scenario maps to one or more automated integration tests (in `tests/integration/`); this doc describes how to reproduce each manually for smoke-level confidence before shipping.

## Vocabulary reminder

- **Master sequence** — a sequence (`sequences.kind='master'`) that contains files (`media_refs` rows). Created by import.
- **Sequence** — a non-master sequence (`sequences.kind='nested'`) that contains clips. The user's edit timelines and any composed sequences.
- **Clip** — a row in `clips`. The thing the user drags around. Every clip references another sequence via `nested_sequence_id`.
- **Nested sequence** — any sequence (master or non-master) while currently being placed inside another sequence. Usage-term, not a kind.
- **File** — user-visible term for a `media_refs` row when looking inside a master.
- **Nest / Unnest** — wrap a selection into a new sequence / expand a clip's contents inline.

## Setup

```bash
cd /Users/joe/Local/jve-spec-kit-claude
make -j4                         # luacheck + Lua tests + C++ compile
./tests/run_integration_tests.sh # integration suite
```

Launch `./build/bin/JVEEditor`. Create a new empty project.

---

## Scenario 1 — Single-file A/V drop

**Source**: a `.mov` with embedded audio (e.g. `tests/fixtures/media/A005_C052_0925BL_001.mp4`).

**Steps**:
1. File → Import, or drag the file into the project browser.
2. Observe: the file appears as a **master sequence** in the browser. The UI label reads "master sequence" (not "clip" or "master clip") per FR-021.
3. Drag the master from the browser onto your edit timeline at frame 0.
4. Observe: two **clips** appear on the timeline — one on V1, one on A1 (linked).
5. Click Play.

**Expected**: Video plays; audio plays. Clips are linked (moving or trimming one moves/trims the other).

**Maps to**: Acceptance Scenarios 1, FR-001/002/003/012.

**DB check**: the master is a `sequences` row with `kind='master'`; its internal contents are `media_refs` rows (not `clips`). The edit-timeline rows are `clips` with `nested_sequence_id` pointing at the master.

---

## Scenario 2 — Resolve synced clip (video + external WAV)

**Source**: `tests/fixtures/resolve/synced clip example.drp`.

**Steps**:
1. File → Import → Resolve Project → choose the DRP.
2. Wait for import.
3. Observe: each synced Sm2MpVideoClip in the DRP produced one **master sequence** whose internal contents are V1 (media_ref → the .mov's video file) + N audio media_refs (→ the external WAV's channels). The Sm2MpAudioClip from the DRP is not a separate top-level master; its channels are media_refs inside the synced master.
4. Drop the synced master onto your edit timeline. Two linked clips appear.
5. Play.

**Expected**: Video from the .mov. Audio from the WAV (not scratch). Opening the A clip's inspector shows the N audio channels.

**Maps to**: Acceptance Scenario 2, 9, FR-011.

---

## Scenario 3 — Multicam: change exposed angle

**Source**: a manually constructed multicam master. Inside a new master sequence, create 3 video tracks; drop a different media file onto each (V1=angleA.mov, V2=angleB.mov, V3=angleC.mov). All three become media_refs inside the master.

**Steps**:
1. Drop the multicam master onto the edit timeline.
2. Observe: the video clip plays V1 by default (`master_layer_track_id=NULL`, inherits `sequences.default_video_layer_track_id=V1`).
3. Select the video clip. Inspector → Exposed video layer → change to V2.
4. Play.

**Expected**: Video decodes from angleB.mov (V2). Other clips of the same master still play V1 (their overrides weren't touched).

**Maps to**: Acceptance Scenario 3, 10, FR-004/013.

---

## Scenario 4 — Disable audio channel on a clip

**Source**: any synced clip on the timeline with ≥3 audio channels.

**Steps**:
1. Select the audio clip.
2. Inspector → Channel state → toggle channel 3 off.
3. Play.

**Expected**: Channel 3 silent in the mix for this clip. Other clips of the same master continue to play channel 3.

**DB check**: a row appears in `clip_channel_override` with `(clip_id=..., channel_index=2, enabled=0)`. Undo removes the row; playback reflects inherited state again.

**Maps to**: Acceptance Scenario 4, FR-005/014.

---

## Scenario 5 — Trim a clip; master unchanged

**Steps**:
1. Drag the left edge of the video clip to trim 10 frames.
2. Play.

**Expected**: Clip starts 10 frames later into the referenced master's content. No other clip of the same master is affected. Inside the master, `media_refs` rows are unchanged.

**Maps to**: Acceptance Scenario 5, FR-009.

---

## Scenario 6 — Master content change propagates

**Setup**: at least 3 clips referencing the same master.

**Steps**:
1. Open the master (double-click in browser).
2. Inside the master, trim one of its media_refs by 5 frames.
3. Close the master. Play each clip.

**Expected**: All 3 clips reflect the trim (their playback windows clip at the new content boundary).

**Maps to**: Acceptance Scenario 6, FR-008.

---

## Scenario 7 — Video-only master later gains audio

**Steps**:
1. Import a video-only file. Place it on the timeline 3 times. Each clip is V-only.
2. Open the master. Add an audio track to the master and drop an audio file in it (creating a new media_ref on the new audio track).
3. Close the master.
4. Observe the existing 3 clips.

**Expected** (per the "clips track master" default, FR-007): each existing clip now has an A entry linked to its V entry. Playback includes the newly-added audio.

**Maps to**: Acceptance Scenario 7, FR-007.

---

## Scenario 8 — Ripple-delete preserves link group

**Steps**:
1. Place three clips A/B/C in sequence (each V+A linked).
2. Select B's video clip. Ripple-delete.

**Expected**: Both B's V and A removed (link group moves together). C shifts upstream by B's duration. C's own link group intact.

**Maps to**: Acceptance Scenario 8, FR-003/009.

---

## Scenario 9 — All importers emit clips, not flat rows

For each of DRP, FCP7 XML, Premiere .prproj:

**Steps**:
1. Import. After completion:
2. Inspect: `sqlite3 "$PROJECT.jvp" "SELECT id, nested_sequence_id FROM clips WHERE owner_sequence_id = <edit_seq_id>;"`
3. And: `sqlite3 "$PROJECT.jvp" "SELECT id, media_id FROM media_refs WHERE owner_sequence_id = <master_seq_id>;"`

**Expected**:
- `clips` rows on edit timelines all have non-NULL `nested_sequence_id` (they reference sequences, not files directly).
- `media_refs` rows exist inside masters with non-NULL `media_id`.
- No `clips` row holds a direct `media_id` (that column doesn't exist on `clips` anymore).

**Maps to**: Acceptance Scenario 9, FR-011.

---

## Scenario 10 — Master default layer

**Setup**: a multicam master with `sequences.default_video_layer_track_id = V2`.

**Steps**:
1. Drop the master on the edit timeline. Observe: clip plays V2 by default.
2. Inspector on the master → change default layer to V3.
3. Drop the master again. New clip plays V3.

**Expected**: existing clips without their own layer override reflect master changes; clips with overrides stay on their overrides. FR-007 + FR-004.

---

## Scenario 11 — Master-level channel state propagates

**Setup**: a master with 5 audio channels; a clip of it on the timeline with no channel overrides.

**Steps**:
1. Open the master. Inspector → set master channel 3's default gain to -6 dB (a row appears in `media_refs_channel_state`).
2. Close the master. Play the clip.

**Expected**: Channel 3 plays at -6 dB.

**Maps to**: Acceptance Scenario 11, FR-006.

---

## Scenario Extra A — Nest / Unnest

**Steps**:
1. Select 3 adjacent clips on the edit timeline.
2. Command → Nest. Observe: a new `kind='nested'` sequence appears in the browser; the 3 clips vanish from the edit timeline and are replaced by one clip referencing the new sequence.
3. Select the new clip. Command → Unnest.

**Expected**: The 3 original clips reappear at their original positions. The nested sequence is deleted (orphan cleanup). Try Unnest on a clip whose `nested_sequence_id.kind='master'` — it refuses with a clear error (masters contain media_refs, which can't live on a non-master's track).

---

## Export parity check (FR-019)

**Steps**:
1. Preview-play a timeline range.
2. Export the same range. Play the export.

**Expected**: Same files, same windows, same channel states — bit-identical within codec tolerance. If preview shows V2 and mutes channel 3, export shows V2 and mutes channel 3.

---

## Cycle refusal (FR-010)

**Steps**: try to create a `clips` row where the candidate `nested_sequence_id` would eventually reference its own `owner_sequence_id` (directly — drag a sequence onto itself; or transitively — drag seq A onto seq B, then try to drag B onto A).

**Expected**: Editor refuses with a user-visible error. No DB mutation.

---

## Offline loud-fail (FR-022)

**Steps**: delete the file behind a clip's chain on disk; observe the clip on the timeline.

**Expected**: Clip shows the offline overlay. Toggle "suppress loud indicators" preference — the overlay hides but log entries still fire.

---

## Pass criteria

All 11 scenarios + Nest/Unnest + export parity + cycle + offline as described. Any scenario failure has a corresponding integration test failure; triage there first.
