# Feature Specification: User-Facing Bug Reporting Pipeline

**Feature Branch**: `027-user-facing-bug`
**Created**: 2026-06-24
**Status**: Draft (revised after skeptical review 2026-06-24)
**Input**: User-facing bug reporting pipeline with private GitHub backend, telemetry, and Joe-side triage.

---

## User Scenarios & Testing *(mandatory)*

### Primary User Story

A JVE user encounters a bug. They press F12. The app captures the last few minutes of activity (gestures, commands, log output, a slideshow of screenshots) and presents a small dialog asking for a short title, a description, and showing a preview of exactly what will be sent. They click Submit. Within seconds the report leaves their machine. They see a confirmation with a short reference id and dismiss the dialog. The user never creates an account, never installs a CLI tool, never types a credential, and never sees the name "GitHub."

Joe periodically opens his triage UI and sees a list of every report ever submitted, automatically grouped into clusters by likely-same-root-cause, sorted by cluster size. He sees country, JVE version, hardware, and the last few commands the user ran for each cluster. He picks the largest cluster and clicks **"promote to tracked bug"** — at that point (and only then) a GitHub issue is created in his private repo, linking back to every raw report that contributed to the cluster.

Joe also wants install-count and weekly-launch-count signal. Every JVE launch silently sends a heartbeat that updates the install's last-launched timestamp.

### Acceptance Scenarios

1. **Given** a freshly installed JVE on a machine with no prior JVE state, **When** the user launches the app, **Then** a first-run consent dialog appears explaining what is collected, with Accept and Decline buttons; nothing is sent to the backend until the user clicks Accept.

2. **Given** the user has accepted telemetry, **When** the app finishes launching, **Then** an anonymous registration is sent containing only: a locally generated install id, JVE version, OS, CPU, GPU, RAM, and (resolved at the backend from the connection, not sent by the app) country and timezone. No username, hostname, or IP address is stored in app-controlled persistence.

3. **Given** a registered install, **When** the user launches JVE on any subsequent occasion, **Then** a lightweight heartbeat updates the install's `last_launched` timestamp.

4. **Given** a registered install, **When** the user presses F12, **Then** a submission dialog opens showing a title field, a description field, a slideshow preview, a list of telemetry fields about to ship, a list of captured user-path strings, a "text-only report" checkbox, and Submit / Cancel buttons.

5. **Given** the user has filled in a title and clicks Submit, **When** the network is reachable, **Then** the report is delivered to the backend within a few seconds and the user sees a confirmation with a short reference id.

6. **Given** the user has filled in a title and clicks Submit, **When** the network is unreachable or the backend returns a 5xx/transport error, **Then** the report is queued locally and automatically retried on the next launch with network connectivity, with no data loss.

7. **Given** the user has filled in a title and clicks Submit, **When** the backend returns a rate-limit response (per-install daily cap exceeded), **Then** the report is **discarded** (not queued) and the user sees an unambiguous message stating "Over today's submission cap; try again tomorrow."

8. **Given** the user enables the "text-only report" checkbox, **When** they click Submit, **Then** the slideshow video is excluded from the payload but the capture metadata, gesture log, command log, and log output are still sent.

9. **Given** a report arrives at the backend, **When** its signature matches a signature already seen, **Then** the existing cluster's count is incremented and the raw report is linked to that cluster. **No GitHub issue is created or modified by the backend at this point.**

10. **Given** a report arrives at the backend, **When** its signature is novel, **Then** a new cluster is created with `count = 1`. **No GitHub issue is created by the backend.** Promotion is Joe's explicit action.

11. **Given** Joe opens the triage UI, **When** he sorts by cluster size, **Then** he sees clusters ranked by frequency with country, JVE version, hardware, last commands, and user description visible for each.

12. **Given** Joe selects a cluster in the triage UI and clicks "promote to tracked bug," **When** the action completes, **Then** a tracked GitHub issue is created (or, if `clusters.gh_issue_url` is already set, updated) and every raw report belonging to the cluster is linked back to that tracked bug.

13. **Given** a cluster has been promoted, **When** additional reports arrive matching its signature, **Then** the cluster `count` is bumped and every Nth new report (configurable; default N=10) triggers a comment on the GitHub issue showing the updated count and the most recent report id.

14. **Given** a user declines telemetry at first launch, **When** they press F12, **Then** the submission dialog does not open; instead a brief notice explains that bug reporting is disabled and points to the Preferences toggle that re-enables it. No registration, heartbeat, or report is ever sent while disabled.

15. **Given** a user previously declined telemetry, **When** the user later enables telemetry via Preferences, **Then** the next backend interaction performs `/register` first if no install record exists, before any `/heartbeat` or `/report`.

16. **Given** an install id has been flagged as `suspended` in the backend, **When** the app from that install attempts to submit a report or heartbeat, **Then** the backend rejects the request and the app surfaces a clear "this install is no longer authorized" message; the rejection requires no JVE rebuild to take effect.

17. **Given** an install submits more than the per-install daily limit, **When** the next submission within the same day is attempted, **Then** the backend rejects it with a rate-limit response and the app discards the submission (see AS #7).

18. **Given** a user upgrades to a new JVE version, **When** the new version first launches, **Then** the hardware snapshot is re-queried and the backend's stored hardware fields are updated if changed.

19. **Given** the user has any dialog or floating panel open with focus, **When** background capture fires, **Then** the captured screenshot shows the JVE main window — not the focused dialog or panel.

20. **Given** JVE has been running idle for 30 minutes of wall time, **When** the capture is exported, **Then** the buffer contains only the last 5 minutes by wall clock (not by accumulated CPU time).

21. **Given** a capture has just been exported with a slideshow video, **When** export completes, **Then** no per-frame PNG files remain on disk under that capture directory.

22. **Given** the submission dialog is showing, **When** the user clicks any of Submit, Cancel, or the text-only checkbox, **Then** the clicked control invokes its stated action (submit, dismiss without sending, toggle text-only inclusion).

23. **Given** the local `install_id.json` file exists but is malformed (not valid JSON, missing required fields, or unreadable), **When** the app starts up, **Then** the app asserts with an actionable error identifying the file path and the parse failure. The app does NOT silently regenerate, fall back, or skip telemetry.

24. **Given** the Worker returns a malformed or non-JSON response, **When** the app receives it, **Then** the asynchronous transport callback fires exactly once with `ok=false, code="bad_response"` carrying endpoint + parse reason, AND the app emits a `log.error` naming the endpoint, HTTP status, and reason. The app does NOT silently treat the response as success or generic failure, AND the callback chain (telemetry / F12 submit / queue drain) never hangs waiting on a callback that never fires.

25. **Given** an attacker repeatedly POSTs to `/register` from a single IP with random install ids, **When** the attempts exceed a per-IP threshold (e.g. 5/hour), **Then** the Worker rejects further `/register` attempts from that IP for the remainder of the window.

26. **Given** an attacker POSTs `/register` with an install id that already exists in D1, **When** the Worker validates the request, **Then** the request is rejected (no overwrite, no new nonce issued). An existing install never loses its nonce by replay.

### Edge Cases

- User wipes the `~/.jve` directory. The next launch behaves like a fresh install: new install id, new consent dialog. Previously submitted reports remain in the backend under the old install id; the user has no way to claim them. Acceptable.
- User runs JVE on a machine with no network. First launch: consent dialog appears; clicking Accept queues a pending registration; no F12 capture can complete the round-trip until network is restored. Pending registrations are retried with the same backoff schedule as pending reports.
- Capture metadata exceeds the payload ceiling (FR-024a). The app clamps by dropping oldest log entries first; if still over ceiling, drops oldest commands; if still over ceiling, refuses to submit and surfaces an error to the user.
- User presses F12 repeatedly. The app throttles the dialog to one open instance at a time; backend rate-limit caps daily volume per install.
- A report contains genuinely sensitive content in the user-typed description or in captured log strings. The privacy preview is the user's last line of defense — the app MUST display every string that is about to ship before the user clicks Submit.
- The backend is unreachable for extended periods. Pending-report queue grows. The app caps queue at 50 reports; past that, the oldest pending report is dropped with a user-visible warning (not a silent log line) each time a drop occurs.
- A cluster signature collision occurs (two genuinely different bugs hash to the same signature). Joe's triage UI is the recovery mechanism; he can manually split a cluster into multiple tracked bugs (FR-034).
- Joe's promote-to-tracked-bug action completes the GitHub API call but the response is lost in transit. The retry of the promote action MUST be idempotent keyed by `cluster_id`: it checks `clusters.gh_issue_url` first and only creates the GH issue if that field is null.
- A user restores their `~/.jve` directory from backup onto a new machine. The same `install_id` will appear from two distinct hardware profiles. v1 accepts this — the backend simply overwrites hardware fields on the latest heartbeat. Joe can detect anomalies in triage if needed.
- The user is on Apple Silicon and `gpu_memory_mb` is a fraction of system memory. The schema records both numbers and a `unified_memory` flag so the relationship is queryable.

---

## Requirements *(mandatory)*

### Functional Requirements — User-facing

- **FR-001**: System MUST display a first-run consent dialog before any data leaves the user's machine. The dialog MUST list every category of data collected (install id, version, OS, CPU, GPU, RAM, country) and MUST state that no usernames, hostnames, or IP addresses are stored in app-controlled persistence.
- **FR-002**: System MUST provide a Preferences toggle that disables all backend communication (registration, heartbeat, submission) and MUST honor it immediately without restart. When the toggle is flipped from disabled to enabled and no install record exists yet, the next backend interaction MUST perform `/register` first.
- **FR-003**: Users MUST be able to invoke bug submission with a single keyboard shortcut (F12 by default, rebindable).
- **FR-004**: The submission dialog MUST require a non-empty title before allowing Submit.
- **FR-005**: The submission dialog MUST display a privacy preview showing (a) the slideshow strip, (b) every captured user-path string about to ship, and (c) the telemetry fields about to ship.
- **FR-006**: The submission dialog MUST provide a "text-only report" option that excludes the slideshow video from the payload while preserving all other capture metadata.
- **FR-007**: On successful Submit, the user MUST receive an unambiguous confirmation that includes a short reference id. On any failure, the user MUST receive an unambiguous error identifying the failure class (network, rate-limit, rejected, malformed response).
- **FR-008**: Users MUST never see, hear, or be required to interact with GitHub, OAuth, accounts, tokens, or any third-party service as part of submission.
- **FR-009**: If the user declines telemetry, F12 MUST present a brief, non-blocking notice explaining that bug reporting is disabled and how to re-enable it, then dismiss.
- **FR-009a**: Every interactive control in the submission dialog (Submit, Cancel, text-only checkbox, and any preview-area buttons) MUST invoke its stated action when activated. A dialog with non-functional controls fails this spec.
- **FR-009b**: The submission flow (capture → slideshow build → upload) MUST NOT block the GUI thread. From Submit-click to dialog confirmation the UI MUST remain responsive (move, resize, repaint) and the Submit button MUST visibly transition through Sending → Sent/Failed states. Synchronous capture is permitted ONLY on the crash-capture path where the event loop is being torn down.

### Functional Requirements — Capture

- **FR-010**: System MUST capture, in memory, a continuous ring buffer of recent gestures, commands, log output, and screenshots while JVE is running. The buffer caps:
  - Gestures: 200 entries
  - Commands: 200 entries
  - Log output: 1000 entries
  - Screenshots: 300 entries (sufficient for 5 minutes at 1 Hz)
  - All streams additionally capped at 5 minutes wall-clock age.
- **FR-010a**: Screenshot capture cadence is 1 Hz while JVE is in foreground. Capture is **suspended during transport playback** (engine reports `is_playing()`) to avoid main-thread stall on Metal surface readback. Capture resumes when playback stops.
- **FR-011**: System MUST package each report as a single artifact containing the capture metadata file (JSON) and, unless the user opted into text-only, the slideshow video. Raw screenshot frames MUST NOT be included.
- **FR-011a**: The payload artifact MUST NOT include the project `.jvp` database file or any portion of its content. The `database_snapshots` field present in current `capture.json` MUST be removed or zeroed before upload.
- **FR-012**: System MUST compute a stable cluster signature for each report. Signature inputs are:
  - The last 3 command names, **excluding any trailing `ReportBug` entry** (the F12 trigger itself MUST NOT dominate the signature space)
  - For automatic captures: the normalized error string (paths, hex ids, timestamps, line numbers stripped)
  - For user-submitted captures: the normalized user title (first 5 tokens, lowercased, alphanumeric-only)
  - Signature MUST NOT include the build identifier (`jve_sha`). Build identifier is preserved as a separate report column so Joe can filter by build during triage, but two reports of the same root cause from different builds MUST land in the same cluster.
- **FR-013**: System MUST capture the user's screen by targeting the JVE main window specifically — not whichever window happens to be focused.
- **FR-014**: System MUST use a monotonic wall-clock time source for ring-buffer expiry, so that buffers age out in real elapsed time, not in process-CPU time.
- **FR-015**: System MUST delete intermediate per-frame screenshot files once the slideshow video has been produced.

### Functional Requirements — Telemetry & registration

- **FR-016**: On first launch with consent, System MUST generate a locally-unique install id and register it with the backend. Registration MUST include build identifier, OS, OS version, architecture, CPU model, CPU core counts, system memory, GPU vendor / model / memory / API, and unified-memory flag.
- **FR-017**: On every subsequent launch, System MUST send a lightweight heartbeat that updates the install's `last_launched` timestamp at the backend. (Metric name: weekly launches, not weekly active users. No periodic in-session heartbeat in v1.)
- **FR-018**: On each launch following a JVE build-identifier change, System MUST re-query the hardware snapshot and include any changed fields in that launch's heartbeat (or the next report).
- **FR-019**: System MUST persist the install id and the per-install authentication secret with file permissions that restrict access to the owning user.
- **FR-019a**: If the persisted install-id file exists but cannot be parsed or is missing required fields, System MUST assert with an actionable error identifying the file path and the parse failure. System MUST NOT silently regenerate the file or skip telemetry.
- **FR-020**: System MUST NOT collect or transmit usernames, hostnames, MAC addresses, IP addresses, file system contents outside the capture, list of installed software, or any other identifying data beyond what is enumerated in FR-001 and FR-016.

### Functional Requirements — Transport

- **FR-021**: System MUST authenticate every submission and heartbeat using a per-install authentication secret obtained at registration, such that compromising one install's secret cannot enable submitting on behalf of any other install.
- **FR-021a**: If the backend returns a malformed or non-JSON response, System MUST surface this to the caller as a classified failure (`ok=false, code="bad_response"`) carrying the endpoint and a `reason` summarising the parse error, AND System MUST emit a loud (`log.error`) message naming the endpoint, HTTP status, and reason. The asynchronous transport callback MUST always fire exactly once so callers (telemetry, F12 submit, pending-queue drain) never hang. System MUST NOT silently treat malformed responses as success or generic failure. (Originally specified as `assert`; rewritten when transport became async to preserve loud-failure spirit without hanging the callback chain — see todo_027_fr021a_async_classified_result.md for rationale.)
- **FR-022**: System MUST be able to revoke an individual install's authorization at the backend (by setting `installs.status = 'suspended'` in D1) without requiring a JVE rebuild or redistribution.
- **FR-023**: System MUST cap per-install submission rate at the backend (no more than twenty reports per install per twenty-four-hour window). Submissions over the cap are rejected with a rate-limit response code distinct from transport errors.
- **FR-024**: System MUST queue submissions locally on **transport failure only** (network unreachable, 5xx, malformed response) and retry on subsequent launches. Rate-limit rejections (FR-023) MUST NOT be queued — they are discarded with a user-visible message. The local queue is size-capped at **50 reports**; past that, oldest entries are discarded and an unmissable warning (modal or persistent banner, not a log line) is surfaced to the user. **Drain-time semantics differ from initial-submit semantics**: when a pending report is drained at app launch (not an active user action), the user has typically moved on; a 200 response is silent (log-only), a 429 response on drain causes the pair to be discarded with a log entry only (no modal — user is not in a submit context), and a transport-error leaves the pair in place silently. Drain-time failures DO surface visibly only when the queue subsequently hits its 50-entry cap (which IS user-visible per the cap rule above).
- **FR-024a**: Each outbound payload MUST be clamped to a 10 MB hard ceiling. If raw capture exceeds the ceiling, the app MUST drop oldest log entries first, then oldest commands. If the payload is still over ceiling after dropping everything but the slideshow + most-recent commands + user description, the app MUST refuse to submit and surface an error to the user.

### Functional Requirements — Backend

- **FR-025**: Backend MUST resolve country and timezone from the connection metadata (not from app-supplied data) and MUST NOT store the requesting IP address in any app-controlled persistence (D1, R2, KV). Edge-level access logs at the Cloudflare account level are out of scope for this requirement; Joe is responsible for disabling Worker analytics IP capture at the account level if desired.
- **FR-026**: Backend MUST deduplicate reports by cluster signature, incrementing an existing cluster's count rather than creating a new cluster row when the signature matches.
- **FR-027**: Backend MUST NOT auto-create GitHub issues. Cluster creation in D1 is automatic on first signature occurrence; **promotion to a GitHub issue is exclusively a Joe-initiated action via the triage UI** (FR-033). At creation time, `clusters.gh_issue_url` MUST be null.
- **FR-027a**: After a cluster has been promoted (`clusters.gh_issue_url` is non-null), the Worker MUST post a comment to that GitHub issue every Nth new report bumping the cluster's count (default N=10), citing the new count and the most recent report id. The N threshold is configurable in Worker config without code change.
- **FR-028**: Backend MUST persist each raw report's payload artifact in object storage and a row in the metadata database, linked to its cluster.
- **FR-029**: Joe's promote-to-tracked-bug action MUST be idempotent keyed by `cluster_id`: implementation MUST check `clusters.gh_issue_url` first and only create the GitHub issue if that field is null. If the Worker's GitHub API call succeeds but the response is lost, the next promote retry MUST detect the existing issue (e.g. via a search by cluster id label) and reconcile rather than creating a duplicate.
- **FR-030**: Backend MUST run at no monetary cost up to and including the documented volume target (five hundred lifetime reports across one hundred active installs).
- **FR-030a**: `/register` MUST refuse to issue a new nonce for an install id that already exists in `installs`. An existing install can re-register only via Joe's manual revocation + the app's natural fresh-install path.
- **FR-030b**: `/register` MUST be rate-limited per source IP at the Cloudflare edge (default ceiling: 5 registrations per hour per IP) to bound abuse of the unauthenticated endpoint.
- **FR-030c**: Every payload sent over the wire MUST carry a `schema_version` field (capture-format and metadata-envelope versions are distinct). Worker MUST reject payloads with unknown schema versions explicitly (not silently coerce).

### Functional Requirements — Triage (Joe-side)

- **FR-031**: Joe MUST be able to view, in a queryable interface, all reports and clusters with their signature, count, country, hardware, version, last commands, user title, and user description.
- **FR-032**: Joe MUST be able to download the raw payload artifact for any report from the triage interface.
- **FR-033**: Joe MUST be able to promote a cluster to a tracked bug with a single action, which creates a GitHub issue in the private `jve-bugs` repo, writes the issue URL into `clusters.gh_issue_url`, and links every member raw report to it.
- **FR-034**: Joe MUST be able to manually split or merge clusters when the signature has under- or over-clustered.

### Functional Requirements — Build & deployment

- **FR-035**: Build system MUST inject the source-tree commit identifier into the binary so that every capture and every registration carries a precise build identifier.
- **FR-036**: Legacy code paths from the prior bug-reporting attempt MUST be removed once the new pipeline is operational. Specifically: `src/lua/bug_reporter/youtube_oauth.lua`, `youtube_uploader.lua`, `bug_submission.lua`, `github_issue_creator.lua`, `ui/oauth_dialogs.lua`, `ui/preferences_panel.lua`, the `tests/synthetic/lua/test_upload_system.lua` / `test_gui_runner.lua` / `test_mocked_runner.lua` / `test_bug_reporter_negative.lua` and any other tests that exclusively cover the deleted modules, and the `src/bug_reporter/PHASE_*_COMPLETE.md` / `PROJECT_COMPLETE.md` documents.

### Non-functional requirements

- **NFR-001**: Submission round-trip (Submit click → confirmation) MUST complete within ten seconds on a typical broadband connection for a payload of five megabytes or less.
- **NFR-002**: First-launch registration MUST add no more than two seconds to perceived startup time on a typical broadband connection; on a slow or offline network, registration MUST be deferred without blocking startup.
- **NFR-003**: The backend MUST handle the documented volume (five hundred lifetime reports / one hundred active installs) at zero monetary cost.
- **NFR-004**: Heartbeat and report submission MUST NOT block the UI thread.

---

## Key Entities

- **Install**: A single JVE installation on a single machine. Identified by a locally generated id. Attributes: first-seen and last-launched timestamps, build identifier, platform / OS version / architecture, CPU model and core counts, system memory, GPU vendor / model / memory / API, unified-memory flag, country (resolved server-side), timezone (resolved server-side), report count, authorization status.

- **Report**: A single user-submitted (or automatic-on-error) bug capture. Attributes: id, owning install id, timestamp, build identifier (separate column, NOT in signature), cluster signature, last few command names (ReportBug stripped), last error class (when applicable), user title, user description, pointer to payload artifact, owning cluster, payload schema version.

- **Cluster**: A group of reports sharing the same signature, representing one likely root cause. Attributes: id, signature, first-seen timestamp, member-report count, pointer to the tracked GitHub issue if promoted (null until Joe promotes).

- **Tracked Bug**: A GitHub issue in Joe's private repository representing one promoted cluster, **created only on Joe's explicit promote action**. Attributes: cluster id, title, body, links to member reports.

- **Capture Artifact**: The single zipped payload uploaded per report. Contains the capture metadata file and (unless the user opted into text-only) the slideshow video. Does not contain raw per-frame screenshots and does not contain the `.jvp` project database.

---

## Delivery Phases

To bound risk and surface signal early, the spec is delivered in two phases:

### Phase A — Capture trustworthiness + local submit loop (no backend)
**Goal:** F12 produces a correct, complete, privacy-previewable capture, and the submission dialog's buttons all work, BEFORE any network round-trip exists.

- FR-009a (button wiring)
- FR-010 / FR-010a (ring-buffer + cadence policy)
- FR-011 / FR-011a (artifact shape, no .jvp leak)
- FR-013 (main-window targeting)
- FR-014 (monotonic time)
- FR-015 (PNG cleanup)
- FR-035 (build-time SHA injection)
- FR-036 (legacy module deletion — partial; YouTube/OAuth/old-submission can go; preferences panel deferred to Phase B)
- A "Reveal in Finder" Submit action that writes the zipped artifact to disk and opens it in Finder, in lieu of network submit.

**Exit criterion:** Joe presses F12, fills the dialog, clicks Submit, Finder opens with a clean zip containing capture.json + slideshow.mp4 and nothing else.

### Phase B — Backend, telemetry, dedup, triage
**Goal:** Replace the Phase-A Finder hand-off with a real `/report` POST; add `/register` and `/heartbeat`; ship the Worker, R2, D1, and the Datasette workflow.

- FR-001 / FR-002 / FR-007 (consent, preferences toggle, confirmation/error)
- FR-012 (signature)
- FR-016 / FR-017 / FR-018 / FR-019 / FR-019a / FR-020 (registration, heartbeat, hardware snapshot, install_id persistence)
- FR-021 / FR-021a / FR-022 / FR-023 / FR-024 / FR-024a (transport, auth, rate-limit, queue, payload ceiling)
- FR-025 through FR-030c (backend behavior, dedup, no-auto-create, schema versioning, /register abuse mitigations)
- FR-031 / FR-032 / FR-033 / FR-034 (triage)
- Privacy preview FR-005 ships in Phase B (telemetry fields don't exist in Phase A).

**Exit criterion:** Joe sees a fresh report appear in Datasette within seconds of a user pressing F12, can sort by cluster count, and can promote a cluster to a real GitHub issue with one click.

---

## Out of Scope (deferred)

- In-JVE triage panel (Help → Bug Triage). v1 uses Datasette only.
- Native hardware queries on Linux and Windows. v1 returns null for those fields on non-Apple-platform installs; this is a *documented* known limitation, not a silent fallback. Revisit when JVE ships on those platforms.
- Per-report capture of display count and main-display resolution.
- Per-install capture of system locale.
- Per-report capture of JVE settings snapshot (audio device, output framerate target, debug flags).
- Automatic promotion of clusters to tracked bugs above a count threshold.
- Periodic in-session heartbeat (would convert "weekly launches" → "weekly active users"). v1 measures launches only.
- Reverse channel: Joe replying to a user from the triage UI.
- User-facing "my submitted reports" view.
- Global Worker-side secret rotation event (per-install nonce revocation via `installs.status = 'suspended'` is the only revocation mechanism in v1).
- Dead-install garbage collection in D1 (long-untouched installs stay in the table; Joe filters in triage).
- Bind install_id to a hardware-derived fingerprint to detect home-dir restore. v1 accepts the ambiguity.

---

## Operational Notes (out of band, not gating)

- Cloudflare account belongs to Joe. Worker secret (GitHub bot PAT) rotation procedure: Joe regenerates PAT in GitHub, updates Worker secret via `wrangler secret put`, no JVE-side change needed. Document this in the runbook attached to /plan.
- Edge-level access logs at Cloudflare may capture IP regardless of Worker code. Joe should disable Worker analytics IP capture at the account level if even edge-log IP retention is unacceptable (FR-025 does not bind Cloudflare's edge plane).

---

## Success Criteria

- A first-time user can submit a bug report end-to-end with zero account creation, zero credential setup, and zero CLI tool installation.
- Joe, opening the triage interface, sees a deduplicated, frequency-sorted list of reports with country, hardware, version, last commands, and user description, and can promote any cluster to a tracked GitHub issue in a single action. The Worker creates no GitHub issues on its own.
- At five hundred lifetime reports across one hundred active installs, the operational backend cost remains at zero.
- A user who declines telemetry has zero network traffic from the bug-reporting subsystem; declining is honored immediately and persistently.
- Every string about to leave the user's machine is visible to the user in the submission dialog before they click Submit.
- The `.jvp` project database never leaves the user's machine via this pipeline.
- Phase A is shippable independently of Phase B and produces a correct local artifact.

---

## Architecture (locked, carried forward from /specify input — REVISED)

This section is retained as direct input to /plan, but updated to reflect the spec revisions.

- **Transport:** Cloudflare Worker on a free `*.workers.dev` URL.
- **Storage:** R2 for payload artifacts; D1 for metadata, dedup, and install records.
- **GitHub integration:** Dedicated bot account `jve-bug-bot`, added to Joe's private `jve-bugs` repo with `triage` permission. Bot token lives only in Worker secrets, never in the JVE binary. **The bot creates GitHub issues only when Joe explicitly promotes a cluster (FR-033); it does NOT auto-create on first signature occurrence.** After promotion, the bot may comment on the issue every Nth new report (FR-027a).
- **Auth:** Per-install nonce. App generates `install_id` on first launch, calls `POST /register` to obtain a 32-byte nonce, stores both at `~/.jve/install_id.json` with owner-only permissions. Subsequent calls send `X-Install-Id` + `X-HMAC` (HMAC-SHA256 of body using the nonce). Worker can mark an install `suspended` in D1 to revoke without a rebuild. `/register` refuses to overwrite an existing install_id (FR-030a) and is per-IP rate-limited at the CF edge (FR-030b).
- **Endpoints:** `POST /register`, `POST /heartbeat`, `POST /report` (multipart: metadata JSON + payload zip), `POST /promote` (Joe-side only, authenticated separately).
- **Triage:** Datasette over a weekly `wrangler d1 export` to a local SQLite file. No in-app triage panel for v1.

### D1 schema (locked, REVISED)

```sql
CREATE TABLE installs (
  install_id          TEXT PRIMARY KEY,
  nonce               TEXT NOT NULL,                  -- 64-char hex; same value held by app; HMAC shared secret per FR-021
  first_seen          INTEGER NOT NULL,
  last_launched       INTEGER NOT NULL,    -- renamed from last_seen to clarify metric
  jve_sha             TEXT,
  platform            TEXT,
  os_version          TEXT,
  arch                TEXT,
  country             TEXT,
  timezone            TEXT,
  cpu_model           TEXT,
  cpu_cores_physical  INTEGER,
  cpu_cores_logical   INTEGER,
  cpu_perf_cores      INTEGER,
  cpu_eff_cores       INTEGER,
  system_memory_mb    INTEGER,
  gpu_vendor          TEXT,
  gpu_model           TEXT,
  gpu_memory_mb       INTEGER,
  gpu_api             TEXT,
  unified_memory      INTEGER,
  reports_count       INTEGER DEFAULT 0,
  status              TEXT DEFAULT 'active'
);

CREATE TABLE reports (
  id              TEXT PRIMARY KEY,
  install_id      TEXT NOT NULL REFERENCES installs(install_id),
  ts              INTEGER NOT NULL,
  jve_sha         TEXT,                    -- preserved as column for triage filtering; NOT in signature
  schema_version  TEXT NOT NULL,           -- payload envelope version (FR-030c)
  signature       TEXT NOT NULL,
  last_cmd        TEXT,
  last_err        TEXT,
  user_title      TEXT,
  user_desc       TEXT,
  r2_key          TEXT NOT NULL,
  cluster_id      TEXT REFERENCES clusters(id)
);

CREATE TABLE clusters (
  id            TEXT PRIMARY KEY,
  signature     TEXT UNIQUE NOT NULL,
  first_seen    INTEGER NOT NULL,
  count         INTEGER DEFAULT 1,
  gh_issue_url  TEXT                       -- null until Joe promotes; never written by /report path
);

-- Per-IP rate limit state for /register abuse mitigation (FR-030b).
-- Cloudflare KV or D1 is acceptable; KV preferred for TTL semantics.
```

### Signature (REVISED)

```
sig = sha256(
  last_3_command_names_stripped_of_ReportBug.join(",") + "|" +
  (capture_type == "automatic"
     ? normalize_error(error_message)
     : normalize_title(user_description))
)
```

- `normalize_error`: strips absolute paths, hex IDs, timestamps, line numbers.
- `normalize_title`: first 5 tokens, lowercased, alphanumeric-only.
- `jve_sha` is **not** an input — would otherwise fragment clusters per build (see review finding #4).
- Trailing `ReportBug` command is stripped — the F12 trigger itself MUST NOT dominate signature space (see review finding, smaller issues).

### Existing code to delete (carried forward, expanded per FR-036)

- `src/lua/bug_reporter/youtube_oauth.lua`
- `src/lua/bug_reporter/youtube_uploader.lua`
- `src/lua/bug_reporter/bug_submission.lua`
- `src/lua/bug_reporter/github_issue_creator.lua`
- `src/lua/bug_reporter/ui/oauth_dialogs.lua`
- `src/lua/bug_reporter/ui/preferences_panel.lua` (Phase B)
- `tests/synthetic/lua/test_upload_system.lua`
- `tests/synthetic/lua/test_gui_runner.lua`
- `tests/synthetic/lua/test_mocked_runner.lua`
- `tests/synthetic/lua/test_bug_reporter_negative.lua`
- Any other tests that exclusively cover the deleted modules
- `src/bug_reporter/PHASE_*_COMPLETE.md`, `PROJECT_COMPLETE.md`

### Fix-in-passing (Phase A — must land for new flow to be trustworthy)

- `qApp->activeWindow()` in `qt_bindings_bug_reporter.cpp` → target the JVE main window explicitly (FR-013).
- `os.clock()` in `capture_manager.lua` → monotonic wall time (FR-014).
- Remove per-second `JVE_LOG_EVENT` instrumentation in `lua_grab_window` and `capture_screenshot` (no longer needed once playback-skip is codified per FR-010a).
- Delete per-frame PNGs in `tests/captures/<id>/screenshots/` after slideshow.mp4 is produced (FR-015).
- Remove `database_snapshots` writes from `json_exporter.lua` so .jvp paths/content never enter the payload (FR-011a).

---

## Review & Acceptance Checklist

### Content Quality
- [x] Implementation detail is contained in the **Architecture (locked, REVISED)** section — explicitly carried forward as input from /specify, not re-derived
- [x] Functional requirements are technology-neutral
- [x] Focused on user value and system behavior
- [x] All mandatory sections completed

### Requirement Completeness
- [x] No [NEEDS CLARIFICATION] markers in functional requirements
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Scope is clearly bounded
- [x] Out-of-scope section enumerates deferred items
- [x] Delivery is phased (A independent of B) to bound implementation risk

### ENGINEERING.md alignment notes
- **1.12** (external inputs MUST NEVER crash): FR-021a covers malformed Worker responses with asserts.
- **1.14** (fail-fast asserts): FR-019a (malformed install_id.json) and FR-021a (malformed response) require asserts, not silent fallback.
- **2.13** (no fallbacks): FR-024 splits transport-failure (queue) from rate-limit (discard with user message), neither silent. FR-024 queue overflow surfaces an unmissable warning, not a log line.
- **2.15** (no backward compat): FR-036 deletes legacy modules. FR-030c rejects unknown schema versions explicitly rather than silent coerce.
- **2.17** (no stubs): Linux/Windows hardware queries documented as known limitation, not silent default.
- **3.0** (MVC): /plan must ensure submission dialog is a view pulling from a bug-report state model, not imperative widget construction.
- **3.1** (protocol versioning): FR-030c mandates `schema_version` on every payload; Worker rejects unknowns.

---

## Execution Status

- [x] User description parsed
- [x] Key concepts extracted
- [x] Ambiguities resolved via skeptical review (no [NEEDS CLARIFICATION] markers remain)
- [x] User scenarios defined (26 ASs covering happy path, error paths, abuse, capture correctness, button wiring, malformed state)
- [x] Requirements generated (36 FRs + 3 sub-FRs + 4 NFRs)
- [x] Entities identified
- [x] Phased delivery defined
- [x] Review checklist passed
