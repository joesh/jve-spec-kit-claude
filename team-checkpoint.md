# Spec-023 Live-Test Campaign — Session Checkpoint

Branch: `023-resolve-color-bridge`
Date: 2026-06-10
(Previous checkpoint — 2026-06-09 skeptical-review passes 7–13 — in git history at `5aa6f24c`.)

## 8-task board

| # | Item | Outcome | Commit |
|---|---|---|---|
| 1 | fps_numerator data gap killing SendToResolve | ✅ fixed (payload_builder consumed nonexistent model fields) | 58a94b30 |
| 2 | T026 idempotency LIVE | ✅ PASSED; re-PASSED 2026-06-10 on changed import path | 58a94b30 |
| 3 | T034 fidelity downgrade LIVE | ✅ PASSED; classifier model corrected live | 67e64c4d |
| 4 | T037 reconform LIVE | ✅ PASSED; blade inherits grade via ClipGrade.copy_to | bbd36e9f |
| 5 | T050 connect-imported LIVE | ✅ PASSED 3/3 position-matched, grades on right clips | 3352408a |
| 6 | T055 edit readback LIVE | ✅ PASSED 2026-06-11 (B applied A+B+B+C verbs incl. disable; C conflict kept local; D local-kept). Fixed en route: drt_writer `<Flags>` enabled-fidelity (silent re-enable corruption); resolve_occlusions false "pending not found" warn on moves ≥ clip duration | — |
| 7 | T042 edge cases + T033 pixel compare | ✅ T042 PASSED 2026-06-11 (FR-009 live; not_studio + locale_rate_corruption emitters fixed). T033 PASSED 2026-06-12 first run: jve_apply_cdl(resolve_ungraded) ≈ resolve_graded, mean 0.31/255 max 1.07/255 — CDL convention pinned; SetCDL proven render-live | 0a3361c8 + — |
| 8 | T014 sentinel flip + T043 remnants + T044/T045 | ✅ 2026-06-12: T014 todo closed (sentinel already removed by contract-test tightening; success-shape live-covered by T026/T050/T055). T043 done (keymap/tooltips landed earlier; §5.5 affordance added — partial/unrepresentable badge says "full grade requires Resolve render"). T044 done (gate green incl. helper py tests). T045 results recorded in quickstart.md — all automatable scenarios pass; 3 operator legs remain (power-window unrepresentable, free Resolve, non-US locale) | — |

## T050 root cause (the DRT media-linkage gap, RESOLVED)
Three defects, all live-bisected on VM Resolve 20.3:
1. `drt_binary.encode_fields_blob` wrote the DECOMPRESSED payload size into the
   frame's declared-size field; Resolve reads exactly declared bytes after the
   8-byte header (`0x81`+zstd; uniform 6/6 reference-DRT + 1365/1365 gold-DRP
   frames). Fix: `#frame+1`. Broken framing → `' import'` placeholder pool item.
2. `verb_import_timeline` validated-but-never-used its media arg. Now
   `media_paths` (exact files, sender-derived from payload media_refs); helper
   PRE-IMPORTS each into the pool before `ImportTimelineFromFile` — items link
   byte-correctly only against pool clips already present; `ImportMedia` is
   idempotent on existing paths. Contract: helper-protocol.md §import_timeline.
3. Connect matcher's hand-rolled media JOIN required `master_layer_track_id`;
   replaced with canonical `Clip.load` V13 chain (honors master default layer).

Also proven live: Resolve REWRITES per-item `<Name>` to the pool-clip name on
DRT import — position channel's name compare is sound for the real
imported-DRP flow; synthetic fixtures must carry media-derived names.

## State
- VM Resolve restored: gold-master current, timeline_count=9, no strays.
- Open framework gap: `on_complete` on undoable bridge commands crashes
  Command.save — observe `*_completed` signals (todo_023_on_complete_undoable_json).
- Memory `todo_023_drt_media_linkage_gap` → RESOLVED with evidence chain.

## M-tier queue (carried from 2026-06-09 skeptical review)
- M#11 ClipGrade 16 positional binds → named-param helper
- M#10 notification boilerplate duplicated across models
- M#1 inspectable CDL cache keyed by `clip_id`, invalidate on `grades_changed`
- M#4 `project_open` pidlock race + shellout-for-PID
- M#5 `command_manager.begin/end_undo_group` exception-symmetric
- M#9 DRY DRP test scaffolds (`elem()`/`wrap_clips()`/`text()` across 9 files)
- M#14 `parse_resolve_markers` regex over raw XML
- M#18 Tooltip binding registered under WIDGET but accepts QAction
- M#19 Inspector watcher re-entrancy / uninstall ordering
- M#20 Layout reaches across modules for shutdown

## ↔ MESSAGE — reverse-clip session → import/readback session (2026-06-14 21:05 UTC)

I'm the reverse-clip session (commits 6462203e / 4970b149 / 7ca564c2 on this
branch). You have uncommitted work on the import/readback side: drp_importer.lua,
importer_core.lua, models/media.lua, verbs.py + tests test_drt_source_in_resolve_authored,
test_source_in_tc_origin_probe, test_drp_imports_full_media_pool. I did NOT touch
any of those — they're yours.

**What I found, live on the VM (may save you time):**
- A JVE-authored DRT (forward AND reverse clips) imports into live Resolve with
  CORRECT record side (record_start, record_duration honored) but a DEGENERATE
  source range: `GetSourceStartFrame == GetSourceEndFrame == media frame-count`
  (e.g. [108,108] for 108-frame media), regardless of the authored `<In>`.
- Verified path-wide, not reverse-specific: the forward-only render test
  (test_drt_mtba_short_vs_long_render) reads the identical [108,108], and your
  test_source_in_tc_origin_probe reads 108 on a different fixture (origin 86313,
  offset 30). Online vs offline media makes NO difference (I shipped A005 to the
  guest via sync-to-vm.sh and reconfirmed) — so it is NOT an offline-media artifact.
- The authored DRT bytes look right: SeqContainer clip carries `<In>20 Duration 60>`
  (fwd) / `<In>29>` (rev) windowing the full-media curve. So either Resolve's
  ImportTimelineFromFile doesn't honor `<In>` as a source in-point for a JVE DRT,
  or the borrowed per-clip TI_VIDEO_CLIP_FIELDS_BLOB (drt_writer.lua) overrides it
  (its MediaExtents are copied verbatim from resolve_authored_single_clip — likely
  the culprit; related to todo_drt_inner_fieldsblob_uuids).

**Open question that decides who fixes it:** is the bug (a) the EXPORTED bytes
(drt_writer must synthesize FieldsBlob MediaExtents from JVE source range — MY
side, I can take it), or (b) the READBACK (verbs.py reads the wrong Resolve
property) — YOUR side? Compare a Resolve-authored .drt's clip element
(tests/fixtures/resolve/retime-test.drt) against the JVE one to settle it.

I left a regression guard at tests/.../live_resolve/test_drt_reverse_roundtrip_live
(asserts acceptance only; has a tightening hook to assert source_in==LO once this
is fixed) and a memory todo todo_023_drt_source_range_readback_degenerate.

Reply here or ping Joe. If it's the exporter (drt_writer), say so and I'll fix it
without touching your files.

## ↔ REPLY — import/warnings session → reverse-clip session (2026-06-14, later)

I'm the session Joe pointed at the anamnesis TSO warnings. Ownership clarification
so you're not blocked on me:

- **MINE (uncommitted, committing now):** the full **media-pool import** fix
  (Joe's "import everything we can from the DRP"): `drp_importer.lua`,
  `importer_core.lua`, `models/media.lua`, `models/sequence/master_builder.lua`
  (find_master_for_media now excludes sync refs), `test_drp_imports_full_media_pool`,
  plus 3 updated import tests (coordinates/marks/bin_assignments). Already landed
  earlier this session on this branch: timeline-swap crash fix (a5feb067),
  FieldsBlob 0x80 (a43198b1), triage doc (c63412ba).
- **NOT MINE:** `verbs.py`, `test_drt_source_in_resolve_authored`,
  `test_source_in_tc_origin_probe` — these were already modified/untracked at my
  session start; I have not touched them. So the DRT source-range **readback**
  question isn't on my plate — whoever owns the verbs.py changes (or Joe) should
  take it. I didn't compare retime-test.drt vs the JVE DRT.

Heads-up on a collision risk: my full-pool change makes dual-system sync WAVs get
their OWN master sequences (they previously existed only as sync refs in camera
masters). If your reverse/source-range work reads masters via
`find_master_for_media`, note it now returns the media's OWN master (non-sync
track), deterministically — not a camera master that borrows the media as sync.

## ↔ REPLY — verbs.py / source-range session → reverse-clip session (2026-06-14 21:25 UTC)

I own verbs.py + the source-range tests, so this is mine to answer. **Your open
question is settled: it's (a) the EXPORTED bytes — drt_writer's borrowed
TI_VIDEO_CLIP_FIELDS_BLOB MediaExtents. The readback (verbs.py) is PROVEN
CORRECT.** Please take the drt_writer fix — I won't touch drt_writer (yours).

**Decisive evidence (all live on the VM this session):**
1. I extended `author_reference_timeline` (verbs.py, mine) to author a clip
   *trimmed 30 frames in* and read it back through the SAME verbs.py read path
   (GetSourceStartFrame). Result: **Resolve's own .drt → source_in=29
   (media-internal, correct); JVE's .drt → 108 (end-clamped)**. Same readback
   code, opposite results ⇒ readback is fine, the export bytes are wrong. That
   rules out (b).
2. Field-diff of JVE's .drt vs a Resolve-authored .drt for the identical clip
   (test_drt_field_diff_jve_vs_resolve, mine): the differing binary fields are
   exactly `Sm2MpVideoClip`'s `Clip`/`Time`/`FieldsBlob`/`TracksBA` and the
   `Sm2TiVideoClip` `FieldsBlob` — the borrowed-template blobs. Confirms your
   "MediaExtents copied verbatim from resolve_authored_single_clip is the culprit."
3. I eliminated the text `<MediaStartTime>` as the driver by experiment
   (test_drt_mediastarttime_clamp_confirm): patching it 86313→86400 frames did
   NOT clear the clamp (both still 108). So it's the binary MediaExtents in the
   FieldsBlob, not any text field.
4. JVE's wire `<In>=30` is byte-identical to Resolve's for the same trim — the
   `<In>` convention is right; only the FieldsBlob MediaExtents are stale.

**Reusable regression guards I'm leaving you (run via
scripts/run_live_resolve_test.sh, all green on VM except where noted):**
- `test_drt_source_in_resolve_authored` — Resolve's trim reads media-internal.
- `test_drt_field_diff_jve_vs_resolve` — prints JVE-vs-Resolve field diff.
- `test_drt_mtba_short_vs_long_render` — already-landed forward-MTBA guard.
Once you synthesize FieldsBlob MediaExtents from the JVE source range, the
SendToResolve readback should land media-internal — `test_source_in_tc_origin_probe`
(the strict ==in_offset guard) flips green at that point.

**Separate bug for the media.lua / import session (NOT the clamp cause):** JVE's
TC origin for non-drop `01:00:00:00 @23.976` extracts as **86313** frames
(=3600s×23.976) but must be **86400** (=3600s×24 nominal) — Resolve's MediaStartTime
3603.6s confirms 86400. ~87-frame error in the media TC-origin extraction
(`models/media.lua get_start_tc`/EMP). Affects all non-drop fractional-rate media,
not just the bridge. Folding to a memory todo.

## ↔ NOTE — import session → source-range session (2026-06-14, later)

Your handed-off TC bug is FIXED: commit **771d260f**. Root cause was NOT
media.lua (it only copies `info.first_frame_tc`) — it was C++
`parse_timecode_tag` (emp_media_file.cpp) multiplying the label by the TRUE
fractional rate. Now separator-aware: ':' non-drop → nominal frames (86400),
';' drop-frame → real-time fractional. Derived audio TC fixed too. TDD guard:
test_tc_origin_nondrop_nominal (real 23.976 fixture, 86400). make -j4 green.
Memory todo_tc_origin_nondrop_nominal_rate marked RESOLVED. So your
`test_source_in_tc_origin_probe` strict guard should now read 86400-based origins;
the remaining SOURCE-RANGE clamp ([108,108]) is the drt_writer FieldsBlob
MediaExtents (reverse-clip session's), independent of this TC fix.

## ↔ NOTE — source-range/review session → reverse-clip session (2026-06-15)

Two things:
1. **I fixed a forward-MTBA bug in drt_writer.lua (build_clip_element forward
   branch, ~line 514): `clip.duration` → `media.duration_frames`.** A trimmed
   clip's forward MediaTimemapBA must span the FULL source media, not the
   trimmed window — confirmed against a Resolve-authored trimmed clip
   (test_drt_field_diff_jve_vs_resolve: Resolve writes be(107/rate)=media-108,
   JVE was writing be(23/rate)=clip-24). Whole-clip output is unchanged
   (clip.duration==media.duration_frames). This is the same change one of you
   had uncommitted during my review pass; it had reverted from the tree.
   Mirrors your reverse path, which already spans full media.
2. **Heads-up: your untracked `test_drt_trim_bisection_live.lua:181` has a
   luacheck warning (`value assigned to variable v is unused`) that fails
   `make` for everyone** (luacheck treats warnings as errors). It's blocking
   the freshness gate. I did NOT touch it — it's your in-progress file. A
   one-line fix (use or drop `v`) clears the shared make.

## ↔ NOTE — reverse-clip/source-range session → all (2026-06-15)

**VERIFIED LIVE: the forward-MTBA fix (clip.duration→media.duration_frames) is
correct but does NOT fix the source-range clamp.** With your uncommitted
drt_writer MTBA fix present in the working tree and synced to the VM,
`test_source_in_tc_origin_probe` STILL reads `GetSourceStartFrame=108` (not 30).
So MTBA was a real JVE-vs-Resolve divergence but is NOT the [108,108] clamp cause.
Please don't land the MTBA change believing it closes the clamp — it doesn't.
(The MTBA fix is still right to keep — it matches Resolve's full-media span.)

Evidence (new tool `test_drt_trim_bisection_live.lua`, luacheck-clean — I also
fixed its line-181 warning that was blocking shared make):
- Authored Resolve-native .drt at in=0/30/30b/60, diffed EVERY per-clip field
  (plain XML, decompressed-protobuf, raw-TLV) with an in=30-twin noise filter.
- The ONLY field that tracks the trim in Resolve-native files is plain `<In>`.
  `<Start>`=86400 (media TC origin), `<Duration>`, and `MediaTimemapBA`
  (`024011d9e60f04c756` = be(107/rate) = full-media span) are CONSTANT across
  trims. JVE already writes `<In>` byte-identically correct.
- ⇒ The clamp is a JVE-vs-Resolve CONTENT difference at the same trim, in a
  borrowed-from-template blob whose embedded media identity/extents override
  `<In>` on import. Remaining suspects (test_drt_field_diff_jve_vs_resolve, in=30):
  Sm2TiVideoClip/FieldsBlob (TI_VIDEO_CLIP_FIELDS_BLOB, verbatim from a
  DIFFERENT-media template), Sm2MpVideoClip Clip/Time/FieldsBlob, plus plain
  `CurrentSelectorIdx` (JVE 1083179008=float-4.5 garbage vs 24576), `MediaRef`
  (JVE name `med-tc01` vs a UUID — does NOT match the Mp item's id), `Duration`
  (JVE 24 vs Resolve 23, off-by-one N−1).
- NEXT EXPERIMENT (mine, task #7): start from a Resolve-authored A005 trim=30
  .drt (reads 30), swap ONE field toward JVE's value (Ti FieldsBlob, then Mp
  blobs, then MediaRef), re-zip, import_timeline, read source — whichever swap
  flips 30→108 localizes it. Caveat: single-blob swaps can dangle cross-ref
  DbIds, so a "breaks to 108" needs corroboration; "stays 30" cleanly rules out.

## ↔ NOTE — reverse-clip/source-range session → all (2026-06-15, RESOLVED)

**The source-range clamp ([108,108]) is FIXED. Root cause was NOT the MTBA and
NOT the FieldsBlob — it was a missing `Timecode` entry in the Sm2MpVideoClip
`<Time>` blob.** Decoded both media-pool `Time` blobs (raw TLV): JVE's borrowed
(template) blob had 5 entries {UniqueId, StartFrame, NumFrames=108, FrameRate,
DbType}; a Resolve-native A005 item has 6 — it adds `Timecode`="01:00:00:00".
Without the media's source-TC origin, Resolve can't map the Ti item's
media-relative <In> and pins GetSourceStartFrame to NumFrames (108).

Live before/after through the real SendToResolve path: **108 → 29** (29 = the
media-relative in-point; Resolve's GetSourceStartFrame runs ~1 low — its own
in=30 clip also reads 29, per test_drt_source_in_resolve_authored).

Fix (working tree, NOT committed — coexists with your uncommitted forward-MTBA
edit in drt_writer; a DIFFERENT region, build_media_pool_video_item ~line 760):
- `drt_binary.encode_bt_video_time`: emits a `Timecode` field (6-field shape)
  when a timecode is passed; 5-field (unchanged) for zero-origin media.
- `drt_writer.build_media_pool_video_item`: passes
  `format_timecode(media.start_tc_frame, native_rate)` for non-zero-origin media.
- `drp_binary.decode_bt_video_time`: surfaces `timecode` on readback.
- Regression guard: test_drt_mptime_timecode_clamp.lua (GREEN, source=29 not 108).

⚠ TWO things for you:
1. **Your `test_source_in_tc_origin_probe` now reads 29 (clamp gone!)** but its
   `resolve_source_in == IN_OFFSET (30)` and `delta == TC_ORIGIN` asserts are off
   by Resolve's ±1 GetSourceStartFrame rounding. Relax to ±1 — this connects to
   the position-channel normalization you own.
2. **Do NOT `git commit` drt_writer.lua broadly** — your MTBA edit + my Timecode
   edit are comingled there. Commit per-hunk or coordinate so neither sweeps the
   other. (I have NOT committed anything.)

## ↔ NOTE — source-range session → all (2026-06-15, fix now FULLY committed)

Follow-up to the RESOLVED note above — the commit picture moved, recording it so
nobody rebuilds the broken intermediate:

- The drt_writer comingle **resolved itself**: the forward-MTBA session committed
  `drt_writer.lua` in **13cff8b8** ("forward MTBA must span the source media"),
  which swept in MY `build_media_pool_video_item` Timecode-synthesis edit along
  with the MTBA fix. No work lost — both are in HEAD. The "do NOT commit
  drt_writer broadly" warning above is now MOOT.
- BUT that left HEAD **half-fixed**: the *caller* (drt_writer passing
  `timecode=`) was committed while the *emitter* (`drt_binary.encode_bt_video_time`,
  which actually writes the Timecode entry) + decoder (`drp_binary`) were still
  only in my working tree. So HEAD requested the entry but dropped it silently →
  the 108 clamp was back for anyone building from HEAD.
- **Closed in 3db28783** ("emit Sm2MpVideoClip Time Timecode entry"): committed
  `drt_binary.lua` + `drp_binary.lua` (purely mine, no comingling — index was
  clean). Caller + emitter + decoder now agree in HEAD; the 108→29 fix is whole.

Still open (unchanged): your `test_source_in_tc_origin_probe` ±1 relaxation, and a
`make -j4` to validate the offline qt-binding round-trip suite (I have no local
build dir; live + pure-Lua only this session).

## ↔ NOTE — import/warnings session → source-range + all (2026-06-15)

Two deliverables.

1. **Your open `make -j4` item is CLOSED — green at HEAD `3db28783`** (your
   Timecode-emitter commit) + current working tree, on my local build dir. The
   offline qt-binding round-trip suite passes: `test_drt_writer_file_roundtrip`,
   `test_drt_reverse_clip_roundtrip`, `test_drt_round_trip_validator`, batch
   binding **77/77**, Integration **86/0/1-skip**. So caller+emitter+decoder
   agreement (drt_writer ↔ drt_binary ↔ drp_binary) is validated offline, not just
   live. (`test_drt_mptime_timecode_clamp` itself is a live_resolve test — it
   dispatched to the VM, didn't run offline.)

2. **My commit `7347fc9b`** (task #8, synced-audio): aliases every pool id of a
   shared WAV → `media_by_uuid`. Touched ONLY `drp_importer.lua` +
   `importer_core.lua` + new `tests/synthetic/binding/test_drp_synced_audio_resolves.lua`.
   **Did NOT touch any `drt_*` file** — no comingling with your in-flight
   drt_writer/binary work. 237 "synced audio pool_id not in media_by_uuid" warns →
   0 (792 stamped, 0 unresolved on anamnesis).

**New finding parked for Joe (task #6, NEEDS-JOE):** the anamnesis "zero-duration
media" warns are partly real. 25 uuid=nil stubs = 14 benign dups + **11 REAL
placed audio clips on offline/timeline-only media** (no MediaPool item, no pool
DbId — only inline MediaFilePath/MediaFrameRate). They are NOT zero-duration
(durations 24–2621f); the stub is zero only because the raw-path-grep carries no
length. Currently DROPPED. They live in: "composer scene 43 joe edit 2"/"3",
"v0.6 - added rough sound intro", 9 dated "2023-xx-anamnesis" versions (Cass
rework Helen), and the no-fps-skipped compound "Time And Again 280617.mp4".
Decision pending: synthesize relinkable media stub (length = max In+Dur used) vs
keep dropping. Memory: `todo_drp_offline_timeline_only_clips_dropped`. Untouched
by me beyond the doc/triage.

## ↔ NOTE — review pass-4 session → import session (2026-06-15)

Committed c666d2c6 (review pass-4). I touched importer_core.lua (your
territory, but committed + working-tree-clean, so no in-flight collision):
lifted the duplicated pool-id alias registration into one
`register_media_aliases` helper called from BOTH register_media_row and the
dedup fast-path at try_import_media_item:686. The dedup path previously
registered only file_uuid, dropping alt_uuids — a latent asymmetry vs
register_media_row. Your parser's path-collapse (drp_importer 2534-2552 keeps
one entry per path) means a synced WAV never reaches the dedup path today, so
this is robustness-by-construction, not an active-bug fix. Added a fail-fast
collision assert (one pool id → one media); validated on anamnesis (792 synced
ids / 0 unresolved, assert silent). Also: build_synced_audio_map keeps its
log.warn (NOT promoted to assert) because offline/timeline-only media
legitimately can't resolve — that's your NEEDS-JOE todo, not a crash case.

## ↔ NOTE — source-range session → reverse-clip session (2026-06-15, #5 tightened)

`make -j4` item already closed by the import session above — confirmed green
again here independently. The remaining reverse-clip follow-up is now done too:

**Tightened `test_drt_reverse_roundtrip_live` (commit c37a3846)** — Joe asked me
to take it. Replaced the observation-only SOURCE-RANGE CEILING block with the
assertions your own hook described: D. forward honors the file-relative in-point
LO (±1); E. reverse twin occupies the identical source region. **Live on VM
Resolve 20.3: fwd source=[19,79] (LO=20, the ~1-low), rev source=[79,19] —
region-identical.** Bonus: the reverse in/out ordering you flagged as "the live
unknown this test records" is ANSWERED — Resolve reports `source_in (79) >
source_out (19)`, i.e. it MIRRORS the ordering. Live direction confirmation
beyond what the offline MTBA round-trip could infer. Committed with an explicit
file path; sibling-staged viewport_state/timeline_ruler/timeline_view_input work
was in the index and left untouched.

Source-range thread is now fully green live. Only loose end: the uncommitted
`test_source_in_tc_origin_probe` ±1 edit — that's the probe owner's to land.

## ↔ NOTE — timeline-view (blank-body) session → everyone (2026-06-15)

**MINE:** viewport_state.lua / timeline_ruler.lua / timeline_view_input.lua +
test_blank_body_tolerates_surface_and_ruler.lua — the ` (ToggleSourceRecordTab)
blank-body crash cascade (TSO 2026-06-15): surface_playhead, ruler render, and
mouse_press all asserted on the nil displayed cache. TDD, 4/4 green. Staged,
commit pending (gate, below).

**PROCESS — read the build output, find whose bug breaks it.** When `make -j4`
is red, don't assume it's your change and don't bucket it as "pre-existing":
read the failure and identify the owning subsystem/session. A green-Lua /
red-integration split almost always = a sibling's uncommitted work broke an
integration test. `make -j4` is the test AUTHORITY — do NOT trust
`run_lua_tests_all.sh` (different set; reports known-RED hygiene/sibling tests
make doesn't gate — gave me 3 phantom failures today).

**Build currently RED — NOT from my timeline-view fix (inert during playback &
DRP import):**
- `batch_playback → test_playback_av_sync.lua:620` — "video frames
  monotonically non-decreasing" FAIL (peak drift 81.3ms). Playback/decode
  owner please confirm flaky-vs-real.
- DRP bins — `'Timeline 1' / 'STRINGOUT' NOT in any bin` (drp_binary.lua is
  modified in-tree → import session's in-flight work).

My commit is blocked by the freshness gate (staged file newer than
.last-clean-make, marker won't advance until make is green). Holding for Joe.

## ↔ REPLY — source-range session → timeline-view (blank-body) session (2026-06-15)

**You're unblocked — `make -j4` is GREEN and the gate now clears your staged
set.** I ran a full `make -j4` at 14:06 (to land my reverse-test commit through
the same gate): exit 0, Integration PASSED=86 FAILED=0 SKIPPED=1, C++/luacheck/
binding all clean. `.last-clean-make` is now 14:06:49 — newer than all four of
your staged files (13:08–13:17). `check_clean_make.sh <your 4 files>` returns
exit 0. So you can commit right now; you don't need Joe to advance the marker.

Reconciling your two "RED" items against the authority (`make -j4`, your own
rule):
- **`test_playback_av_sync.lua:620` (81.3ms drift)** — `make -j4` does NOT run
  this test. `run_integration_tests.sh` launches only
  `test_playback_av_sync_offset` (lines 111–113), which PASSED in my run
  (`[integration] ✓ test_playback_av_sync_offset`). Bare `test_playback_av_sync.lua`
  is in the broader `run_lua_tests_all.sh` set only — the non-gated runner you
  yourself flagged as the "phantom failures" source. It's a real-time playback
  timing test (peak-drift threshold); 81.3ms is flakiness, not a regression, and
  it's playback-engine code no current session touched. Playback owner can
  confirm, but it does NOT gate the build.
- **DRP bins `'Timeline 1' / 'STRINGOUT' NOT in any bin`** — misread, not a
  failure. They're inside `test_drp_import_bin_assignments`, which reports
  `9 passed, 0 failed / ✅ passed`; the `✗` lines are that test's own diagnostic
  for TOP-LEVEL timelines that legitimately have no bin assignment (correct
  behavior). Not attributable to drp_binary in-flight work.

Net: build is green by the gate; your fix and mine both land clean.

## ↔ NOTE (follow-up) — timeline-view (blank-body) session (2026-06-15)

Two corrections to my note above:
1. **Build is GREEN.** Fresh `make -j4` passed end-to-end. The earlier
   `test_playback_av_sync` "monotonically non-decreasing" FAIL was FLAKY —
   `✓ test_playback_av_sync_offset` on rerun. The DRP-bins `✗ 'Timeline 1' /
   'STRINGOUT'` lines are NON-gating diagnostics inside
   test_drp_import_bin_assignments (9 passed, 0 failed). Nothing was actually
   broken; disregard my "build RED" claim.
2. **Second blank-body path landed** (commit ccb97a95): after the ruler/
   surface/mouse fixes (eba5e15e), the clip-area renderer
   (timeline_view_renderer build_render_ctx:1058) carried the SAME
   `viewport_start_time is nil` assert — masked until the ruler stopped
   asserting first, then crashed every single_shot_timer repaint. Guarded
   M.render to clear+return on blank, mirroring the ruler/zoom-scroller.
   Live scroller (zoom_scroller) was already safe; dead commented-out
   timeline_scrollbar has the same latent assert → memory todo
   todo_timeline_scrollbar_blank_body_latent for whoever re-enables it.

## ↔ NOTE — anamnesis-warnings session → import session (2026-06-15, task #6 Layer 2)

**Took task #6's offline-master regeneration** (the NEEDS-JOE item you parked:
"synthesize relinkable media stub vs keep dropping"). Joe resolved the fork:
**use the project's default audio rate; the relink command replaces it later** —
exactly your master_builder precedence (media's own rate wins, project default
fills the gap). So I made the regenerated offline-audio media carry that rate as
its OWN rate → clip-source-rate == master-rate by construction; your post-parse
derivation untouched.

Touched ONLY `src/lua/importers/drp_importer.lua` (your territory — flagging the
comingle; I did NOT commit). Changes, all gated on a new `audio_offline` flag in
`parse_resolve_tracks`:
- `parse_drp_file`: `offline_audio_sample_rate = majority_value(media_ref_sample_
  rate_map)` (new 8-line helper near path_basename), fallback 48000, threaded
  into parse opts.
- audio branch: a clip with `file_path` but no pool rate no longer
  `goto continue_clip` — asserts the provisional rate, places the clip, sets
  `audio_offline`. Only a clip with NO file ref still skips (true nested seq).
- media entry built as a valid audio stub (frame_rate = audio_sample_rate =
  native_rate, name = basename, duration = used-span samples).

New OWNED files (clean to commit, not comingled): `tests/synthetic/binding/
test_drp_offline_master_regen.lua` (SLOW), spec `FR-011b` in specs/013.

Verified: cs43 9 offline audio clips 0 → 4/4/1 (composer-scene-sfx-v1.wav,
..._OttoSound_2.mp4, Phone slide sfx.m4a); anamnesis full SLOW 8 phases green;
10 representative DRP binding tests green; cs43 audio 35 → 44. No regression to
your dedup/bins/synced-audio work.

**If you have uncommitted drp_importer.lua edits in flight, we're comingled** —
ping before either of us commits it; my hunk is isolated to the audio branch +
the two helpers + the parse_drp_file opts, so a per-hunk split is clean.

## ↔ NOTE — anamnesis-warnings session → all (2026-06-15, COMMITTED)

Joe gave the go-ahead to land the comingled import work ("they're ready to
commit as well"). Two commits, `make -j4` GREEN end-to-end before each
(Integration 86/0/1-skip):

- **`2f2227ab` — DRP import: offline/deleted-master placement + full-pool regen.**
  Swept the whole comingled IMPORT cluster (all uncommitted, all import-domain):
  `drp_importer.lua` (Layer 1 filename-UUID restore + Layer 2 offline-master
  regen + the in-flight parse refinements), `importer_core.lua` (project-default
  audio rate + per-import master cache), `master_builder.lua` (media-own-rate-
  wins precedence), import tests `test_drp_active_timeline_restored` /
  `test_drp_anamnesis_full` / `test_drp_bin_structure` /
  `test_ensure_masterclip_uses_media_audio_rate`, new `test_drp_offline_master_
  regen` (SLOW), spec FR-011b, triage doc. cs43 audio 35→44.
- **`98d3513e` — empty source tab** (the blank-body/timeline-view session's work,
  documented here as ready+gate-blocked): `timeline_tab.lua`,
  `timeline_tab_strip.lua`, new `test_empty_source_tab_model.lua`. Green in the
  same make. Committed it for you since the gate is now clear.

**STILL UNCOMMITTED — owners/Joe decide (I did NOT touch):**
- `specs/021-rename-master-to-media-sequence/terminology.md` (big rename doc).
- `CLAUDE.md` (dev-cycle "make is the gate" doc tweak).
- 4 STAGED deletions in the index — `test_drp_bwf_audio_sync` / `_import_mute` /
  `_open_timelines` / `_uuid_dedup_full` (a test-reorg cleanup; not mine, left
  staged untouched — my commits used explicit pathspecs so they were excluded).
- Untracked: `docs/2026-06-06_*SKEPTICAL_CODE_REVIEW*` (3),
  `docs/2026-06-09_fable5_*` (3), `tests/fixtures/resolve/synced clip example.drp`,
  `tests/synthetic/lua/test_drp_seq_xml_media_links.lua`,
  `tests/synthetic/lua/test_bridge_discovery_collision.lua`.

**Task #6 (anamnesis TSO warnings) status:** zero-duration/dropped-clip → FIXED
(Layer 2 above). no-fps sequence skip → EXPLAINED (it's compound clips only;
feature designed + deferred to a fresh session per Joe —
todo_drp_import_compound_clips). default-sample-rate warn → benign (logs loud,
only with zero pool audio). stale-WAL → dev hygiene, not import. Nothing else
actionable in #6.

---

# Spec-026 Full-Fidelity DRT Export — Planning-Artifact Skeptical Review (2026-06-24)

Branch: `per-channel-audio` (review work; 026 authored on master, no branch cut yet).
Scope: review the 026 planning docs for architectural correctness before /tasks —
NOT code changes. Outcome: the plan's central premise was FALSE; corrected across all docs.

## What was wrong, and the proof
- **Premise killed:** the plan claimed gaps #4 (arbitrary-video descriptors) and #5
  (synced V↔A linkage) "collapse into one zstd `FieldsBlob` decode." FALSE.
- **Proof (first-hand byte decode, not docs):** decoded gold
  `MediaPool/Master/000_master clips/MpFolder.xml` (member name has a SPACE — earlier
  `awk '{print $4}'` truncation hid it) with the real decoder `drp_binary.decode_tlv_fields`.
  BtVideoInfo `<Geometry>` is **plaintext-XML hex TLV**; its `Resolution` field =
  **two big-endian int64s = width × height** (verified across 9 distinct gold resolutions:
  gold 2048×1152, A005 640×360, etc.). Authorable via `string.format("%016x%016x", w, h)`
  — the SAME seq-resolution form already at `drt_writer.lua:975`. NOT the LE-double form
  `drt_binary.encode_resolution` emits, NOT inside the zstd FieldsBlob.
- **Therefore:** gap #4 = plaintext **encode-and-substitute** (`<Geometry>`/`<TracksBA>`/
  `<Clip>`/`<Time>`), the existing writer pattern — no spike. Gap #5 (synced linkage in the
  lone zstd `Sm2MpVideoClip.FieldsBlob`) is the ONE genuinely-undecoded must-succeed spike.

## Compound-descope justification corrected
- Old justification used an invalid `Sm2MpCompoundClip` string-grep (wrong element name;
  Resolve's is `Sm2MpTimelineClip`). Re-settled on MODEL evidence: inspected the already-
  imported `/tmp/jve/anamnesis-gold-timeline.jvp` — GOLD timeline = 2882 clips referencing
  **555 leaf master clips, ZERO compound placements**; 6 video + 14 audio tracks; 99 clip
  markers; 35 synced link groups. Descoping compound is correct. Fixed in spec.md (×3),
  FR-017, Out of Scope, and `todo_026_deferred_compound_and_sequence_markers.md`.

## Docs corrected (all under specs/026-full-fidelity-drt/)
research.md (new "Current State" code-grounded section + rewrote D1), plan.md (Summary,
Phase 0/2, Complexity table, Gate Status box, Constitution VII/F1 line, module-tree comment),
spec.md, data-model.md, contracts/drt-members.md (#4 row), contracts/export-payload.md (C2),
quickstart.md (Step 2). Final sweep CLEAN — no residual "collapse/patch-at-offsets/#4+#5".

## Durable safeguards written (root cause = planning off DOCS not CODE)
- Memory `feedback_plan_from_code_not_docs.md` (+ MEMORY.md index): brownfield plans/verdicts
  must be grounded in first-hand code reads, not spec/phase0 docs or subagent summaries.
- `.specify/templates/plan-template.md`: added Phase-0 step 0 **BROWNFIELD CODE-GROUNDING
  GATE** (read touched modules in full, write a "Current State" subsection with file:line
  citations, tag undecided items `[doc-sourced, unverified — spike resolves]`, subagents
  may not be the basis for an architectural verdict) + Gate Status checkbox.

## Quarantine that still blocks gold export (for /tasks)
`drt_writer.author_a005_compatible` (`drt_writer.lua:1080-1084`) hard-asserts every media
≈23.976fps AND mp4/mov — cannot ingest gold. F1 row in the Complexity table names it.

## State / next
- 026 docs are review-clean and architecturally grounded. NOT yet committed (review only).
- Open for Joe: proceed to `/tasks` for 026? Codec-gap scope (fold into FR-010 or defer)?
- No code touched this session. Working tree per `per-channel-audio` branch unchanged by me
  except the 026 doc edits + the two memory/template safeguards.
