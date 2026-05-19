# Quickstart: Manual Validation Walkthrough

**Feature**: 017 | **Phase**: 1 | **Purpose**: Joe's hands-on validation script after implementation completes. Each step maps to one or more acceptance scenarios + edge cases in spec.md.

## Setup

1. Build: `make -j4` — must pass with zero luacheck warnings, all Lua tests green, all C++ tests green.
2. Open project: `~/Documents/JVE Projects/anamnesis-gold-timeline.jvp` (contains the A035 master that surfaced this refactor, plus a record sequence with audio, plus at least one record-side clip selectable for MatchFrame).
3. Stop daemons: `pgrep -x JVEEditor || rm -f "$HOME/Documents/JVE Projects/anamnesis-gold-timeline.jvp-shm"` (existing CLAUDE.md convention).
4. Launch with logs to file: `JVE_LOG=play:event,audio:event,ticks:event ./build/bin/JVEEditor > /tmp/jve_017_validation.log 2>&1 &`

## Walkthrough

### Step 1 — Two-engine ownership visible in logs (FR-001, FR-022)
- On startup, `tail /tmp/jve_017_validation.log` shows engine construction lines tagged `source:unloaded` and `record:unloaded` (two distinct engines, both alive, both unbound).
- **Pass criterion**: exactly one `source:unloaded` and one `record:unloaded` line; no extra engines.

### Step 2 — Source-tab playback emits audio (FR-021, FR-024)
- Click an audio-having master clip in the project browser.
- Verify: source viewer (top-left) loads the master. Source tab opens in the timeline panel.
- Click the Source tab. Verify the timeline view shows the master's video + audio tracks.
- Click somewhere within the timeline panel (focus moves to timeline panel area).
- Press Space.
- **Pass criteria**:
  - Audio is audible through speakers (regression fix for the bug that prompted this work).
  - Source viewer surface AND timeline panel monitor surface advance frames simultaneously, in lock-step (FR-015).
  - Log lines tagged `source:xxxxxxxx` (where `xxxxxxxx` = first-8 of master's seq id) — never `record:`.

### Step 3 — Tab switch stops source, parks viewer, falls silent (FR-022, FR-027 vicinity)
- While source is playing, click a Record tab in the timeline panel.
- **Pass criteria**:
  - Master playback stops immediately.
  - Audio device falls silent (no clicks, no pops, no residual buffer).
  - Source viewer (top-left) retains the last decoded master frame — visible but not advancing.
  - Timeline view now shows the record sequence's tracks.
  - Log: one final `source:xxxxxxxx Stop` line, then `record:yyyyyyyy` lines for park events.

### Step 4 — Record plays cleanly after the handover (FR-011, FR-012)
- With record tab displayed and engine parked, press Space.
- **Pass criteria**:
  - Record plays with audio.
  - No double-audio (source isn't still pushing samples — verifies I1, no-overlap).
  - Audio starts before any record video frame is delivered (verifies I2, audio-before-video — observable in interleaved [audio] / [video] event timestamps).

### Step 5 — Symmetric: click source viewer mid-record-play (FR-009, scenario 3)
- While record is playing, click the source viewer widget (top-left).
- Press Space.
- **Pass criteria**:
  - Record stops, audio swaps to source-engine, source plays with audio.
  - Timeline panel does NOT auto-switch tabs — record tab still displayed, record's playhead frozen at its stop frame, record's parked frame visible in the timeline view.
  - Both views of source (top-left viewer + source-tab timeline view, if user clicks source tab) would render in lock-step.

### Step 6 — MatchFrame reachable from timeline_monitor focus (FR-021)
- Click into the timeline_monitor area (top-right viewer, or whichever widget had the F-unhandled bug in TSO 2026-05-15).
- Select a clip in the record sequence (via prior selection persistence, or click first).
- Press F.
- **Pass criteria**:
  - MatchFrame command fires (verify in log: `[commands] EVENT: MatchFrame ...`).
  - The clip's master loads into source viewer at the right frame.
  - No `→ unhandled key=70` log line.

### Step 7 — Edit commands from source-side focus (FR-021a)
- Focus the source viewer (or source-tab timeline view — anything source-side).
- Source has marks set; an active record sequence exists.
- Press F9 (Insert).
- **Pass criteria**:
  - Insert lands on the active record sequence (the source-side focus did NOT redirect Insert to the master).
  - Master playback (if it was running) continues uninterrupted on source-engine.
  - Active record sequence's clips show the inserted segment.

### Step 8 — Persistence across project close+reopen (FR-008a)
- Click record tab → transport target = record.
- Close project (`Cmd+W` or File → Close).
- Reopen project.
- Press Space.
- **Pass criteria**: record plays (target was persisted as `record`).
- Repeat with source-side last interaction: target should restore to `source`.

### Step 9 — Empty source slot (FR-027a, FR-027)
- Open a fresh project (no masters loaded yet) OR close out the source-loaded master via the source viewer's clear action.
- Click the empty source viewer widget.
- Press Space.
- **Pass criteria**:
  - No crash. No silent error.
  - Either: clean no-op (preferred per FR-027), OR an actionable assert with the offending state ("Space pressed; transport target = source; source-engine has no loaded sequence").
  - `transport.get_target()` returns `"source"` (target was set by the click, even though there's nothing to play — FR-027a).

### Step 10 — Video-only master plays silently with device ownership (FR-013a)
- Load a video-only master (no audio media) into source.
- Press Space.
- **Pass criteria**:
  - Video plays. No audio is audible (correct — there's no audio to play).
  - `audio_playback._owning_engine == source_engine` during playback (verify via `--test` mode or a debug accessor).
  - Record-engine does NOT own the device while source plays — even though source produces no audio, the handover still ran (uniform protocol).

### Step 11 — `active_sequence_id` change mid-play (FR-005a)
- Record A is playing.
- Via menu or sequence-list, switch active sequence to Record B.
- **Pass criteria**:
  - Record A stops (playhead written back to A's row).
  - Record-engine rebinds to B, parks at B's saved playhead.
  - Audio falls silent. User must press Space to play B.
  - Log: `record:<A> Stop` → `record:<B> Park`.

### Step 12 — `active_sequence_id` change while parked (FR-005b)
- Record A is parked (not playing).
- Switch active sequence to Record B.
- **Pass criteria**:
  - Record-engine rebinds to B silently (A's playhead written back; B's read). No audio activity.
  - Views update to render B's parked frame; if no frame ever decoded for B, empty-state placeholder shows (FR-016 case c).

### Step 13 — Rapid tab clicking coalesces (FR-009a)
- Source playing.
- Click Record tab → Source tab → Record tab → Source tab as fast as possible.
- **Pass criteria**:
  - Final state: source tab displayed, source-engine playing (or playing wherever user landed).
  - Audio device went through at most 1–2 handover cycles, not 4. Verify by audio event log line count.
  - No torn audio.

### Step 14 — Throttled playhead writeback (FR-007a)
- Start record playback. Let it run for 10 seconds.
- Force-quit the editor (`kill -9` the process).
- Reopen project.
- **Pass criterion**: record sequence's playhead is within ~1 second of where it was when killed (NOT at the stop point from before the play session). Verifies throttled writeback survived.

## Failure-mode validation (negative tests)

### N1 — Force-trigger a mis-routed transport command (FR-010 assert)
- In `--test` mode, manually invoke `engine_record:play()` while `transport.get_target() == "source"`. Verify the editor crashes with an assert message naming the command, the target engine role, and the current transport target. (Note: this scenario requires `--test` mode because the production command-dispatch layer should never invoke this path.)

### N2 — RETIRED 2026-05-16: derived-target design has nothing to persist
- The first draft of FR-008a had `transport_target` written to `projects.settings`. The redesign (see spec.md "Architectural Premise" + `contracts/transport.md`) makes the target a pure projection of UI state — there is no persisted value to corrupt. FR-008a's "default to record" outcome is the projection's result when neither source-side condition holds.
- The original scenario (assert on corrupt JSON) is not reachable and is intentionally not implemented.

### N3 — Audio halt timeout (FR-012 assert)
- Stub `audio_playback.halt_current()` in `--test` mode to hang past 100ms. Trigger a handover. Verify editor asserts at 100ms with `halt_current: timeout` and the source/target roles + elapsed time.

## Done criteria

All 14 walkthrough steps pass without manual workarounds. All 3 negative tests crash with actionable asserts (NOT silent failures). The TSO bugs (FR-024 source-tab silent, FR-021 F-unhandled, FR-022 untagged ticks) are demonstrably resolved.
