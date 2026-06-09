# Spec-023 Skeptical Review — Session Checkpoint

Branch: `023-resolve-color-bridge`
Date: 2026-06-09

## 9 tasks this segment

| # | Item | Outcome | Commit |
|---|---|---|---|
| 1 | Pass 7 — A#5 `cpu_video_surface.cpp` push-contract comment | fix | `e058317d` |
| 2 | Pass 8 — A#2 `_SINGLE_CLIP` rename + evidence-based rejection of reviewer HIGH claim | fix + memory update | `707771db` |
| 3 | A#1 — borrowed-FieldsBlob UUID enumeration (incl. `1235499f-…` audio DbId) | memory-only fold into `todo_drt_inner_fieldsblob_uuids.md` | — |
| 4 | A#3 — verified closed (gates + todos already in place) | no change | — |
| 5 | Pass 9 — DRY#5 lift `invoke_cb` → shared `jve_invoke_lua_callback` (process/local_socket/fs_watcher) + deferred Slot/registry template todo | refactor | `01b00582` |
| 6 | M#13 — verified closed (`qt_process_start` doc accurate) | no change | — |
| 7 | Pass 10 — M#15 fix ping crash on disconnected handle + spec sync + TDD test | fix + test | `2cd2ca14` |
| 8 | Pass 11 — M#17 CDL EDL closed-set ASC_* guard (incl. side-fix on silent fallthrough → misleading EOF) | fix + 2 tests | `90c493f5` |
| 9 | Pass 12 — M#16 helper bootstrap platform gate (linux/win refuse-to-guess) + TDD test | fix + test | `ea928567` |

Bonus: M#6 keyboard return-semantic verified closed (consume-on-match contract already documented at `keyboard_shortcut_registry.lua:880-884`).

## Deferred todos added
- `todo_023_callback_slot_registry_template.md` — full `template<typename SlotT> CallbackSlotRegistry` refactor (not /cu-safe; ~1-2hr focused work)
- `todo_drt_inner_fieldsblob_uuids.md` updated — 5 borrowed FieldsBlob hex constants in `drt_writer.lua` enumerated

## Next up (M-tier queue)
- M#11 ClipGrade 16 positional binds → named-param helper
- M#10 notification boilerplate duplicated across models
- M#21 `synced_at` INTEGER schema display
- M#1 inspectable CDL cache keyed by `clip_id`, invalidate on `grades_changed`
- M#4 `project_open` pidlock race + shellout-for-PID
- M#5 `command_manager.begin/end_undo_group` exception-symmetric
- M#9 DRY DRP test scaffolds (`elem()`/`wrap_clips()`/`text()` across 9 files)
- M#14 `parse_resolve_markers` regex over raw XML
- M#18 Tooltip binding registered under WIDGET but accepts QAction
- M#19 Inspector watcher re-entrancy / uninstall ordering
- M#20 Layout reaches across modules for shutdown
