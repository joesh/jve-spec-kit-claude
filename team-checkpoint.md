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
| 7 | T042 edge cases + T033 pixel compare | ⏳ | — |
| 8 | T014 sentinel flip + T043 remnants + T044/T045 | ⏳ (T044 gate: `make -j4` exit 0 on 2026-06-10) | — |

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
