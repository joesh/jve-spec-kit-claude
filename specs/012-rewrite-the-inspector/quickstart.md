# Quickstart: Inspector Rewrite (012)

This document shows how to exercise the rewritten Inspector as a user, how to run the automated test suites, and how to validate the acceptance gate manually.

---

## 1. Build

```bash
cd /Users/joe/Local/jve-spec-kit-claude

# Full build + Lua tests + C++ tests. Must pass clean (zero luacheck warnings).
make -j4 2>&1 | tee /tmp/build.log

# Editor-only rebuild (faster for UI iteration):
cd build && make JVEEditor -j4
```

---

## 2. Run the Inspector manually

```bash
# Kill any stale JVEEditor process so the SQLite -shm file can be removed safely.
pgrep -x JVEEditor || rm -f "$HOME/Documents/JVE Projects/Untitled Project.jvp-shm"

./build/bin/JVEEditor
```

The Inspector panel is on the right side of the three-panel layout. Exercise the Primary User Story from `spec.md`:

1. Select one master clip in the Project Browser → Inspector shows `Clip: <name>` with clip-schema sections.
2. Select a timeline clip → Inspector shows clip-schema sections AND a mark-summary line.
3. Edit a field (e.g., clip name) → press Enter or click away → change persists.
4. Issue undo (Cmd+Z) → Inspector field reverts without you re-selecting.
5. Issue redo (Cmd+Shift+Z) → Inspector field re-updates.
6. Select two clips → Apply button appears; fields that differ across the two show `<mixed>`.
7. Type a new value and press Apply → both clips update in one undo group.
8. Select one clip and one sequence (heterogeneous) → Inspector shows majority schema with header "1 clip, 1 sequence — editing 1 clip" (or whichever majority).
9. Open a different project → Inspector clears.
10. Collapse the Source Range section, quit, relaunch → section is still collapsed.

---

## 3. Run the automated test suites

### 3.1 Unit tests (Qt stubs; fast)

```bash
cd tests
luajit test_harness.lua unit/inspector/test_filter_matching.lua
luajit test_harness.lua unit/inspector/test_majority_schema_tiebreak.lua
luajit test_harness.lua unit/inspector/test_mixed_value_detection.lua
luajit test_harness.lua unit/inspector/test_timecode_parse_format.lua
luajit test_harness.lua unit/inspector/test_pending_edit_discard.lua
luajit test_harness.lua unit/inspector/test_read_only_commit_suppression.lua
```

Or run everything via `make -j4` from repo root (runs all Lua tests + luacheck + C++ tests).

### 3.2 Integration tests (`--test` mode; full Qt process, 1:1 with Acceptance Scenarios)

```bash
for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17; do
  script=$(ls tests/integration/inspector/scenario_${i}_*.lua 2>/dev/null | head -1)
  if [ -n "$script" ]; then
    echo "=== Scenario ${i}: $(basename "$script") ==="
    ./build/bin/JVEEditor --test "$script" > "/tmp/inspector_scenario_${i}.txt" 2>&1 || echo "FAILED"
  fi
done
```

All 17 must report `✅` on their last line (14 Acceptance Scenarios from spec.md + 3 /analyze-driven: G1 pull-missing, G3 invalid-input, G4 mid-edit race). Failures go to the corresponding `/tmp/inspector_scenario_NN.txt` for inspection.

### 3.3 luacheck

```bash
luacheck src/lua --config .luacheckrc --std luajit
```

Zero warnings required (rule 2.4).

---

## 4. Behavior-preservation acceptance gate

The rewrite is accepted when all of the following hold:

- [ ] `make -j4` from the repo root exits 0.
- [ ] All 11 unit tests pass (6 FR-032 + 5 /analyze-driven).
- [ ] All 17 `--test` integration scenarios pass (14 spec Acceptance Scenarios + 3 /analyze-driven).
- [ ] `luacheck` produces zero warnings for `src/lua/`.
- [ ] Manual walkthrough of the 10 steps in §2 above produces the expected behavior.
- [ ] Files deleted: `view.lua`, `adapter.lua`, `widget_pool.lua`, `selection_inspector.lua`, `main_window.lua`, `test_inspector_modules.lua`. Confirm via `git status` that these appear as deletions, not modifications.
- [ ] `git grep "pcall(qt_constants\\." src/lua/ui/inspector/` returns nothing (FR-024).
- [ ] `git grep " or \"\"\\| or 0\\| or nil" src/lua/ui/inspector/` returns no fallback usages on required data (FR-025).
- [ ] `git grep "_G\\.inspector_" src/lua/` returns nothing (FR-027).

---

## 5. Manual invariant checks (in addition to §2)

### Deletion responsibility (FR-017a/b)

1. Launch the editor. Select a clip. Inspector shows it.
2. Delete that clip from the timeline (Delete key).
3. Expected: the timeline's delete command emits a selection-change; the Inspector receives an empty or one-smaller selection and updates normally. No assertion fires.
4. If instead the Inspector asserts with a "missing inspectable" message, the delete command failed to emit a selection change — file that as a bug against the delete command, NOT the Inspector.

### Mid-edit conflict (FR-016a/b)

1. Select a clip. Focus the "name" field. Type a new name but do NOT press Enter or click away.
2. In a separate action (undo of a prior rename, say, via Cmd+Z), mutate the same field on the same clip.
3. Expected: the typed-but-uncommitted text stays in the field; other fields refresh normally.
4. Press Enter → the typed name is written, overwriting the undo's value. Last-write-wins. No prompt.

### Invalid timecode (FR-015a/b/c)

1. Select a clip. Focus the source_in field.
2. Type `not a timecode` and press Enter.
3. Expected: field keeps the bad text; red border appears; no write to the model.
4. Click to another field (blur).
5. Expected: source_in reverts to the model value; red border clears.
6. Repeat in multi-edit: select 2 clips, type bad text in one pending field → Apply button is disabled. Fix the typo → Apply becomes enabled.

### Search filter (FR-019/020/021)

1. Select a clip with full sections visible.
2. Type `name` in the search box → only sections whose name or any field's label contains "name" remain visible (e.g., File section). Others collapse.
3. Clear the search → all sections return.

### Section collapse persistence (FR-021a)

1. Launch, select a clip, collapse the Source Range section.
2. Select a different clip → Source Range is still collapsed.
3. Quit and relaunch the editor → Source Range is still collapsed on next launch.
4. Expand Source Range → relaunch → still expanded.

### Heterogeneous selection stability (FR-005a)

1. Select one clip → Inspector shows clip schema.
2. Cmd-click a sequence to add it (selection is now 1 clip + 1 sequence).
3. Expected: clip wins on tiebreak (sequence is the newly-added item, but the clip is the majority — actually here counts tie; clip was previously active and set of schemas changed — recompute: by rule, the newly-clicked is the sequence, so sequence becomes active). Verify header: "1 clip, 1 sequence — editing 1 sequence" if sequence wins, or "1 clip, 1 sequence — editing 1 clip" if clip wins.
   - Whichever wins: Cmd-click one more clip (now 2 clips + 1 sequence) → clip wins on majority; header "2 clips, 1 sequence — editing 2 clips".
   - Cmd-click to remove one clip (now 1 clip + 1 sequence) → **active schema remains clip** because the set of schemas did not change from the previous step.

---

## 6. Rollback

If the rewrite introduces a regression that blocks users:

1. `git revert <merge-commit>` of this feature branch.
2. The old `view.lua` / `adapter.lua` / etc. come back intact.
3. `layout.lua` goes back to `require("ui.inspector.view")`.
4. Re-run `make -j4` to confirm the old module still compiles (it does — nothing else in the tree depends on the new module paths).

No data format changed, so no project-file migration is needed either way.
