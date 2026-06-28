# Contract: `POST /heartbeat`

**Purpose**: One ping per JVE launch. Updates `installs.last_launched`. If `jve_sha` changed since the last successful heartbeat for this install, the body carries an updated hardware snapshot which the Worker writes to `installs`.

**Spec FRs**: FR-017, FR-018, FR-021, FR-022, FR-030c.

## Request

```
POST /heartbeat HTTP/1.1
Host: jve-bug-relay.<...>.workers.dev
Content-Type: application/json
X-Install-Id: 550e8400-e29b-41d4-a716-446655440000
X-Schema-Version: 1
X-HMAC: <hex SHA-256 HMAC of body with nonce as key>
```

### Body schema

Minimal case (no `jve_sha` change since last heartbeat):

```json
{
  "ts": 1719279600,
  "jve_sha": "8935293"
}
```

Hardware-update case (JVE was upgraded — `jve_sha` differs from app's locally stored `jve_sha_at_register`):

```jsonc
{
  "ts": 1719279600,
  "jve_sha": "e9d8d97",
  "hardware": {
    "os_version": "24.6.0",
    "arch": "arm64",
    "cpu": { "model": "...", "cores_physical": 10, "cores_logical": 10, "perf_cores": 8, "eff_cores": 2 },
    "system_memory_mb": 32768,
    "gpu": { "vendor": "Apple", "model": "Apple M3 Pro", "memory_mb": 24576, "api": "Metal", "unified_memory": true }
  }
}
```

App MUST set `hardware` only when `jve_sha` differs from the value stored at last successful `/heartbeat` or `/register` (FR-018). Bandwidth-thrift.

## Validation (Worker)

| Check | Failure |
|---|---|
| `X-Schema-Version` is "1" | 400 `{"error":"unknown_schema_version"}` |
| `X-Install-Id` exists in `installs` | 404 `{"error":"unknown_install"}` |
| `installs.status == 'active'` | 403 `{"error":"suspended"}` (FR-022 → AS #16) |
| `X-HMAC == hex(HMAC-SHA256(nonce, body))` | 401 `{"error":"bad_hmac"}` |
| `ts` within ±1 day of server time | 400 `{"error":"ts_out_of_range"}` |
| `jve_sha` matches `[0-9a-f]{7}` | 400 `{"error":"invalid_jve_sha"}` |

## Response — success (200)

```json
{
  "server_ts": 1719279700,
  "status": "ok"
}
```

## Side effects

1. `UPDATE installs SET last_launched = MAX(last_launched, request_ts), jve_sha = ?body.jve_sha WHERE install_id = ?`.
2. If body has `hardware` field, update every populated hardware column on the same UPDATE.

## Idempotency

Idempotent. Same `(install_id, ts)` replayed produces same DB state. Worker uses `MAX(last_launched, request_ts)` so re-ordering or clock-skew doesn't regress the column.

## Contract test outline (`bug-reporter-worker/test/heartbeat.test.ts`)

- ✅ Happy path returns 200 and bumps `last_launched` in D1.
- ✅ Replay of identical request returns 200 idempotently (last_launched not regressed).
- ✅ Missing `X-Install-Id` returns 404.
- ✅ Unknown `install_id` returns 404.
- ✅ `status='suspended'` returns 403.
- ✅ Wrong `X-HMAC` returns 401.
- ✅ `X-HMAC` of body with attacker-chosen-nonce returns 401.
- ✅ Body with `hardware` updates GPU/CPU columns (verified via D1 select).
- ✅ Body without `hardware` does NOT clobber existing columns to null.
- ✅ `ts` 2 days in the future returns 400.
- ✅ Unknown `X-Schema-Version` returns 400.
