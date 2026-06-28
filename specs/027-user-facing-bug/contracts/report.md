# Contract: `POST /report`

**Purpose**: Deliver a single bug report (metadata JSON + zip payload). Worker writes the zip to R2, inserts a `reports` row, upserts the matching `clusters` row, and (per FR-027) does NOT auto-create any GitHub issue.

**Spec FRs**: FR-007, FR-011, FR-011a, FR-012, FR-021, FR-021a, FR-022, FR-023, FR-024, FR-024a, FR-025, FR-026, FR-027, FR-027a, FR-028, FR-030c.

## Request

```
POST /report HTTP/1.1
Host: jve-bug-relay.<...>.workers.dev
Content-Type: multipart/form-data; boundary=----jveBugBoundary
X-Install-Id: 550e8400-e29b-41d4-a716-446655440000
X-Schema-Version: 1
X-HMAC: <hex SHA-256 HMAC of signed payload (see "Signed payload construction" below) with nonce as key>
X-Report-Local-Id: <client-generated UUID — echoed back for debug correlation>
```

### Multipart body

Two parts:

#### Part 1 — `metadata` (JSON)

```jsonc
{
  "signature": "<64 hex>",                     // computed app-side per FR-012
  "last_cmd": "RippleTrimEdge",                // ReportBug-stripped last command; nullable
  "last_err": null,                            // normalized error string; null when capture_type=user_submitted
  "user_title": "Cuts disappear after undo",   // non-empty (FR-004)
  "user_desc": "When I undo a ripple trim ...",// nullable
  "capture_type": "user_submitted",            // "user_submitted" | "automatic"
  "text_only": false,                          // true if slideshow excluded (FR-006)
  "ts": 1719279600,                            // unix seconds
  "jve_sha": "8935293"                         // preserved as column; NOT in signature
}
```

#### Part 2 — `payload` (binary zip)

Content-Disposition MUST include a `filename` parameter (e.g. `form-data; name="payload"; filename="payload.zip"`). Cloudflare Workers' `FormData.get()` returns a part as a string when no filename is present and as a Blob when filename IS present; the Worker's `parse_multipart` requires `payload instanceof Blob` for binary safety. A filename-less payload returns `400 malformed_request`.

The `metadata` part MUST NOT include a filename — the Worker requires `typeof metadata === "string"`.

Zip containing:
- `capture.json` (REQUIRED) — capture metadata file per FR-011 + FR-011a (no `database_snapshots`, no `video_recording` block)
- `slideshow.mp4` (PRESENT iff `metadata.text_only == false`)

Raw screenshot PNGs MUST NOT be in the zip (FR-011, FR-015). The `.jvp` project DB MUST NOT be in the zip (FR-011a).

App MUST clamp the total request size to **10 MB** before sending (FR-024a). Strategy: drop oldest log entries, then commands, then refuse with user-visible error.

### Signed payload construction

HMAC over raw multipart body bytes is impractical because multipart boundary generation is nondeterministic — the app and Worker would compute different `body` strings even for identical logical content. Instead:

```
signed_payload = metadata_json + "\n" + sha256_hex(zip_bytes)
X-HMAC = hex(HMAC-SHA256(nonce, signed_payload))
```

Both sides reconstruct `signed_payload` deterministically:
- App: serializes `metadata` to JSON with stable key ordering (sort keys alphabetically), computes `sha256_hex(zip_bytes)`, concatenates with `\n`, HMACs with nonce.
- Worker: parses the multipart, extracts `metadata_json` (the raw bytes received for the metadata part), computes `sha256_hex(zip_bytes)` over the payload part, concatenates with `\n`, HMACs with the looked-up nonce, constant-time compares against `X-HMAC`.

This separates the integrity guarantee (the metadata JSON + the zip hash) from the wire format (multipart boundaries). The zip content itself is integrity-checked transitively via its hash being inside `signed_payload`.

## Validation (Worker)

| Check | Failure |
|---|---|
| `X-Schema-Version` is "1" | 400 `{"error":"unknown_schema_version"}` |
| `X-Install-Id` exists in `installs` | 404 `{"error":"unknown_install"}` |
| `installs.status == 'active'` | 403 `{"error":"suspended"}` |
| `X-HMAC == hex(HMAC-SHA256(nonce, metadata_json + "\n" + sha256_hex(zip_bytes)))` per §Signed payload construction | 401 `{"error":"bad_hmac"}` |
| Total body ≤ 10 MB | 413 `{"error":"payload_too_large"}` |
| Reports for this install in last 24h < 20 | 429 `{"error":"rate_limited","retry_after_seconds":N}` (FR-023) |
| `metadata.signature` is 64 hex | 400 `{"error":"invalid_signature"}` |
| `metadata.user_title` non-empty | 400 `{"error":"missing_title"}` |
| `metadata.capture_type ∈ {"user_submitted","automatic"}` | 400 `{"error":"invalid_capture_type"}` |
| `metadata.ts` within ±1 day of server time | 400 `{"error":"ts_out_of_range"}` |
| Multipart body has `metadata` part (parseable JSON) | 400 `{"error":"malformed_request"}` |
| Multipart body has `payload` part (any bytes) | 400 `{"error":"malformed_request"}` |
| Zip parses (at minimum: read directory entries, find `capture.json`) | 400 `{"error":"malformed_payload"}` |

The Worker does NOT inspect `capture.json` contents — that's app-side responsibility. The Worker DOES verify the zip is a syntactically valid zip with a `capture.json` entry, to catch fully corrupt uploads early.

## Response — success (200)

```json
{
  "report_id": "7e8b1f72-3a51-4cb9-9c8e-114c8d6a2f80",
  "ref_short": "7e8b1f72",
  "cluster_id": "<uuid>",
  "cluster_count": 4,
  "server_ts": 1719279700
}
```

`ref_short` is the first 8 chars of `report_id` (UUID v4). App shows this to the user as "Report sent — reference #7e8b1f72" per FR-007.

## Side effects

1. R2 PUT: `reports/<report_id>.zip` ← payload bytes.
2. D1 transaction:
   - `INSERT OR ABORT INTO clusters (id, signature, first_seen, count, gh_issue_url) VALUES (new_uuid, ?, now, 1, NULL) ON CONFLICT(signature) DO UPDATE SET count = count + 1`.
   - Read back the matching cluster row to get `cluster_id` and post-update `count`.
   - `INSERT INTO reports (id, install_id, ts, jve_sha, schema_version, signature, last_cmd, last_err, user_title, user_desc, capture_type, text_only, r2_key, cluster_id) VALUES (...)`.
   - `UPDATE installs SET reports_count = reports_count + 1, last_launched = MAX(last_launched, ?) WHERE install_id = ?`.
3. If `cluster.gh_issue_url IS NOT NULL` AND `(cluster.count % N) == 0` (default N=10): enqueue a GitHub-issue-comment task (FR-027a). Bot comments: *"Cluster bumped to N reports. Most recent: `ref_short`."*

**The Worker does NOT create a GitHub issue on `/report`** (FR-027). Promotion happens only via `/promote`.

## Idempotency

**Per-`X-Report-Local-Id`** if the app retries: Worker checks an idempotency table (`report_idempotency` keyed by `(install_id, x_report_local_id)`) before processing. Duplicate retries return the original 200 response with the same `report_id`. Idempotency rows TTL after 7 days. This handles the "request completed server-side but response lost" case without producing duplicate reports.

```sql
CREATE TABLE report_idempotency (
  install_id    TEXT NOT NULL,
  local_id      TEXT NOT NULL,
  report_id     TEXT NOT NULL,
  created_at    INTEGER NOT NULL,
  PRIMARY KEY (install_id, local_id)
);
```

(Add this table to `bug-reporter-worker/migrations/0001_initial_schema.sql` alongside the other tables defined in `data-model.md`.)

## Spec-sync note

This contract adds a `report_idempotency` table not previously called out in `data-model.md`'s tier-1 list. Updating both: the table is a Worker-internal implementation detail of FR-024's "queue and retry on transport failure" requirement (the retry path that the app already executes per FR-024 must not double-write at the Worker — idempotency table is the mechanism). Adding a one-line note here is sufficient; the spec's FR-024 already mandates the behavior. *(Spec-sync: no FR change; this is a contract-internal mechanism.)*

## Contract test outline (`bug-reporter-worker/test/report.test.ts`)

- ✅ Happy path returns 200 with valid `report_id` UUID v4 and 8-char `ref_short`.
- ✅ R2 PUT verified: `reports/<report_id>.zip` exists with correct bytes.
- ✅ D1 verified: `reports` row inserted, `clusters` upserted, `installs.reports_count` bumped, `last_launched` not regressed.
- ✅ Replay with same `X-Report-Local-Id` returns the same `report_id` (idempotency).
- ✅ Two reports with same `signature` produce ONE cluster row with `count=2`.
- ✅ Two reports with different signatures produce TWO cluster rows.
- ✅ NO GitHub issue created by `/report` (FR-027 — verified by spying on github.ts module).
- ✅ Cluster with existing `gh_issue_url` AND `count % 10 == 0` triggers issue-comment task.
- ✅ Cluster with `gh_issue_url IS NULL` AND `count % 10 == 0` does NOT trigger issue-comment task.
- ✅ Wrong HMAC returns 401.
- ✅ `installs.status='suspended'` returns 403.
- ✅ Payload over 10 MB returns 413.
- ✅ 21st report in 24h window returns 429.
- ✅ Unknown `install_id` returns 404.
- ✅ Empty `user_title` returns 400.
- ✅ `capture_type` not in enum returns 400.
- ✅ Zip without `capture.json` entry returns 400.
- ✅ Text-only flag with no slideshow part in zip succeeds.
- ✅ Text-only flag = false with slideshow part absent returns 400.
- ✅ `ts` 2 days in future returns 400.
- ✅ Unknown `X-Schema-Version` returns 400.
