# Quickstart: 018 end-to-end acceptance recipe

**Phase**: 1 — Design
**Status**: Complete
**Spec ref**: Primary User Story (spec.md §"User Scenarios"), FR-025

This recipe demonstrates the Primary User Story end-to-end after 018 lands. The same recipe is automated by the FR-025 acceptance test (`tests/test_overwrite_acceptance_bit_identical.lua`). Run it manually to validate the user-facing bug is fixed; run the test to validate the fix stays fixed.

---

## Prerequisites

- A `.jvp` file with schema V11 (a brand-new project; old V10 files hard-error at open per Clarification Q2).
- A media file with:
  - Non-zero camera timecode origin (e.g. `15:49:39:08`) — exercises the resolver's TC math.
  - Both video and audio tracks (mixed-media master).
  - Audio sample rate that divides `master_clock_hz` (e.g. 48000 with default 192000) for exact bit-identical assertion. (Non-divisor rates produce ≤0.5 sample error; documented and bounded by FR-008.)

A suitable file: any modern camera `.mov` that ProRes-444 plus 48k stereo audio. The test uses an existing JVE test fixture from the `tests/fixtures/` tree.

---

## Recipe (manual, via the UI)

1. **Open project**.
   - New project initialized at default fps 24/1, `master_clock_hz = 192000`.
2. **Import media** via the DRP importer (or drag a single file into the browser, which constructs a single-media-ref master).
   - The importer creates one master sequence (kind='master') containing one or more media_refs from the imported file(s). Each media_ref's `audio_sample_rate` is populated from the file's native rate.
3. **Load the master into the source viewer** (double-click in the browser).
4. **Set marks** — pick an in-point and out-point. The test uses a range that does NOT begin on a frame boundary at the master's fps if the source file has a fractional TC offset; otherwise the in is frame-aligned.
5. **Switch focus to the timeline** (the record sequence).
6. **Press F10 (Overwrite)** to write the marked range onto the record sequence at the playhead.
7. **Park the playhead** somewhere INSIDE the new clip's range.
8. **Play**.

### Expected outcome (after 018)

- Video frame renders correctly.
- Audio is **audible**.
- The clip body shows a waveform.

### Failing outcome (the bug 018 fixes)

- Video renders, but the clip is silent (resolver requests file_sample = 0 instead of the TC-anchored offset, decoder returns silence).
- Waveform region is empty.

---

## Recipe (automated, `test_overwrite_acceptance_bit_identical.lua`)

```lua
-- Pseudocode (the real test uses the test_env harness + JVEEditor --test mode):

-- 1. Open a fresh V11 project.
local proj = test_env.create_project_v11(default_fps={num=24, den=1},
                                          master_clock_hz=192000)

-- 2. Import a test media file with TC origin = 15:49:39:08 and 48 kHz audio.
local media = test_env.import_drp_with_media("fixtures/sample_v_plus_a_tc_15h.drp")
local master = media.master_sequence  -- kind='master', mixed V+A

-- 3. Construct a record sequence (kind='sequence') and an Overwrite range.
local record_seq = Sequence.create(kind='sequence', fps={num=24, den=1})
local marks = { in_frame = 100, out_frame = 300 }  -- 200 frames at 24 fps = ~8.3 s

-- 4. Execute Overwrite from master[marks] onto record_seq at playhead=0.
cmd.execute("Overwrite", {
    source_sequence_id = master.id,
    target_sequence_id = record_seq.id,
    source_in_frame = marks.in_frame,
    source_out_frame = marks.out_frame,
    target_start_frame = 0,
})

-- 5. Locate the new audio clip on the record sequence.
local audio_clip = test_env.find_audio_clip_at(record_seq, target_start_frame=0)

-- 6. Resolve a frame inside the new clip and decode the audio entry.
local playhead = 50  -- frames into the new clip
local entries = Sequence.resolve(record_seq, playhead, playhead+1)
local audio_entries = filter(entries, e -> e.kind == 'audio')
assert(#audio_entries > 0, "FR-025a: resolver returned no audio entry")

-- 7. Decode the same sample range from the source file directly.
local file_path = audio_entries[1].file_path
local file_sample_start = audio_entries[1].source_in  -- file-natural samples
local file_sample_count = audio_entries[1].source_out - audio_entries[1].source_in
local direct_samples = audio_decoder.read_samples(
    file_path, file_sample_start, file_sample_count)

-- 8. Decode via the resolver path (the path the playback engine takes).
local resolver_samples = audio_decoder.read_resolved(audio_entries[1])

-- 9. ASSERT: bit-identical (FR-025c).
assert(byte_compare(direct_samples, resolver_samples),
       "FR-025c: resolver-decoded samples differ from direct file decode")

-- 10. ASSERT: peak-cache for the same range is non-empty (FR-025b).
local peaks = peak_cache.query(file_path, file_sample_start, file_sample_count)
assert(#peaks > 0, "FR-025b: peak cache returned empty range")
```

---

## Acceptance checklist (manual or automated)

- [ ] Project opens at schema V11 (V10 hard-errors with the spec'd message).
- [ ] Import succeeds; new master has populated `media_ref.audio_sample_rate` values.
- [ ] `sequences.audio_sample_rate` is NULL on master rows (INV-7).
- [ ] Overwrite produces an audio clip with non-NULL subframes (INV-3) — both may be zero, since marks are frame-aligned by today's UI, but the columns exist.
- [ ] Resolver returns a non-empty audio entry inside the new clip.
- [ ] Decoded audio is audible.
- [ ] Waveform renders against the clip body.
- [ ] Decoded sample bytes equal direct-file-read sample bytes (FR-025c).
- [ ] Peak-cache query returns non-empty data for the source range (FR-025b).

---

## Cross-cutting smokes (run after the primary recipe)

These exercise the broader 018 surface area. Each has its own automated test (referenced in plan.md's test table); the manual smoke is one user-visible action.

| Smoke | Action | Expected |
|---|---|---|
| **Order independence** (FR-033) | Import the same set of media into two distinct masters in opposite orders (master A: video then audio; master B: audio then video). Place a clip referencing each at the same range. Compare resolver output. | Bit-identical between A and B. |
| **Multi-rate audio in one master** (FR-034) | Construct a master with a 48k camera-audio media_ref AND a 96k field-recorder media_ref. Place a clip; verify both audio streams resolve and decode at their native rates. | Both audible; no resampling errors. |
| **ConformSequence** (FR-035) | Conform an existing 24/1 master to 23.976. Verify every dependent clip still resolves to the same wall-clock content. | Wall-clock equivalence within rounding bound. |
| **SetProjectDefaultFps** (FR-036a) | Run `SetProjectDefaultFps(30, 1)` on a project with existing 24/1 sequences. Verify nothing changes except the settings key. | Existing rows untouched; new sequence pre-fills 30/1. |
| **SetProjectMasterClock** (FR-036b) | Run `SetProjectMasterClock(48000)` on a project with non-zero subframes. Verify subframes rescale exactly and wall-clock is preserved. | Subframes scaled by 1/4 (within rounding); fps and frames untouched. |
| **Subframe preservation** (FR-023) | Build a synthetic clip with subframe = 100. Apply Slip by N frames. Verify subframe still = 100. Undo, redo, verify still 100. | Preserved exactly. |
| **Invariant trigger fires** (FR-024) | Direct SQL: `UPDATE clips SET source_in_subframe = -1 WHERE id = ...`. | Trigger raises INV-4 with actionable message. |

---

## Failure-mode walkthroughs (for support / debugging)

| Symptom | Likely 018-related cause | Diagnostic |
|---|---|---|
| Project won't open; error names schema mismatch | Old V10 file (Clarification Q2). | Re-import original source. |
| Audio clip silent after Overwrite | Subframe write skipped → resolver computes wrong file_sample. | Inspect clip row: `source_in_subframe` should be 0 (frame-aligned Overwrite) or a valid in-range integer. If NULL, INV-3 was bypassed somewhere — check the writer for a non-`clip_position` mutation. |
| Resolver returns garbage frame after ConformSequence | Outer-clip rewrite was skipped. | Inspect the outer clip's `source_in_frame` pre/post conform; rescale ratio should match `new_fps/old_fps`. Re-run with extra logging. |
| Two masters with same media produce different resolver output | INV-7 or fps drift on creation. | Diff `sequences` rows: `kind='master'` rows must have NULL `audio_sample_rate` (INV-7). `fps_num/den` must equal project default at creation. |

---

*Quickstart complete. Phase 1 design deliverables done. Proceed to `/tasks` to generate `tasks.md`.*
