# Contract: `POST /register`

**Purpose**: First-contact handshake. App generates an `install_id` locally, calls this endpoint to obtain a per-install nonce. All subsequent calls use that nonce as HMAC key.

**Spec FRs**: FR-016, FR-019, FR-021, FR-025, FR-030, FR-030a, FR-030b, FR-030c.

## Request

```
POST /register HTTP/1.1
Host: jve-bug-relay.<...>.workers.dev
Content-Type: application/json
```

**No HMAC header** — this is the bootstrap call. Abuse mitigation is per-IP rate limit at the Worker edge (FR-030b).

### Body schema

```jsonc
{
  "install_id": "550e8400-e29b-41d4-a716-446655440000",  // UUID v4, client-generated
  "schema_version": "1",                                   // FR-030c
  "jve_sha": "8935293",                                    // 7-char git short SHA from build_info.lua
  "platform": "Darwin",                                    // "Darwin" | "Linux" | "Windows"
  "os_version": "24.6.0",                                  // uname -r; nullable
  "arch": "arm64",                                         // "arm64" | "x86_64"
  "cpu": {
    "model": "Apple M2 Pro",
    "cores_physical": 10,
    "cores_logical": 10,
    "perf_cores": 8,                                       // nullable on non-AS
    "eff_cores": 2                                         // nullable on non-AS
  },
  "system_memory_mb": 32768,
  "gpu": {
    "vendor": "Apple",
    "model": "Apple M2 Pro",
    "memory_mb": 22016,
    "api": "Metal",
    "unified_memory": true
  },
  "consent_version": 1                                     // for audit trail of which consent text user saw
}
```

### Validation (Worker enforces)

| Check | Failure response |
|---|---|
| `schema_version` is "1" | 400 `{"error":"unknown_schema_version"}` |
| `install_id` matches UUID v4 regex | 400 `{"error":"invalid_install_id"}` |
| `install_id` not already in `installs` table | 409 `{"error":"install_id_exists"}` (FR-030a) |
| Per-IP rate (≤5/hour by `SHA256(IP)`) | 429 `{"error":"rate_limited","retry_after_seconds":N}` (FR-030b) |
| `jve_sha` matches `[0-9a-f]{7}` | 400 `{"error":"invalid_jve_sha"}` |
| `platform` ∈ `{Darwin, Linux, Windows}` | 400 `{"error":"invalid_platform"}` |
| `arch` ∈ `{arm64, x86_64}` | 400 `{"error":"invalid_arch"}` |
| Numeric fields positive ints or null | 400 `{"error":"invalid_<field>"}` |

## Response — success (200)

```json
{
  "nonce": "<64 hex chars>",
  "server_ts": 1719279600,
  "country": "US",
  "timezone": "America/Los_Angeles"
}
```

App MUST persist `{nonce, server_ts, country, timezone}` along with the request body into `~/.jve/install_id.json` with file perms 600.

`country` and `timezone` are returned for app-side audit display in Preferences ("we see you as: US, America/Los_Angeles") — they are NOT used for any app-side logic. Authoritative country/timezone live in `installs` on the backend; resolved from `request.cf` (FR-025).

## Side effects (Worker)

1. Store the generated `nonce` (raw, 64-char hex) as `installs.nonce`. HMAC verification on `/heartbeat` and `/report` requires the same secret on both sides; this is a shared-secret protocol (per FR-021), not a password-verification protocol. D1 platform encryption-at-rest is the storage protection. Per-install scoping bounds blast radius: a D1 compromise lets an attacker impersonate every install but does NOT compromise any user's actual project data (which lives only on the user's machine).
2. Resolve `request.cf.country` and `request.cf.timezone`; insert into `installs.country` / `installs.timezone`.
3. INSERT into `installs` with `first_seen = last_launched = now()`, `status = 'active'`, `reports_count = 0`.
4. UPSERT `install_register_attempts` row (`ip_hash`, current window) — increment count.

## Idempotency

**Not idempotent.** Per FR-030a, a second `/register` for an existing `install_id` returns 409. An install that loses its nonce (e.g. file corruption with FR-019a assert) is recoverable only by:
1. Joe manually `UPDATE installs SET status='suspended' WHERE install_id=?` (revoke the dead nonce), OR
2. The user wipes `~/.jve/install_id.json` → fresh-install path → new `install_id` → new `/register` succeeds.

## Contract test outline (`bug-reporter-worker/test/register.test.ts`)

- ✅ Happy path returns 200 with `nonce` matching `/^[0-9a-f]{64}$/`.
- ✅ Subsequent call with same `install_id` returns 409 `install_id_exists`.
- ✅ Missing `install_id` returns 400.
- ✅ `install_id` not UUID v4 returns 400.
- ✅ Unknown `schema_version` returns 400.
- ✅ 6th call in same hour from same IP returns 429.
- ✅ Worker writes `country` and `timezone` columns from `request.cf` (verified via D1 select).
- ✅ Worker writes `installs.nonce` equal to the response `nonce` (verified by D1 select after `/register` — same bytes shared with client).
- ✅ Worker does NOT write raw IP anywhere (D1 select on `install_register_attempts.ip_hash` shows hex, not IP).
- All tests use Miniflare D1/R2 emulation; no real Cloudflare calls.
