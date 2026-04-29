# Quickstart: Verify Two-Phase Project Switch

**Feature**: 014-two-phase-project · **Phase 1** · **Date**: 2026-04-29

This is the manual-repro path for FR-011 (the original failing scenario must produce zero `assert_project_exists` lines after the feature ships).

## Prerequisites

- Repo at branch `014-two-phase-project` with the feature implemented.
- A clean build: `make -j4` (zero luacheck warnings, all tests pass).
- The fixture DRP: `tests/fixtures/resolve/anamnesis-gold-timeline.drp`.

## Steps

### 1. Reset state

```bash
# Kill any running editor
pkill -x JVEEditor || true

# Remove the existing project DB so we start clean
rm -f "$HOME/Documents/JVE Projects/anamnesis-gold-timeline.jvp"
rm -f "$HOME/Documents/JVE Projects/anamnesis-gold-timeline.jvp-shm"
rm -f "$HOME/Documents/JVE Projects/anamnesis-gold-timeline.jvp-wal"

# Optional: clear the TSO log so the post-test grep is clean
> "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Downloads/Terminal Saved Output.txt"
```

### 2. Launch and import

```bash
./build/bin/JVEEditor
```

In the editor:

1. **File > Open** (or **File > Import** depending on how DRP import is wired).
2. Select `tests/fixtures/resolve/anamnesis-gold-timeline.drp`.
3. Conversion dialog appears; accept default destination path.
4. Wait for "Conversion complete" (no warnings expected on a successful re-import).
5. Editor opens with the GOLD timeline active.

### 3. Interact with the timeline

The original failure pattern was repeated single-shot-timer asserts firing on user interaction. Reproduce the interaction load:

1. Arrow ←/→ through 20–30 frames near a clip boundary (e.g. REC `01:36:49:17`, the GOLD master clip).
2. Press **J/K/L** for play/pause cycles, ~5 seconds of playback.
3. Click on different clips to change selection — at least 5 different clips.
4. Open a different project from **File > Open Recent**, then come back via **Open Recent** again. (This exercises a project switch with pending state from the GOLD timeline.)

### 4. Verify TSO is clean

```bash
TSO="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Downloads/Terminal Saved Output.txt"
grep -c "assert_project_exists.*Stale project_id after project switch" "$TSO"
# Expected output: 0
```

### 5. Verify pre-switch flush worked

The pre-switch flush should have written `media_status` entries for the GOLD project to the GOLD project's DB before the switch. Verify:

```bash
sqlite3 "$HOME/Documents/JVE Projects/anamnesis-gold-timeline.jvp" \
  "SELECT json_extract(settings, '$.media_status') IS NOT NULL FROM projects;"
# Expected output: 1   (or a populated map; empty is also acceptable if no probes ran)
```

### 6. Verify the audit catalog is committed

```bash
test -f /Users/joe/Local/jve-spec-kit-claude/specs/014-two-phase-project/handler_audit.md && echo "OK"
# Expected: OK
```

The catalog must list every `Signals.connect("project_changed", ...)` site with classification and migration status. No row may have classification ∈ {must-cancel, must-flush} AND migration_status = none-needed.

## Expected outcome

- TSO has zero `assert_project_exists ... Stale project_id` lines (FR-011).
- TSO may still contain known-noise warnings (PeakGenerator decode failures, FieldsBlob WARNs) — out of scope for this feature.
- Editor stays responsive. No frozen UI > 1 second on any project switch.
- In-flight GOLD probe results either landed in the GOLD DB before the switch, or were discarded with a logged drop count. Never silently lost.

## Failure modes & where to look

- **`assert_project_exists` still fires**: a deferred-work site was missed in the audit. Grep `qt_create_single_shot_timer` for callbacks that touch DB; verify each is either cancelled in `project_will_change` or uses `assert_project_id_is_live`.
- **Editor hangs on project switch > 1s**: a worker isn't honoring the cancel flag. Check `media_status.cancel_background_probe` (or whichever worker is involved) — it should set the flag, the worker should observe it at write boundaries, drain should complete fast.
- **Stack traces not appearing in TSO for callback errors**: the C++ bridge update wasn't applied or build is stale. Rebuild with `make -j4` and re-run.
- **Persisted media_status missing from outgoing DB after switch**: the `project_will_change` flush ran on the wrong DB connection. Verify the emit point is BEFORE `database.init(new_path)` in `core/project_open.lua`.

## Automated equivalent

An integration test at `tests/integration/test_anamnesis_reimport_no_asserts.lua` automates steps 1–5 via `--test` mode. The manual quickstart is for sanity-checking after large changes; the integration test runs in CI on every commit.
