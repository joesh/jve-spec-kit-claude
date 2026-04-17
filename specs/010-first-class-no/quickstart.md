# Quickstart — Manual Validation

Run these scenarios against a fresh `./build/bin/JVEEditor` after implementation. Each maps to an acceptance scenario (AS) or functional requirement (FR) in [spec.md](./spec.md).

## Pre-flight
```bash
pgrep -x JVEEditor || rm -f "$HOME/Documents/JVE Projects/Untitled Project.jvp-shm"
cd /Users/joe/Local/jve-spec-kit-claude
make -j4                                    # must be green: luacheck + all tests
./build/bin/JVEEditor
```

## 1. Close-last-tab enters blank state (AS-1, FR-001, FR-002, FR-003)

1. From the welcome screen, open any multi-sequence project.
2. Close every tab except one. Timeline still displays that one sequence.
3. Click the close (X) button on the final tab.
4. **Expect**: the tab disappears; the timeline panel goes blank (dark empty area, no ghost clips, no timecode ruler populated). Window stays open; project browser still shows the sequence list.
5. Quit the editor (⌘Q).
6. Relaunch; open the same project from the welcome screen's recent list.
7. **Expect**: the project opens in the blank state — no tab automatically recreated (AS-3, FR-004).

## 2. Drop-to-blank creates new sequence (AS-2, FR-011)

1. With the project in the blank state (from step 1), expand a bin in the project browser containing several media clips.
2. Select three media clips (shift-click).
3. Drag them from the browser onto the timeline area.
4. **Expect**:
   - A new sequence is created.
   - Its name is `<first-clip-filename> (+2 more)`.
   - Its fps + resolution match the first dropped clip's metadata (confirm by inspecting the sequence's properties dialog).
   - All three clips are placed on the timeline in drop order.
   - The new tab becomes active.

## 3. Drop an existing sequence onto blank timeline (AS-2 variant, FR-011)

1. Return to the blank state (close the tab created in step 2).
2. Drag an existing sequence from the project browser onto the timeline.
3. **Expect**: that sequence opens as a tab and becomes active. **No new sequence** was created.

## 4. DRP import — no-tab-metadata (AS-5, FR-006)

1. Import `tests/fixtures/resolve/anamnesis-gold-timeline-no-tabs.drp` (create this fixture if it doesn't exist by stripping `SequenceTabsData` and emptying `TimelineHandleVec` from an existing DRP — see test note below).
2. **Expect**: import succeeds; the resulting project opens in the blank state. Project browser lists the sequences; no tab is auto-selected.

*Note*: if this fixture doesn't exist in the repo, the pure-Lua `test_drp_resolver_asserts_malformed.lua` covers Case 1 behavior; manual validation of this scenario is optional.

## 5. DRP import — malformed TimelineHandleVec (FR-007)

1. Attempt to import a DRP with `CurrentTimelineIndex` out of range (fabricate by editing `project.xml` inside the archive).
2. **Expect**: the import fails with a visible error dialog naming `CurrentTimelineIndex` and the range. No partial project is created.

*Automated equivalent*: `tests/test_drp_resolver_asserts_malformed.lua`.

## 6. Delete-last-active-sequence cascades to blank (FR-013)

1. Open a project with exactly one sequence (or delete all other sequences first).
2. With that sequence as the active tab, right-click it in the project browser → Delete.
3. Confirm the delete.
4. **Expect**: the tab closes; timeline goes blank; the sequence is gone from the browser.
5. Press ⌘Z (undo).
6. **Expect**: the sequence returns to the browser AND its tab re-opens as the active tab with its prior edit history intact (FR-014 for non-active equivalent).

## 7. Shortcuts disabled in blank state (FR-008)

1. In the blank state, open the Edit menu.
2. **Expect**: Cut / Copy / Paste / Delete / Mark In / Mark Out / Play / JKL are greyed out.
3. Press the J, K, L keys.
4. **Expect**: silent no-op; no error in the status area; no console assert.

## 8. Drag from browser while blank creates sequence (FR-011 + spec edge cases)

Tested as part of step 2 above. Variants to spot-check:
- Drag a single clip → new sequence named exactly after the clip (no "(+N more)" suffix).
- Drag a whole bin → new sequence contains every clip recursively inside, named `<first-clip> (+N more)`.
- Drag a mix of sequences + clips → sequences open as tabs; clips form one new sequence; last-activated tab is active.

## 9. Undo in blank state (FR-012)

1. In the blank state (post step 1), in the project browser, right-click → New Sequence. Confirm.
2. Don't open it; close it again via browser delete.
3. The project is back in the blank state, but an undo stack exists.
4. Press ⌘Z.
5. **Expect**: the sequence is restored in the browser. Timeline remains blank until the user opens the restored sequence.

## Success criteria
All nine scenarios pass. No console asserts or silent fallbacks. `make -j4` stays green.
