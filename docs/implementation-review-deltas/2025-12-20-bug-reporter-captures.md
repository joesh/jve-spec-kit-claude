# 2025-12-20 Bug Reporter Capture Outputs

## Summary
- Documented default bug reporter capture outputs: JSON + screenshots under `tests/captures/capture-<datestamp>-<id>/` and DB snapshot `tests/captures/bug-<datestamp>.db`.
- Noted `metadata.output_dir` override for capture export location.

## Baseline Impact
- `docs/implementation-review-baseline/01-REPO-OVERVIEW.md` → **Bug Reporter** section updated with output locations.

## Baseline Insufficiency
- Baseline described the bug reporter flow but did not record where captures are written.
- Confirmed in code: `CaptureManager.export_capture` defaults `output_dir` to `tests/captures` and writes DB snapshots (`src/lua/bug_reporter/capture_manager.lua`), while `JsonExporter.export` creates per-capture folders and `capture.json` + `screenshots/` (`src/lua/bug_reporter/json_exporter.lua`).

## Risks / Test Gaps
- None identified; documentation-only update.
