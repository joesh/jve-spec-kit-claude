# Research: Gap-as-Clip Refactor

## Code Inventory

### Functions to Remove (batch_ripple_edit.lua)

| Function | Lines | Purpose | Replacement |
|----------|-------|---------|-------------|
| `create_temp_gap_clip()` | ~2310-2380 | Materialize gap from neighbor positions | gap_lifecycle.compute_gaps_for_track |
| `register_temp_gap()` | ~510-523 | Add temp gap to clip_lookup | Gaps already in track clip list |
| `materialize_gap_edges()` | ~556-570 | Convert clip:gap_after → temp_gap:gap_after | Edge picker selects gap:in directly |
| `move_gap_right_clip()` | ~1293-1320 | Propagate gap geometry to right clip | Roll mechanics handle it (gap is a clip) |
| `compute_gap_shift_value()` | ~1296-1318 | Compute right clip shift from gap change | Not needed — gap duration change IS shift |
| `propagate_gap_offsets()` | ~1322-1340 | Iterate modified_clips for temp gaps | Removed entirely |
| `inject_implicit_gap_edges()` | ~578-640 | Create phantom edges on unselected tracks | Replaced by gap_lifecycle.create_implied_gap |
| `compute_gap_close_constraint()` | ~179-207 | Gap-specific constraint | Unified with apply_min_duration_limits |
| `clamp_gap_to_origin()` | ~278-293 | Gap can't extend before 0 | Same as any clip |
| `apply_gap_limits()` | ~265-278 | Gap constraint dispatch | Removed — uses clip constraints |
| `gap_right_has_independent_in_edge()` | ~1260-1268 | Guard for gap propagation | No propagation |
| `clip_has_selected_edge()` guard | ~1303 | Prevent roll propagation to unselected | No propagation needed |

### Branch Points to Remove (~20)

- `is_gap_edge()` in apply_edge_ripple, compute_applied_delta, record_gap_delta, analyze_selection, compute_constraints, build_planned_mutations, edge preview builder
- `is_temp_gap` in build_clip_cache, snapshot_clip_for_gap, load_clip_for_edit, ensure_clip_loaded
- `gap_before`/`gap_after` in edge_utils.to_bracket, edge_picker.select_boundary_edges, edge_picker.build_boundaries, build_edge_key
- Gap-roll special path in apply_edge_ripple (lines 824-831)

### Pipeline Steps to Remove

Current: `materialize_gap_edges → inject_implicit_gap_edges → ... → propagate_gap_offsets`
After: All three removed from pipeline.lua

### Tests Referencing Gap Edge Types (~30 files)

Files matching `gap_before|gap_after|is_temp_gap|gap_edge`:
- test_batch_ripple_gap_*.lua (8 files)
- test_gap_*.lua (5 files)
- test_timeline_*gap*.lua (6 files)
- test_edge_*.lua (3 files)
- test_asymmetric_ripple_gap_*.lua (2 files)
- helpers/ripple_test_runner.lua (gap_before edge type)
- Various other files with is_gap_edge checks

### Decision Log

| Decision | Rationale | Rejected Alternative |
|----------|-----------|---------------------|
| In-memory gaps | Undo free (recompute from clips). No schema change. | DB rows — simpler but inflates clip count |
| Persistent for session | Edge picker needs gaps at all times | Transient per-edit — can't select gaps between edits |
| Local recompute | O(n) unacceptable for long timelines | Full recompute |
| On-the-fly zero-length gaps | Avoids polluting track list | Always-present zero-length — 3 edges at every boundary |
| Single gap_lifecycle module | All gap creation/deletion in one place (FR-001a) | Spread across commands — violates single responsibility |
