# Anamnesis "joe edit" DRP — TSO warnings/errors triage (2026-06-14)

Context: re-tested import + relink against `tests/fixtures/resolve/anamnesis joe edit.drp`
(43 MB, ~1549 media items, 331 synced camera clips). The big project surfaces
latent issues the small fixtures never hit. Each item below is root-caused with
evidence (probe output / file:line), then classified **FIXED**, **NEEDS-JOE**, or
**BENIGN/NOISE**.

---

## FIXED this session (with regression tests)

### E1 — Timeline crash opening a DRP while a timeline is displayed  ✅ FIXED
`timeline_tab.lua:49 TimelineTab:get_marks: sequence_id=… not found`

- **Root cause**: `database.init(new.jvp)` swaps the DB connection mid-`convert_to_jvp`;
  the import then pumps Qt events (`progress_panel.lua:94 PROCESS_EVENTS`) to drive the
  progress bar, which reentrantly repaints the timeline. The strip's displayed tab still
  pointed at the OUTGOING project's sequence → `Sequence.load` against the INCOMING DB
  returns nil → assert. Latent because only a project large enough to pump a paint
  mid-import (50 ms throttle) hits it.
- **Fix**: `timeline_state` now resets its tab strip on the existing `project_will_change`
  pre-swap signal (after flushing view-state), so a reentrant paint renders blank until
  `project_changed` repopulates it. `src/lua/ui/timeline/timeline_state.lua:1089`.
- **Test**: `tests/synthetic/lua/test_project_swap_detaches_timeline.lua` (reproduces the
  exact assert before the fix).
- **Spec**: updated `specs/014-two-phase-project/contracts/signal_will_change.md`
  (corrected emit site → `database.set_path`; documented the detach responsibility).

### W5 — FieldsBlob "wrapper byte 9 must be 0x81, got 0x80" (9×)  ✅ FIXED
- **Root cause (confirmed by probe, not guessed)**: byte 9 is a payload-variant tag.
  `0x81` = zstd-compressed Fields (the common case). `0x80` = a SHORT **uncompressed**
  Fields payload (~40-byte protobuf, no zstd magic) written by Resolve for **video-only
  media** (the 9 are all VFX renders). `qt_zstd_decompress` correctly fails on it; the
  payload carries **no MediaRef audio list** (`extract_media_refs` → 0 on the raw bytes,
  verified). So nothing was ever lost — the warning mischaracterized an expected variant.
- **Fix**: `decode_fields_blob_bytes` recognizes `0x80` as the uncompressed variant and
  returns its payload directly; only a genuinely unknown marker errors now.
  `src/lua/importers/drp_binary.lua:742`. Verified: **0** FieldsBlob warnings on the
  fixture after the fix; marker-blob + fields-blob binding tests still pass.
- **Test**: `tests/synthetic/lua/test_fieldsblob_uncompressed_variant.lua` (real captured
  0x80 bytes from the fixture).
- **Doc**: `docs/DRP_BLOB_FIELDS.md` could note the 0x80 uncompressed variant (the inline
  code comment is now authoritative).

---

## NEEDS-JOE — domain/product decision or your project to reproduce

### E2 — RelinkClips crash: `clip.lua:914 batch_update_source: rebind exec failed`  ⚠️ NEEDS-JOE
Failing clip `b6bfc1bb-e17e-4c08-9c6c-ecd22cc4d263` during a relink on the anamnesis project.

- **Two problems, separable**:
  1. **The assert swallows the real SQLite error.** Every `assert(stmt:exec(), "…")` in
     `batch_update_source` (clip.lua:894, 895, 907, 908, 914, 921) discards the second
     return value / `db:errmsg()`. Violates the project's "asserts must be actionable"
     rule — we currently can't see WHY the rebind aborted. **Recommended quick win**:
     capture `db:errmsg()` into the message. (Deferred only because I have no repro to
     TDD it against — see below — and didn't want to change 6 asserts blind.)
  2. **The likely underlying cause** (strong hypothesis, unconfirmed without your DB):
     the rebind `UPDATE clips SET sequence_id=?` fires trigger
     `trg_clips_subframe_bound_update` (schema.sql:739), which revalidates an AUDIO clip's
     `source_in/out_subframe` against the NEW master's `ticks_per_frame`
     (`master_clock_hz * fps_den / fps_num`). Relinking an audio clip to a media whose
     master has a **different fps** can make the existing subframe ≥ the new
     ticks_per_frame → `RAISE(ABORT)`.
- **Domain question for you**: when an audio clip is relinked to a different-fps source,
  what should happen to its sub-frame offset? (Preserve absolute tick offset and
  recompute the within-frame remainder under the new fps? Clamp? Reject the relink with a
  user-visible error?) This is a sub-frame-semantics decision I should not guess.
- **To reproduce**: I need the exact relink you performed (which clip → which target
  file). With the actionable-assert in place, the next attempt will print the real
  constraint. Tell me and I'll write a failing test + implement your chosen semantics.

### W3 — "CUSTOM-audio pmc '<X>.mov' not in media_items — synced_audio_pool_ids not stamped" (331×)  ⚠️ NEEDS-JOE
- **Root cause (CONFIRMED by probe, refutes the earlier UUID-mismatch theory)**: all 331
  warned video pmcs are **genuinely absent** from `media_items` — 0 match by id, 0 by
  `file_uuid`, 0 by path-contains-name. They are CUSTOM-audio (dual-system synced) camera
  clips living in media-pool **sub-bins, never placed on any timeline** and not in the
  root MpFolder. The importer only materializes media for timeline-used + root-pool items
  (`drp_importer.lua` passes 1/2/4 + UUID enrichment), so these never become media rows.
  Emit site: `drp_importer.lua:~2004` (`resolve_synced_audio_linkage`).
- **Severity**: currently **benign** — the clips aren't imported, aren't on any timeline,
  so there's nothing for the synced audio to attach to. BUT it's a symptom of a product
  gap (below).

### W4 — "apply_marks: no master sequence for media '<NNN-TNNN>.WAV'" (316×)  ⚠️ NEEDS-JOE
- **Root cause (confirmed)**: `Sequence.ensure_master` is only called inside the
  timeline-clip loop (`importer_core.lua:864`). These 316 are production-sound WAVs that
  ARE imported as media rows (they're in `media_items`) but are **not placed on any
  timeline**, so no master sequence is created → `find_master_for_media` returns nil →
  marks can't be applied. Emit site: `drp_importer.lua:~2667` (`apply_pool_master_clip_marks`).
- **Severity**: low. The dropped data is the PMC mark_in/out/playhead Resolve stored on
  the pool item. For unused pool media these are usually just a default playhead, not
  meaningful in/out marks — but I can't prove every one is trivial without inspecting.

### Unifying product decision behind W3 + W4
Both trace to one design choice: **the DRP importer materializes media (and master
sequences) only for media used on a timeline (+ root pool); pool-only / sub-bin media is
not fully materialized.** The open question is product-level:

> Should opening a Resolve project import the **entire media pool** (every bin, including
> clips not used in the edit) so the JVE media browser mirrors Resolve's pool — or only
> the media actually referenced by timelines?

- If **full-pool import** is desired: create media rows for all pool items and master
  sequences for them (incl. synced-audio Sync tracks for W3, mark application for W4).
  Larger projects, but a faithful mirror; lets you later cut unused clips into the edit.
- If **timeline-only** is the intended scope: W3/W4 are expected noise — downgrade both to
  `log.detail`/`event` (or summarize as one line: "N pool-only items skipped"), so the TSO
  isn't flooded with hundreds of WARNs for normal behavior.

I did not change importer scope or warning levels here — that's your call.

---

## BENIGN / NOISE — low priority (W6 bucket)

- **"Skipping zero-duration media: <X>" (~24×)** — Pass-4 phantom entries from the raw
  `<MediaFilePath>` grep that get filtered when they resolve to zero duration
  (`importer_core.lua:634`). Expected filtering of non-media/placeholder paths. Could be
  summarized to one line. **No action needed** unless you want quieter logs.
- **"Skipping sequence '…' - no fps in MediaPool metadata" (1×)** — one orphan/compound
  sequence with no fps in the pool metadata is skipped (`drp_importer.lua:2247`). Expected
  for compound clips / deleted timelines. **Benign.**
- **"pick_majority_audio_sample_rate: no audio media decoded; defaulting to 48000 Hz" (1×)**
  — `drp_importer.lua:2771`. The majority-vote over `timeline.media_files[*].audio_sample_rate`
  found **zero** decodeable rates, so it fell back to 48 k. The fallback is **deliberate and
  documented** (free Resolve only offers 44.1/48; 48 is the default; 96/192 projects would
  have decodeable blobs) with a standing **TODO: decode the Fairlight project FieldsBlob**
  for the authoritative project sample rate. ⚠️ Worth noting: that zero timeline media
  carried a decodeable audio rate on a project this size is itself suspicious — either the
  BtAudioInfo rate decode is failing broadly, or timeline media_files don't carry the rate.
  Real fix (Fairlight FieldsBlob decode) is a reverse-engineering task = NEEDS-JOE scope.
- **"refresh_last_sequence_number: DB MAX=5 > cached=0 (stale WAL or concurrent session)" (1×)**
  — `[commands]`. Benign; expected when another JVE session/WAL is around (you run parallel
  sessions). The message already self-diagnoses. **No action.**

---

## Summary
- **2 fixed** with TDD + spec sync: E1 (timeline crash), W5 (FieldsBlob 0x80).
- **2 confirmed-but-NEEDS-JOE**: W3 + W4 (one product decision: import full pool vs
  timeline-only).
- **1 NEEDS-JOE w/ repro**: E2 (relink crash — sub-frame semantics + I need your exact
  relink to reproduce; recommend making the asserts actionable first).
- **Rest benign noise**, optionally summarizable to reduce TSO flooding.
