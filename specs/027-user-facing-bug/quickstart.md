# Quickstart — User-Facing Bug Reporting Pipeline

**Spec**: [spec.md](./spec.md) · **Plan**: [plan.md](./plan.md) · **Data model**: [data-model.md](./data-model.md) · **Contracts**: [contracts/](./contracts/)
**Date**: 2026-06-25

End-to-end smoke walkthroughs for both delivery phases. These also serve as the Phase 5 validation script.

---

## Phase A quickstart — local capture loop, no backend

**Goal**: Press F12 → fill dialog → click Submit → Finder opens a clean zip containing only `capture.json` + `slideshow.mp4`. No network round-trip. No `.jvp` content. No PNG residue.

### Preconditions

- JVE built from current branch (`cd build && make jve -j4` succeeds, no warnings).
- A project open: anything in `~/.jve/recent_projects.json` works.

### Steps

1. **Launch JVE** with the live log capturing:
   ```bash
   JVE_LOG=ui:event ./build/bin/jve.app/Contents/MacOS/jve --control-socket /tmp/joes-jve.sock 2>&1 | tee ~/iDownloads/Terminal\ Saved\ Output.txt
   ```

2. **Open a project** from the project browser. Verify in TSO: `Bug reporter initialized (background capture active)` (`src/lua/ui/layout.lua:145`).

3. **Do some editing** for ~30 seconds: cut a clip, ripple-trim, undo, redo. This populates the ring buffer with real commands and gestures.

4. **Press F12**. Submission dialog should open. Verify it shows:
   - Title field (empty, focused).
   - Description field (empty, multiline).
   - Slideshow preview strip (a few thumbnails from the last 5 minutes).
   - "Text-only report" checkbox (unchecked).
   - Submit (disabled until title is non-empty), Cancel.

5. **Try clicking Submit with empty title** — should remain disabled or surface a validation message. Confirms FR-004.

6. **Type a title** (e.g. "ripple trim drops audio"). Submit becomes enabled.

7. **Click Cancel**. Dialog closes. No zip produced. Confirms FR-009a Cancel wiring (AS #22).

8. **Press F12 again, fill title, click Submit**. Finder opens a new window showing the zip file (Phase A submit action = reveal in Finder). Verify:
   - Zip path: `tests/captures/<datestamp>-<short_uuid>/<datestamp>-<short_uuid>.zip` (or similar — exact path documented during /tasks).
   - Zip contents (inspect via `unzip -l`):
     ```
     capture.json
     slideshow.mp4
     ```
     and **NOTHING ELSE**. No `screenshots/*.png` (FR-015). No `*.db` (FR-011a).

9. **Inspect `capture.json`** (in the zip's source directory under `tests/captures/<id>/`):
   - `capture_metadata.jve_version` is a 7-char hex string (the git short SHA), NOT `"0.1.0-dev"`. Confirms FR-035.
   - `database_snapshots` field is ABSENT or null in both `before` and `after`. Confirms FR-011a.
   - `video_recording.youtube_url` field is ABSENT (legacy clutter removed).

10. **Test the text-only path**: F12 → title → check "Text-only report" → Submit. Zip should contain ONLY `capture.json` (no mp4). Confirms FR-006 + AS #8.

11. **Test capture-correctness fixes** (manual, AS #19/20/21):
    - **AS #19 (main-window targeting)**: Open any small dialog (e.g. Preferences) so it becomes the active window. Wait 5 seconds. Close dialog. Press F12, submit. Inspect any screenshot in the source directory before zipping — dimensions should match the **JVE main window** (e.g. ~3424×2070 on the dev box), NOT the dialog (~400×300). If they match the dialog, FR-013 has regressed.
    - **AS #20 (monotonic time)**: Open a project, leave JVE running idle (no user input) for at least 10 minutes by wall clock. Press F12, submit. Inspect `capture.json` — `gesture_log` should contain at most the last 5 minutes of gestures by wall clock. The current bug shows hours of accumulation. If it does, FR-014 has regressed.
    - **AS #21 (PNG cleanup)**: After submission, look in `tests/captures/<id>/`. There should be NO `screenshots/` subdirectory remaining. Just `capture.json` + `slideshow.mp4` + the zip. If `screenshots/*.png` is present, FR-015 has regressed.

12. **TSO sanity** — no `bug_reporter timer fired` or `grab_window: N ms` log lines should appear. Confirms Phase A instrumentation removal.

### Pass criteria

- All steps complete without error.
- Zip contents are exactly `capture.json` + (optionally) `slideshow.mp4` — nothing else.
- All three capture-correctness fixes verified (AS #19, #20, #21).
- TSO is quiet (no 1 Hz log spam).

### If a step fails

Phase A's failure modes map directly to FR violations. Read the FR text, write a failing test that exercises the same behavior at unit level, then fix.

---

## Phase B quickstart — backend + telemetry + triage

**Goal**: Same F12 flow as Phase A, but Submit POSTs to a live Worker; Joe sees the report in Datasette within seconds; one-click promote creates a GitHub issue.

### Preconditions

Phase A merged. Then:

- **Node + Wrangler**: `npm install -g wrangler` (Node 18+).
- **Cloudflare account**: free tier; logged in via `wrangler login`.
- **`jve-bug-bot` GitHub account**: created; added to `joeshapiro/jve-bugs` private repo with `triage` permission; PAT generated with `repo` scope.
- **Worker secrets**:
  ```bash
  cd bug-reporter-worker
  wrangler secret put GITHUB_BOT_TOKEN     # paste the bot PAT
  wrangler secret put JOE_PROMOTE_SECRET   # 32+ char random — Joe's own promotion auth
  ```
- **R2 bucket + D1 db**: created via `wrangler r2 bucket create jve-bug-reports` and `wrangler d1 create jve-bug-reports`. Bindings configured in `wrangler.toml`.
- **D1 schema applied**: `wrangler d1 execute jve-bug-reports --file=migrations/0001_initial_schema.sql`.

### Steps

1. **Start the Worker locally**:
   ```bash
   cd bug-reporter-worker
   wrangler dev
   ```
   Note the dev URL (e.g. `http://localhost:8787`). Set JVE-side endpoint env override:
   ```bash
   export JVE_BUG_REPORT_ENDPOINT=http://localhost:8787
   ```

2. **Wipe local install state** to simulate a fresh install:
   ```bash
   rm -f ~/.jve/install_id.json
   rm -rf ~/.jve/pending-reports/
   ```

3. **Launch JVE**. Verify in TSO that a **first-run consent dialog** appears BEFORE any project is opened. Confirms FR-001 + AS #1.

4. **Click Decline**. Press F12. Verify: brief notice "Bug reporting is disabled; enable in Preferences → Privacy." No dialog opens. No network traffic to `localhost:8787` (confirm via `wrangler dev` log). Confirms FR-009 + AS #14.

5. **Open Preferences → Privacy** (path stub — exact path documented during /tasks). Toggle bug reporting ON. Confirm: `/register` POST hits the Worker (visible in `wrangler dev` log). Confirms FR-002 + AS #15. Confirm: `~/.jve/install_id.json` is now present, contains `install_id`, `nonce`, `hardware_snapshot`. File perms 600 (`ls -l ~/.jve/install_id.json` shows `-rw-------`). Confirms FR-019.

6. **Inspect D1**:
   ```bash
   wrangler d1 execute jve-bug-reports --local --command "SELECT install_id, country, timezone, cpu_model, gpu_model FROM installs"
   ```
   Should show one row with country = `XX` (local dev — CF can't geolocate `localhost`), correct CPU and GPU models from your machine. Confirms FR-016 + FR-025.

7. **Relaunch JVE**. Verify in TSO that a `/heartbeat` POST hits the Worker (no `/register`). Query D1 again:
   ```bash
   wrangler d1 execute jve-bug-reports --local --command "SELECT install_id, first_seen, last_launched FROM installs"
   ```
   `last_launched > first_seen`. Confirms FR-017 + AS #3.

8. **Do some editing, press F12, fill dialog, click Submit**. Verify:
   - TSO shows confirmation "Report sent — reference #<8hex>".
   - `wrangler dev` log shows `/report` 200 response.
   - D1 query: `SELECT id, signature, user_title, cluster_id FROM reports` shows one row.
   - D1 query: `SELECT id, signature, count, gh_issue_url FROM clusters` shows one row, `count=1`, `gh_issue_url IS NULL`. **Confirms FR-027** — Worker did NOT auto-create a GH issue.

9. **Submit a second report with similar last commands and similar title**. Inspect D1:
   - `reports` table now has 2 rows.
   - `clusters` table still has 1 row with `count=2`. Confirms FR-026 dedup + AS #8.

10. **Submit a third report with very different commands**:
    - `reports` table has 3 rows.
    - `clusters` table has 2 rows. Confirms AS #10 (novel signature → new cluster, still no GH issue).

11. **Export D1 to local SQLite and run Datasette**:
    ```bash
    cd bug-reporter-worker
    wrangler d1 export jve-bug-reports --local --output=/tmp/jve-bugs.sqlite
    datasette serve /tmp/jve-bugs.sqlite --open
    ```
    Browse `http://localhost:8001/jve-bugs/clusters`. Verify: clusters sorted by count desc; each row shows signature, count, gh_issue_url (null). Confirms FR-031.

12. **Promote a cluster**:
    ```bash
    CLUSTER_ID=$(wrangler d1 execute jve-bug-reports --local --command "SELECT id FROM clusters ORDER BY count DESC LIMIT 1" --json | jq -r '.[0].results[0].id')
    curl -X POST http://localhost:8787/promote \
      -H "Authorization: Bearer $JOE_PROMOTE_SECRET" \
      -H "Content-Type: application/json" \
      -H "X-Schema-Version: 1" \
      -d "{\"cluster_id\":\"$CLUSTER_ID\"}"
    ```
    Response should be 201 with `gh_issue_url`. Open the URL: issue exists in `joeshapiro/jve-bugs` with body listing the member reports + R2 URLs. Confirms FR-029 + FR-033.

13. **Replay the promote call** with the same `cluster_id`. Response should be 200 with `created:false` and the SAME `gh_issue_url`. Confirms FR-029 idempotency.

14. **Test rate limit**: submit 21 reports in rapid succession from the same install. The 21st should return 429; the app shows "Over today's submission cap; try again tomorrow"; the report is NOT queued in `~/.jve/pending-reports/`. Confirms FR-023 + AS #7.

15. **Test offline queue**: stop `wrangler dev`. Press F12, submit. Verify: "report queued" message; `~/.jve/pending-reports/` contains one `<uuid>.payload.zip` + `<uuid>.metadata.json` pair. Restart `wrangler dev`. Relaunch JVE. Verify: pending pair is drained, report appears in D1, pair files deleted. Confirms FR-024 + AS #6.

16. **Test queue cap**: programmatically generate 51 pending pairs (or stop `wrangler dev` and submit 51 reports). Verify on the 51st: oldest pair deleted, unmissable warning surfaced to user. Confirms FR-024 cap behavior.

17. **Test suspend**: with Worker running, manually `UPDATE installs SET status='suspended' WHERE install_id=?` for the test install. Submit a report. Verify: 403 response surfaced to user as "this install is no longer authorized." Confirms FR-022 + AS #16.

18. **Test FR-019a assert**: corrupt `~/.jve/install_id.json` by editing it to be invalid JSON. Relaunch JVE. Verify: app asserts with actionable message identifying the file path and parse error, does NOT silently regenerate. Confirms FR-019a + AS #23.

19. **Test FR-021a assert**: configure JVE to point at a fake endpoint that returns HTML or empty body. Submit. Verify: app asserts with actionable message identifying the endpoint and the unparseable response. Confirms FR-021a + AS #24.

### Pass criteria

- All 19 steps complete with the expected confirmations.
- Worker created exactly ZERO GitHub issues on `/report` (verified across all submits).
- Joe's manual `/promote` created exactly the GitHub issues he promoted (one per promote call, idempotent on replay).
- D1 query `SELECT COUNT(*) FROM installs WHERE status='active'` matches the number of opted-in installs.
- Phase A pass criteria all still hold (no regression).

---

## Joe-side operational notes

### One-time setup

```bash
# 1. Cloudflare side
wrangler login
wrangler r2 bucket create jve-bug-reports
wrangler d1 create jve-bug-reports     # note the database_id printed; paste into wrangler.toml
cd bug-reporter-worker
wrangler d1 execute jve-bug-reports --file=migrations/0001_initial_schema.sql
wrangler secret put GITHUB_BOT_TOKEN
wrangler secret put JOE_PROMOTE_SECRET
wrangler deploy

# 2. GitHub side
# - Create jve-bug-bot account (use joe@shapiro.net+jve-bug-bot@gmail.com)
# - Create private repo: joeshapiro/jve-bugs
# - Invite jve-bug-bot as a collaborator with Triage role
# - Generate PAT for jve-bug-bot with repo scope
# - Paste into the GITHUB_BOT_TOKEN secret above
```

### Weekly triage workflow

```bash
# Export D1 to local SQLite
cd bug-reporter-worker
wrangler d1 export jve-bug-reports --output ~/jve-bugs-$(date +%Y%m%d).sqlite

# Browse
datasette serve ~/jve-bugs-*.sqlite --open
```

In Datasette, sort `clusters` by `count DESC`. For each cluster worth tracking:

1. Click the cluster row.
2. Click "Member reports" facet, download any of the R2 zips for full repro.
3. If you decide to track: copy the cluster_id, click the "promote" button (Option-A static page served beside Datasette), confirm.
4. GitHub issue appears in `joeshapiro/jve-bugs`.

### Secret rotation

`GITHUB_BOT_TOKEN`: regenerate the PAT in GitHub, then `wrangler secret put GITHUB_BOT_TOKEN`. No JVE side change.
`JOE_PROMOTE_SECRET`: `wrangler secret put JOE_PROMOTE_SECRET` with new value. Update the value in the triage-promote.html page's localStorage.

### Disabling Worker analytics IP capture (FR-025 op note)

By default Cloudflare Workers Analytics may capture client IP. To enforce FR-025's edge-plane corollary: in Cloudflare dashboard → Workers → jve-bug-relay → Settings → disable Analytics, OR add `analytics_engine_datasets = []` to `wrangler.toml`. The spec doesn't bind Cloudflare's logging plane (out-of-scope), but Joe may choose to do this for completeness.
