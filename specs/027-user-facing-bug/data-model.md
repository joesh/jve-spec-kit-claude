# Phase 1 Data Model — User-Facing Bug Reporting Pipeline

**Spec**: [spec.md](./spec.md)
**Plan**: [plan.md](./plan.md)
**Date**: 2026-06-25

Three storage tiers:
1. **Backend** (Cloudflare D1 SQLite + R2 object store) — authoritative shared state.
2. **Local app state** (`~/.jve/install_id.json`, `~/.jve/pending-reports/`) — per-install identity + retry queue.
3. **In-memory ring buffers** (capture_manager.lua) — transient per-session state.

---

## Tier 1 — Cloudflare D1 schema

Identical to the locked schema in `spec.md` (Architecture section, REVISED). Restated here as the canonical definition with column-level constraints and indexes.

### `installs`

```sql
CREATE TABLE installs (
  install_id          TEXT PRIMARY KEY NOT NULL,    -- client-generated UUID v4
  nonce               TEXT NOT NULL,                 -- 64-char hex; same value returned to app at /register
  first_seen          INTEGER NOT NULL,              -- unix seconds, set on /register
  last_launched       INTEGER NOT NULL,              -- unix seconds, bumped on /heartbeat and /report
  jve_sha             TEXT NOT NULL,                 -- 7-char git short SHA
  platform            TEXT NOT NULL,                 -- "Darwin" | "Linux" | "Windows"
  os_version          TEXT,                          -- uname -r; nullable for non-mac in v1
  arch                TEXT NOT NULL,                 -- "arm64" | "x86_64"
  country             TEXT,                          -- ISO-3166-1 alpha-2, from request.cf at /register
  timezone            TEXT,                          -- IANA, from request.cf at /register
  cpu_model           TEXT,                          -- "Apple M2 Pro" etc.; nullable on Linux/Windows v1
  cpu_cores_physical  INTEGER,
  cpu_cores_logical   INTEGER,
  cpu_perf_cores      INTEGER,                       -- Apple Silicon P-cores; null elsewhere
  cpu_eff_cores       INTEGER,                       -- Apple Silicon E-cores; null elsewhere
  system_memory_mb    INTEGER,
  gpu_vendor          TEXT,                          -- "Apple" | "NVIDIA" | "AMD" | "Intel"
  gpu_model           TEXT,
  gpu_memory_mb       INTEGER,                       -- recommendedMaxWorkingSetSize / 1MiB on Metal
  gpu_api             TEXT,                          -- "Metal" v1; "OpenGL" / "Vulkan" / "D3D12" later
  unified_memory      INTEGER NOT NULL DEFAULT 0,    -- 0/1 boolean
  reports_count       INTEGER NOT NULL DEFAULT 0,    -- bumped on /report
  status              TEXT NOT NULL DEFAULT 'active' -- 'active' | 'suspended'
);

CREATE INDEX idx_installs_last_launched ON installs(last_launched);
CREATE INDEX idx_installs_country       ON installs(country);
CREATE INDEX idx_installs_jve_sha       ON installs(jve_sha);
```

**State transitions**:
- `status`: `active → suspended` (Joe sets manually via Datasette or `wrangler d1 execute`). No transition back to `active` from the Worker; intentional friction.
- `last_launched`: monotonically increases. Worker uses `MAX(stored, request_ts)` to prevent regression from clock-skewed clients.

**Validation rules** (Worker enforces on `/register`):
- `install_id` matches UUID v4 regex; if not, 400.
- `install_id` MUST NOT already exist in `installs` (FR-030a); if exists, 409.
- `jve_sha` matches `[0-9a-f]{7}`; if not, 400.
- `platform ∈ {"Darwin", "Linux", "Windows"}`; else 400.
- `arch ∈ {"arm64", "x86_64"}`; else 400.
- Numeric fields: positive integers or null.

### `reports`

```sql
CREATE TABLE reports (
  id              TEXT PRIMARY KEY NOT NULL,         -- server-generated UUID v4
  install_id      TEXT NOT NULL REFERENCES installs(install_id),
  ts              INTEGER NOT NULL,                  -- unix seconds; client-supplied, server bounds-checks
  jve_sha         TEXT NOT NULL,                     -- preserved as column for triage filtering; NOT in signature
  schema_version  TEXT NOT NULL,                     -- payload envelope version; "1" at launch
  signature       TEXT NOT NULL,                     -- 64-char hex SHA-256
  last_cmd        TEXT,                              -- last command name with ReportBug stripped; may be null
  last_err        TEXT,                              -- normalized error string; null for user-submitted captures
  user_title      TEXT NOT NULL,                     -- non-empty per FR-004
  user_desc       TEXT,                              -- nullable; user can leave description blank
  capture_type    TEXT NOT NULL,                     -- 'user_submitted' | 'automatic'
  text_only       INTEGER NOT NULL DEFAULT 0,        -- 0/1 boolean; 1 if user chose text-only
  r2_key          TEXT NOT NULL,                     -- storage path under bucket ("reports/<id>.zip"); URLs are NOT public-read — generated on access via R2 presigned URL with 1h TTL (T043)
  cluster_id      TEXT NOT NULL REFERENCES clusters(id)
);

CREATE INDEX idx_reports_install_ts  ON reports(install_id, ts);
CREATE INDEX idx_reports_cluster     ON reports(cluster_id);
CREATE INDEX idx_reports_signature   ON reports(signature);
CREATE INDEX idx_reports_jve_sha     ON reports(jve_sha);
```

**Validation rules**:
- `ts` MUST be within ±1 day of server time; otherwise reject (prevents clock-skew DoS).
- `signature` MUST be 64 hex chars.
- `capture_type` MUST be one of the two literals.
- `user_title` MUST be non-empty.

### `clusters`

```sql
CREATE TABLE clusters (
  id            TEXT PRIMARY KEY NOT NULL,           -- server-generated UUID v4
  signature     TEXT UNIQUE NOT NULL,                -- the dedup key
  first_seen    INTEGER NOT NULL,
  count         INTEGER NOT NULL DEFAULT 1,
  gh_issue_url  TEXT                                  -- null until Joe promotes
);

CREATE INDEX idx_clusters_count ON clusters(count DESC);
```

**State transitions**:
- `count`: monotonically increases per `/report` (FR-026).
- `gh_issue_url`: `NULL → 'https://...'` once Joe calls `/promote` (FR-029, FR-033). Never written by `/report` path (FR-027).

### `report_idempotency` (retry de-dup for FR-024)

Worker-internal table that prevents double-writes when the app retries `/report` after a lost response.

```sql
CREATE TABLE report_idempotency (
  install_id    TEXT NOT NULL,
  local_id      TEXT NOT NULL,   -- the X-Report-Local-Id header value (client UUID)
  report_id     TEXT NOT NULL,   -- the report_id returned to the client on first success
  created_at    INTEGER NOT NULL,
  PRIMARY KEY (install_id, local_id)
);
```

**Lifecycle**: row inserted on first successful `/report`. TTL via a scheduled Worker that deletes rows older than 7 days. Matches the local pending-queue lifespan in practice — past 7 days the client has surely either succeeded or hit the queue cap and dropped.

**Why local_id is required on the client**: contract `report.md` mandates `X-Report-Local-Id` on every `/report` call. The client generates a UUID at zip-creation time and reuses it across retries. Without this header the Worker can't dedupe.

### `install_register_attempts` (rate-limit state for FR-030b)

```sql
CREATE TABLE install_register_attempts (
  ip_hash       TEXT NOT NULL,                       -- SHA-256(request IP) — hashed, not raw
  window_start  INTEGER NOT NULL,                    -- floor(unix_seconds / 3600)
  attempt_count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (ip_hash, window_start)
);
```

**Rationale**: hashing IP gives per-IP throttling without storing raw IP (FR-025 says no IP in app-controlled persistence; SHA-256 is non-reversible at random-IP scale). 1-hour windows; old rows reaped on a Worker scheduled trigger.

---

## Tier 2 — Local app state

### `~/.jve/install_id.json`

```jsonc
{
  "install_id": "550e8400-e29b-41d4-a716-446655440000",
  "nonce": "<64 hex chars>",
  "consent_accepted_ts": 1719279600,
  "consent_version": 1,              // bumped when consent text materially changes
  "jve_sha_at_register": "8935293",  // used by FR-018 to detect version change → re-snapshot hardware
  "hardware_snapshot": {
    "platform": "Darwin",
    "os_version": "24.6.0",
    "arch": "arm64",
    "cpu": {
      "model": "Apple M2 Pro",
      "cores_physical": 10,
      "cores_logical": 10,
      "perf_cores": 8,
      "eff_cores": 2
    },
    "system_memory_mb": 32768,
    "gpu": {
      "vendor": "Apple",
      "model": "Apple M2 Pro",
      "memory_mb": 22016,
      "api": "Metal",
      "unified_memory": true
    }
  }
}
```

**File permissions**: 600 (owner-only). Created via `utils.write_secure_file` (existing helper, line 100 of `utils.lua`).

**Validation rules** (FR-019a — assert on malformed):
- File MUST parse as JSON; otherwise assert with path + parse error.
- `install_id` MUST match UUID v4.
- `nonce` MUST be 64 hex chars.
- `consent_accepted_ts` MUST be positive integer.
- Missing any required key → assert.
- Missing `hardware_snapshot` is allowed (e.g. mid-upgrade); the app re-queries and re-writes.

**State**:
- File absent → user is in fresh-install state; app shows consent dialog.
- File present + valid + `consent_accepted_ts` present → registered; app sends `/heartbeat` at launch.
- File present + valid + `jve_sha_at_register != current_jve_sha` → re-query hardware, include changed fields in next `/heartbeat` (FR-018), update `jve_sha_at_register`.
- File present but malformed → assert (FR-019a). Do NOT silently regenerate.

### `~/.jve/pending-reports/`

Directory containing pairs of files for each pending report:

```
~/.jve/pending-reports/
├── <uuid>.payload.zip       # raw bytes that would have been the multipart payload field
└── <uuid>.metadata.json     # the multipart metadata field (JSON)
```

`<uuid>` is a client-generated UUID used both as the file basename and as `X-Report-Local-Id` on retry submission (Worker echoes it back for debug correlation; not stored).

**Cap**: 50 pairs (FR-024). When inserting a new pair would exceed cap:
1. Pick the oldest pair by `<uuid>` mtime.
2. Delete it.
3. Surface an unmissable warning to the user (modal or persistent banner — choice locked in /tasks).
4. Insert the new pair.

**Drain order**: oldest first by mtime. On each retry, transport.lua processes one pair at a time; on success deletes the pair; on rate-limit (FR-023 → AS #17) deletes the pair AND surfaces the rate-limit message; on transport failure (network/5xx/malformed response) leaves the pair in place.

### `tests/captures/<id>/` (Phase A on-disk export)

Existing structure from `json_exporter.lua` modified per FR-011a + FR-015:

```
tests/captures/capture-<datestamp>-<short_uuid>/
├── capture.json             # MODIFIED: drop database_snapshots, drop video_recording, add schema_version + jve_sha
├── slideshow.mp4            # ffmpeg-generated from screenshots
└── (screenshots/ removed after slideshow.mp4 produced — FR-015)
```

Phase A's "Submit" action zips `capture.json` + `slideshow.mp4` (text-only excludes the mp4) and opens Finder to that zip — no upload.

---

## Tier 3 — In-memory ring buffers (transient)

Existing `capture_manager.lua` shapes, modified to enforce per-stream count caps (FR-010).

```lua
-- Each ring buffer is an array; trim_buffers() drops oldest when over cap.

CaptureManager.gesture_ring_buffer = {}      -- cap: 200 entries, 5min wall age
-- entry: {id="g123", timestamp_ms=12345, gesture={type, screen_x, ...}}

CaptureManager.command_ring_buffer = {}      -- cap: 200 entries, 5min wall age (new cap per FR-010)
-- entry: {id="c123", timestamp_ms=12345, command="RippleTrimEdge", parameters={...}, result={...}, triggered_by_gesture=nil}

CaptureManager.log_ring_buffer = {}          -- cap: 1000 entries, 5min wall age (new cap per FR-010)
-- entry: {timestamp_ms=12345, level="warn", message="..."}

CaptureManager.screenshot_ring_buffer = {}   -- cap: 300 entries (5min @ 1Hz), 5min wall age (new cap per FR-010)
-- entry: {timestamp_ms=12345, image=<QPixmap userdata>}
```

**Timestamp source**: `qt_monotonic_s() * 1000` instead of `os.clock() * 1000` (FR-014). Session start captured at `init()` time the same way; difference vs. now is the elapsed-ms.

**Pixmap lifecycle**: `entry.image` is a QPixmap userdata owned by Lua. When the entry is dropped by `trim_buffers()`, the QPixmap goes out of scope and the existing `qpixmap_gc` metamethod (`qt_bindings_bug_reporter.cpp:177`) deletes the underlying C++ object. No manual cleanup needed.

---

## Tier-spanning derived entities

### Signature (FR-012)

Deterministic function of three inputs:

```
sig_input_commands = last_3_commands.reject(c -> c.name == "ReportBug").map(c -> c.name).join(",")
sig_input_text     = capture_type == "automatic"
                       ? normalize_error(error_message)
                       : normalize_title(user_description)
sig                = sha256(sig_input_commands + "|" + sig_input_text)  // 64 hex chars
```

`normalize_error(s)`:
- Strip absolute path prefixes (anything matching `/[A-Za-z0-9_./\-]+` and ending in `\.[a-z]+`).
- Strip hex IDs (`0x[0-9a-f]+`, plus standalone `[0-9a-f]{16,}`).
- Strip ISO-8601 timestamps and unix-second integers ≥ 10⁹.
- Strip trailing `:N` line numbers from path-like prefixes.
- Lowercase, collapse whitespace, trim.

`normalize_title(s)`:
- Lowercase.
- Replace non-alphanumeric with single space.
- Take first 5 space-delimited tokens.
- Concatenate with single spaces.

**Both implementations** (Lua side at `signature.lua`, TS side at `bug-reporter-worker/src/signature.ts`) MUST agree on the same fixture vectors. Canonical fixture file: `tests/fixtures/signature_vectors.json` consumed by both sides.

### Reference id (`ref_short`) returned to user

First 8 chars of `report_id` (UUID v4). 32-bit collision space across ≤500 reports is comfortable.

---

## Index of where each spec FR's data touches

| FR | Tier | Touches |
|---|---|---|
| FR-001 (consent) | 2 | `install_id.json.consent_accepted_ts` + `consent_version` |
| FR-002 (toggle) | 2 | Preferences key (separate file `~/.jve/preferences.json` — not in scope of this data-model; preferences module owns it) |
| FR-010 (ring caps) | 3 | New per-stream count caps |
| FR-011a (no .jvp) | 1 + tier-A export | Remove `database_snapshots` from `capture.json` and never include `.jvp` content in `r2_key` payload |
| FR-012 (sig) | 1 | `reports.signature`, `clusters.signature` |
| FR-014 (monotonic) | 3 | `entry.timestamp_ms` derived from `qt_monotonic_s()` |
| FR-016 (register fields) | 1 + 2 | `installs.*` columns and `install_id.json.hardware_snapshot` |
| FR-019 (perms) | 2 | `install_id.json` 600 |
| FR-019a (assert) | 2 | Loader asserts on malformed |
| FR-021 (per-install HMAC) | 1 + 2 | `installs.nonce` (raw, server-side); `install_id.json.nonce` (same value, client-side) — HMAC verification requires shared secret, so backend retains the nonce; D1 platform-level encryption-at-rest is the storage protection |
| FR-022 (revoke) | 1 | `installs.status = 'suspended'` |
| FR-023 (daily cap) | 1 | Computed at `/report` time from `reports.install_id + ts` window |
| FR-024 (queue) | 2 | `~/.jve/pending-reports/` cap of 50 |
| FR-024a (10 MB) | 2 + 3 | App clamps before zip |
| FR-025 (no IP) | 1 | `install_register_attempts.ip_hash` (hashed), no raw column anywhere |
| FR-026 (dedup) | 1 | `clusters.signature` UNIQUE + count |
| FR-027 (no auto GH) | 1 | `clusters.gh_issue_url` NULL on insert |
| FR-027a (Nth comment) | 1 | Read `clusters.count` after bump; if `count % N == 0 AND gh_issue_url IS NOT NULL` then post comment |
| FR-029 (idempotent promote) | 1 | `/promote` checks `gh_issue_url` first; on lost-response, label-search reconciliation |
| FR-030a (no overwrite) | 1 | UNIQUE constraint + 409 |
| FR-030b (per-IP RL) | 1 | `install_register_attempts` table |
| FR-030c (schema_version) | 1 + 2 + wire | `reports.schema_version` + `X-Schema-Version` header |

---

## Migration policy

Per Constitution VIII (No Backward Compatibility): D1 schema is created fresh by `bug-reporter-worker/migrations/0001_initial_schema.sql` (top-level `migrations/` per wrangler convention). No migration from any prior shape (none exists). Future schema changes will be additive (new columns nullable) until a breaking change forces a fresh `wrangler d1 create`. Joe regenerates the D1 on breaking changes; no in-place migration code.
