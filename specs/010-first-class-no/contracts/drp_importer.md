# Contract: `importers.drp_importer` — `resolve_project_tab_ids`

## Location
`src/lua/importers/drp_importer.lua` — function `resolve_project_tab_ids(project, timeline_id_map)` at ~line 528.

## Current behavior (pre-feature)
Three priority paths, then a silent fall-through:
```
Priority 1: SequenceTabsData (FieldsBlob) non-empty                → set open_ids + active_id
Priority 2: TimelineHandleVec + CurrentTimelineIndex resolves      → set single-tab
Otherwise: log.warn and leave empty state
```
The `log.warn` path fires in four distinct sub-cases — three of which are malformed-file or parser bugs. See [research.md §4](../research.md).

## New behavior (post-feature)

| Sub-case | Trigger | Treatment |
|---|---|---|
| **Case 1** | `tabs_data` empty AND `timeline_handle_vec_ids` empty AND (no CurrentTimelineIndex or it's nil) | Leave `project.open_timeline_ids = {}`, `active_timeline_id = nil`. No assert. Legitimate format variant. |
| **Case 2** | `#timeline_handle_vec_ids > 0` AND (`cti < 0` OR `cti >= #timeline_handle_vec_ids`) | **Assert.** Message: `"drp_importer: CurrentTimelineIndex=%d out of range for TimelineHandleVec of length %d (DRP file corruption)"` |
| **Case 3** | Valid `cti`, handle id is non-nil, but `timeline_id_map[tl_db_id]` is nil | **Assert.** Message: `"drp_importer: TimelineHandleVec[%d]=%s has no corresponding Sm2Sequence in MediaPool (DRP file corruption or parser bug)"` |
| **Case 4** | `#timeline_handle_vec_ids > 0` AND `CurrentTimelineIndex` is nil (absent from project.xml) | **Assert.** Message: `"drp_importer: TimelineHandleVec has %d entries but <CurrentTimelineIndex> is missing (DRP file corruption)"` |

Case 2/3/4 messages MUST include the function name and the offending values so the error is actionable (constitution principle VI).

## Preconditions (unchanged)
- `project` is the result of `parse_project_metadata` with `sequence_tabs_data`, `timeline_handle_vec_ids`, and `current_timeline_index` populated.
- `timeline_id_map` maps `Sm2Timeline.DbId` → `{name, seq_id}`.

## Postconditions
- If no assert fires: `project.open_timeline_ids` is set (possibly `{}`) and `project.active_timeline_id` is set (possibly `nil`).
- Case 1 is the only path that can leave both empty/nil.
- Cases 2/3/4 never return — they raise.

## Required tests

- `tests/test_drp_resolver_asserts_malformed.lua` (pure Lua, no --test mode needed):
  - Build a minimal `project` + `timeline_id_map` fixture in code.
  - **Case 2**: handle_vec_ids = `{"a", "b"}`, cti = 5 → `pcall(resolve_project_tab_ids, …)` returns false + message containing "out of range".
  - **Case 3**: handle_vec_ids = `{"a"}`, cti = 0, timeline_id_map = `{}` → pcall returns false + "no corresponding Sm2Sequence".
  - **Case 4**: handle_vec_ids = `{"a"}`, cti = nil → pcall returns false + "<CurrentTimelineIndex> is missing".
  - **Case 1**: handle_vec_ids = `{}`, sequence_tabs_data nil → pcall succeeds, project.open_timeline_ids == {}, active_timeline_id == nil.
  - Happy-path regression for Priority 1 + Priority 2 already covered by existing `test_drp_active_timeline_restored.lua`.

## Interaction with `convert()`
`convert()` already asserts on unresolved open-tab UUIDs (commit `90ecb27`, lines ~2265–2285). Those asserts remain. Together they form a contract chain: the resolver produces valid UUIDs or raises; the converter maps UUIDs to sequence ids or raises. No silent path survives.
