# Contract: `POST /promote`

**Purpose**: Joe-side action. Triggered from the Datasette triage UI (or via `curl` directly). Creates a GitHub issue in Joe's private `jve-bugs` repo for the named cluster, writes `clusters.gh_issue_url` back, and posts an initial comment listing the member raw reports.

**Spec FRs**: FR-027, FR-029, FR-033, FR-034.

## Request

```
POST /promote HTTP/1.1
Host: jve-bug-relay.<...>.workers.dev
Content-Type: application/json
Authorization: Bearer <JOE_PROMOTE_SECRET>
X-Schema-Version: 1
```

**Auth model is different from `/report` and `/heartbeat`.** Those use per-install nonces; this uses a single Joe-owned bearer secret stored in Worker secrets (`wrangler secret put JOE_PROMOTE_SECRET`). Only Joe can promote. No install_id involved.

### Body schema

```jsonc
{
  "cluster_id": "<uuid>",
  "title_override": "Ripple trim leaks track on undo",   // optional; defaults to derived title
  "body_override": "## Repro\n1. ...",                    // optional; defaults to derived body
  "label_overrides": ["bug","timeline","high"]            // optional; defaults to ["bug","auto-triaged"]
}
```

Derived title (when `title_override` absent): `"[cluster] <first 60 chars of most-common user_title>"`.
Derived body (when `body_override` absent): templated markdown listing cluster signature, count, member report ids, **presigned R2 URLs** (1-hour TTL per T043) for each member report, hardware distribution, country distribution, and a "promote source: /promote" footer. Presigned URLs in the issue body expire after 1 hour — when Joe re-opens the issue later, he re-clicks the cluster in the triage UI to refresh URLs. This is intentional: URLs in long-lived locations (GitHub issue bodies) don't become permanent payload-leak vectors.

## Validation (Worker)

| Check | Failure |
|---|---|
| `X-Schema-Version` is "1" | 400 `{"error":"unknown_schema_version"}` |
| `Authorization` matches `JOE_PROMOTE_SECRET` (constant-time compare) | 401 `{"error":"unauthorized"}` |
| `cluster_id` UUID v4 | 400 `{"error":"invalid_cluster_id"}` |
| Cluster exists in D1 | 404 `{"error":"cluster_not_found"}` |
| `clusters.gh_issue_url` IS NULL **OR** the existing URL is a valid GitHub issue URL | (handled below — idempotent) |

## Response — success (201, fresh promotion)

```json
{
  "gh_issue_url": "https://github.com/joeshapiro/jve-bugs/issues/142",
  "cluster_id": "<uuid>",
  "member_report_count": 4,
  "created": true
}
```

## Response — already promoted (200, idempotent reconciliation per FR-029)

```json
{
  "gh_issue_url": "https://github.com/joeshapiro/jve-bugs/issues/142",
  "cluster_id": "<uuid>",
  "member_report_count": 4,
  "created": false
}
```

## Idempotency (FR-029)

Three-stage check to handle the "GitHub API succeeded but Worker response lost" case:

1. **Fast path**: `SELECT gh_issue_url FROM clusters WHERE id = ?`. If non-null → return `created: false` with the stored URL.
2. **Reconciliation path** (gh_issue_url IS NULL): before calling GitHub API to create, search the repo via `GET /repos/{owner}/{repo}/issues?labels=cluster:<cluster_id>` (where the issue is tagged with a `cluster:<uuid>` label at creation time). If a result is found, `UPDATE clusters SET gh_issue_url = ?` and return `created: false`.
3. **Create path**: call `POST /repos/{owner}/{repo}/issues` with body, title, `["bug","auto-triaged","cluster:<cluster_id>"]` labels. On success, `UPDATE clusters SET gh_issue_url = ?` and return `created: true`. Then post initial comment with the member-report inventory.

The `cluster:<cluster_id>` label is the reconciliation key (GitHub issues are searchable by label). This is why the body template includes `["bug","auto-triaged","cluster:<id>"]` — not for human display, for idempotent recovery.

## Side effects

1. (Create path only) GitHub: `POST /repos/{owner}/{repo}/issues`.
2. (Create path only) D1: `UPDATE clusters SET gh_issue_url = ? WHERE id = ?`.
3. (Create path only) GitHub: `POST /repos/{owner}/{repo}/issues/{number}/comments` with member-report listing including R2 URLs.
4. (Reconciliation path) D1: `UPDATE clusters SET gh_issue_url = ?` — fills in the URL we should have stored last time.

## Triage UI integration

Datasette doesn't natively POST to external endpoints. Two options:
- **Option A (chosen for v1)**: a tiny static HTML+JS page served alongside Datasette (`triage-promote.html`) that takes a cluster_id from the URL query string and POSTs to `/promote` with Joe's secret read from `localStorage`. Joe pastes the secret once.
- **Option B**: a Datasette plugin. More work; not justified for one button.

Document Option A in `quickstart.md` Phase B walkthrough.

## Contract test outline (`bug-reporter-worker/test/promote.test.ts`)

- ✅ Happy path returns 201 with valid `gh_issue_url`.
- ✅ Subsequent call with same `cluster_id` (gh_issue_url already set) returns 200 `created:false`.
- ✅ Lost-response reconciliation: simulated state with `gh_issue_url IS NULL` but a GH issue exists with `cluster:<id>` label → returns 200 `created:false` and updates D1.
- ✅ Wrong bearer returns 401.
- ✅ Unknown `cluster_id` returns 404.
- ✅ Unknown `X-Schema-Version` returns 400.
- ✅ GitHub issue body includes R2 URLs for every member report.
- ✅ GitHub issue labels include `cluster:<id>` for reconciliation.
- ✅ Initial comment posted with member listing.
- All GitHub API calls mocked via vitest spies; no real GH API hits in tests.
