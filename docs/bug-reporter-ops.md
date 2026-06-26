# JVE bug-reporter operations (Joe-side)

Operational notes for the Cloudflare-Worker bug-reporter pipeline
(feature 027). For end-user-facing semantics see
[`specs/027-user-facing-bug/`](../specs/027-user-facing-bug/).

## One-time setup

```bash
cd bug-reporter-worker

# 1) Cloudflare resources
npx wrangler login
npx wrangler d1 create jve-bug-reports
# → paste returned database_id into wrangler.toml [[d1_databases]].database_id
npx wrangler r2 bucket create jve-bug-reports

# 2) Schema
npx wrangler d1 execute jve-bug-reports --file=migrations/0001_initial_schema.sql

# 3) GitHub bot
# - Create a `jve-bug-bot` account.
# - Add it to your private `jve-bugs` repo with `triage` permission.
# - Generate a PAT with `repo:status` + `public_repo` (or `repo` if your
#   bugs repo is private).
# - Store it as a worker secret:
npx wrangler secret put GITHUB_BOT_TOKEN

# 4) Joe-side promote bearer
npx wrangler secret put JOE_PROMOTE_SECRET

# 5) Deploy
npx wrangler deploy
```

## Weekly triage

```bash
# Export D1 to local SQLite
npx wrangler d1 export jve-bug-reports --output=/tmp/jve-bugs.sqlite

# Run Datasette over it
datasette serve /tmp/jve-bugs.sqlite
# → http://localhost:8001
```

Sort the `clusters` table by `count DESC`. Click into a cluster to see
its `signature`, `first_seen`, and the linked `reports` rows. Each row
points at an R2 zip (`r2_key`) — the Worker exposes presigned URLs
that expire in 1 hour (T043 / T-NEW-D).

To promote a cluster, open `triage-promote.html` served alongside the
worker:

```
https://jve-bug-relay.<workers-subdomain>.workers.dev/triage-promote.html?id=<cluster_id>
```

Paste your `JOE_PROMOTE_SECRET` once (cached in `localStorage`) and
click Promote. A GitHub issue is created in `jve-bugs`, tagged
`cluster:<id>` for reconciliation, with the initial member listing as
a comment.

## Secret rotation

```bash
npx wrangler secret put GITHUB_BOT_TOKEN
npx wrangler secret put JOE_PROMOTE_SECRET
```

Wrangler immediately invalidates the previous value. If a user's nonce
is compromised, suspend the install:

```bash
npx wrangler d1 execute jve-bug-reports --command \
  "UPDATE installs SET status='suspended' WHERE install_id='<uuid>'"
```

A suspended install's heartbeats and reports return 403; the app's
F12 path will surface "Bug reporting is disabled."

## Cloudflare analytics IP capture

By default the Workers analytics dashboard records the Client IP for
every request. Disable this so the bug-reporter pipeline never has
raw IPs in its analytics history either:

1. Open your Cloudflare dashboard → Workers → jve-bug-relay → Settings.
2. Under "Observability", set **Logs → Client IP** to "Off".
3. The D1 path already only stores `sha256(ip)` (`install_register_attempts.ip_hash`),
   so this is the last surface where raw IPs appear in the platform.

## Endpoint override for development

`bug_reporter.transport` (T035) reads `JVE_BUG_REPORT_ENDPOINT` at
module-load. Set it before launching `jve` to point at `wrangler dev`:

```bash
JVE_BUG_REPORT_ENDPOINT=http://localhost:8787 \
  ./build/bin/jve.app/Contents/MacOS/jve
```

The env var is intended for dev only — `transport.lua` asserts on
non-https URLs at module-load (T-NEW-E).

## Worker test suite

```bash
cd bug-reporter-worker
npm test
```

Runs vitest against a Miniflare-emulated D1+R2. No real Cloudflare
calls. Known issue: `report.test.ts` halts after the first R2 PUT in
the pool's isolated-storage check — see
`~/.claude/projects/-Users-joe-Local-jve-spec-kit-claude/memory/todo_027_report_test_r2_isolation.md`.
The other four contract test files (register, heartbeat, promote,
signature_parity) run to completion.

## Cron cleanup (T-NEW-C)

`wrangler.toml` declares `triggers.crons = ["0 * * * *"]`. Every hour
the scheduled handler deletes:

- `install_register_attempts` rows whose `window_start < (current_hour − 24)`
- `report_idempotency` rows whose `created_at < (now − 7d)`

No action needed from Joe; runs automatically post-deploy.
