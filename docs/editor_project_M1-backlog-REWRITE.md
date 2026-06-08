# Editor Project v1.2 — M1 Backlog (Editor-First Rewrite)

> **Purpose of M1:** Ship a usable **editor skeleton** that demonstrates the model–UI loop. No media decoding yet. The user can browse assets/sequences, place/edit clips on a timeline, select them, and edit properties in a unified Inspector/Metadata panel. Project saves/loads as a single file.

## Goals
- One **project data model** (SQLite) that persists and reloads.
- Three core panels wired to that model: **Project Browser**, **Timeline**, **Inspector/Metadata (tabbed)**.
- **Viewers visible** (Record/Timeline Viewer and Source Viewer), even if they don’t play video yet.
- **Editing commands**: create, delete, split (add edit), ripple delete, ripple trim, roll; plus **clip selection** behavior.
- One-file **save/load** that’s safe to copy.

![Overall Editor UI](https://raw.githubusercontent.com/joesh/editor-design-examples/a20e830d91a9663263b9682ceb64a1fbebf22151/images/editor/resolve.png)

---

## Epic A — Project Data Model & Persistence (authoritative)
**Context:** The single source of truth the panels manipulate. Must be simple, deterministic, and durable.

- **Story A.1 — Minimal schema online**
  - Tables: `projects, sequences, tracks, clips, props, metadata, cmd_log, snapshots` (as per spec v1.2).
  - Ticks are integers; FKs enforced.
  - **Acceptance:** Creating a sequence and adding clips persists rows; FKs pass; integer tick math only.

- **Story A.2 — Save/Load (one file)**
  - Project saves atomically; reload restores state exactly.
  - **Acceptance:** Create → Save → Quit → Reopen shows identical timeline and properties.

- **Story A.3 — Command surface & determinism**
  - `apply_command(cmd,args) → delta|error`; post-state deterministic; inverse deltas recorded.
  - **Acceptance:** A scripted sequence of commands replays to identical post-hash on reopen.

---

## Epic B — Project Browser Panel
**Context:** Where users see/manage assets and sequences; selecting here drives the rest of the UI.

- **Story B.1 — Assets & sequences list**
  - List/tree of media references and sequences.
  - **Acceptance:** Selecting a sequence focuses it in Timeline; selecting a clip focuses it in Inspector.

- **Story B.2 — Create sequence & add clip references**
  - Create empty sequence; create clip references (placeholder media OK).
  - **Acceptance:** New sequence appears in list; adding a clip reference makes it available to the Timeline.

- **Story B.3 — Rename & delete safeguards**
  - Rename items; prevent deleting media that’s referenced.
  - **Acceptance:** Attempting to delete referenced media yields error with user hint.

---

## Epic C — Timeline Panel (tracks, selection, feedback)
**Context:** Primary editing surface. Must reflect model state and selection, and show clear feedback.

- **Story C.1 — Tracks & layout**
  - Display a sequence with multiple V/A tracks; show clip blocks on tracks.
  - **Acceptance:** Adding clips to different tracks renders correctly.

- **Story C.2 — Clip selection**
  - Click selects clip; Shift extends; Cmd toggles; range select by drag.
  - **Acceptance:** Selection model matches rules; Inspector reflects current selection.

- **Story C.3 — Snapping toggle & guides**
  - Global snap toggle with visual guide; Option bypasses snap.
  - **Acceptance:** Drag near edit point snaps when on; doesn’t when off.

![Premiere Timeline](https://raw.githubusercontent.com/joesh/editor-design-examples/6b79f5e3ca0dfa9b1ff8fbc104d1b7ce3f3b0ce6/images/timeline/premiere-timeline.png)
![Resolve Timeline](https://raw.githubusercontent.com/joesh/editor-design-examples/6b79f5e3ca0dfa9b1ff8fbc104d1b7ce3f3b0ce6/images/timeline/resolve-timeline.png)

---

## Epic D — Inspector / Metadata Panel (Unified, tabbed)
**Context:** One panel with two tabs: **Inspector** (properties) and **Metadata** (search & tagging). It is the bridge to the data model.

- **Story D.1 — Tabbed UI**
  - Two tabs: Inspector | Metadata; state persists when switching.
  - **Acceptance:** Switching tabs doesn’t lose current selection or typed edits.

- **Story D.2 — Inspector mode (edit properties)**
  - Schema-driven fields; inline validation/hints; per-property undo.
  - **Acceptance:** Editing a property updates the clip immediately; invalid input shows user hint; per-property undo works.

- **Story D.3 — Metadata mode (filter & tag)**
  - Faceted search; apply/remove tags/labels.
  - **Acceptance:** Filters reduce result set deterministically; tags persist and reflect in Inspector.

![Resolve Metadata Category Chooser](https://raw.githubusercontent.com/joesh/editor-design-examples/a20e830d91a9663263b9682ceb64a1fbebf22151/images/inspector%2Bmetadata/resolve%20metadata%20category%20chooser.png)
![Resolve Properties Video](https://raw.githubusercontent.com/joesh/editor-design-examples/a20e830d91a9663263b9682ceb64a1fbebf22151/images/inspector%2Bmetadata/resolve%20properties%20video.png)
![Resolve Properties Audio](https://raw.githubusercontent.com/joesh/editor-design-examples/a20e830d91a9663263b9682ceb64a1fbebf22151/images/inspector%2Bmetadata/resolve%20properties%20audio.png)
![Resolve Metadata Scene](https://raw.githubusercontent.com/joesh/editor-design-examples/a20e830d91a9663263b9682ceb64a1fbebf22151/images/inspector%2Bmetadata/resolve%20metadata%20scene%20top.png)

---

## Epic E — Viewers (Visible, non-playing)
**Context:** Establish the spatial layout and wiring for later playback; for M1 they reflect selection/time only.

- **Story E.1 — Record/Timeline Viewer**
  - Shows current sequence frame/timecode overlays, safe guides; responds to playhead changes.
  - **Acceptance:** Moving playhead in Timeline updates the Record viewer overlays.

- **Story E.2 — Source Viewer**
  - Shows selected clip’s in/out points and timecode overlay.
  - **Acceptance:** Selecting a clip in Project Browser or Timeline shows its I/O range overlays.

---

## Epic F — Editing Commands (create/delete/split/ripple/roll)
**Context:** Minimum set of verbs that let the user shape the timeline. All go through the command API and update the model + panels.

- **Story F.1 — Create & delete clips on timeline**
  - Place clip refs from Browser onto Timeline; delete removes from track.
  - **Acceptance:** Create/delete updates rows and UI; undo/redo restores exact state.

- **Story F.2 — Split (Add Edit)**
  - Blade at playhead across targeted tracks.
  - **Acceptance:** New clip boundaries at the correct tick; inverse delta merges them on undo.

- **Story F.3 — Ripple delete & ripple trim (head/tail)**
  - Close gaps on delete; trims ripple downstream on targeted tracks; **ripple outranks link** (out-of-sync allowed).
  - **Acceptance:** Downstream items shift appropriately; out-of-sync badge appears when link overridden.

- **Story F.4 — Roll**
  - Adjust boundary between adjacent clips without changing total duration.
  - **Acceptance:** One edge moves forward while the neighbor’s edge moves backward by equal ticks; no illegal overlaps.

---

## Cross-Epic Acceptance (what “done” looks like)
- Start app → Project Browser + Timeline + Inspector/Metadata + Viewers are visible.
- Create a sequence; add clip refs; place clips on the timeline.
- Select a clip → Inspector shows properties; edit a property → Timeline reflects (e.g., label/color/enable).
- Perform split/ripple/roll/delete → Timeline updates and badges show as needed; Inspector updates selection.
- Save → Quit → Reopen → identical state and selection restored.
