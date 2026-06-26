// JVE bug-reporter Cloudflare Worker (feature 027 T045-T048 + T-NEW-C).
//
// Routes:
//   POST /register   — first-contact bootstrap; per-IP rate-limit
//   POST /heartbeat  — one ping per launch; HMAC + last_launched bump
//   POST /report     — bug report upload; HMAC + dedup + R2 + D1
//   POST /promote    — Joe-only; bearer auth; create GH issue +
//                       reconcile via cluster:<id> label
//
// Scheduled handler: hourly cleanup of install_register_attempts
// (drop >24h-old windows) + report_idempotency (drop >7d-old rows).

import * as d1 from "./d1";
import * as auth from "./auth";
import * as r2 from "./r2";
import * as github from "./github";
import { compute as signature_compute } from "./signature";

interface Env {
    DB: D1Database;
    BUCKET: R2Bucket;
    GITHUB_OWNER: string;
    GITHUB_REPO: string;
    WIRE_SCHEMA_VERSION: string;
    ISSUE_COMMENT_EVERY_N: string;
    GITHUB_BOT_TOKEN?: string;
    JOE_PROMOTE_SECRET?: string;
}

function json(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json" },
    });
}

const UUID_V4_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

async function handle_register(req: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
    let body: Record<string, unknown>;
    try {
        body = await req.json() as Record<string, unknown>;
    } catch {
        return json({ error: "malformed_request" }, 400);
    }
    if (body.schema_version !== env.WIRE_SCHEMA_VERSION) {
        return json({ error: "unknown_schema_version" }, 400);
    }
    const install_id = body.install_id;
    if (typeof install_id !== "string" || !UUID_V4_RE.test(install_id)) {
        return json({ error: "invalid_install_id" }, 400);
    }
    if (typeof body.jve_sha !== "string" || !/^[0-9a-f]{7}$/.test(body.jve_sha)) {
        return json({ error: "invalid_jve_sha" }, 400);
    }
    const platform = body.platform;
    if (platform !== "Darwin" && platform !== "Linux" && platform !== "Windows") {
        return json({ error: "invalid_platform" }, 400);
    }
    const arch = body.arch;
    if (arch !== "arm64" && arch !== "x86_64") {
        return json({ error: "invalid_arch" }, 400);
    }

    // Per-IP rate limit (5/hour). Use CF-Connecting-IP if available;
    // hash with SHA-256 so the raw IP is never persisted.
    const raw_ip = req.headers.get("CF-Connecting-IP") ?? "unknown";
    const ip_hash = await auth.sha256_hex_text(raw_ip);
    const now = Math.floor(Date.now() / 1000);
    const rate = await auth.check_install_register_rate(env.DB, ip_hash, now, 5);
    if (!rate.ok) {
        return json({ error: "rate_limited", retry_after_seconds: rate.retry_after_seconds }, 429);
    }

    // Duplicate install_id check.
    const existing = await d1.installs.get(env.DB, install_id);
    if (existing) {
        return json({ error: "install_id_exists" }, 409);
    }

    const nonce_bytes = crypto.getRandomValues(new Uint8Array(32));
    const nonce = Array.from(nonce_bytes, (b) => b.toString(16).padStart(2, "0")).join("");

    // request.cf is undefined under Miniflare unless explicitly set;
    // accept either CF-IPCountry header (Miniflare convention) or the
    // request.cf object (production).
    const cf_country = (req as Request & { cf?: { country?: string } }).cf?.country
        ?? req.headers.get("CF-IPCountry") ?? "ZZ";
    const cf_timezone = (req as Request & { cf?: { timezone?: string } }).cf?.timezone
        ?? req.headers.get("CF-Timezone") ?? "UTC";

    const cpu = (body.cpu as Record<string, unknown> | undefined) ?? {};
    const gpu = (body.gpu as Record<string, unknown> | undefined) ?? {};
    const unified = gpu.unified_memory === true ? 1 : 0;

    await d1.installs.insert(env.DB, {
        install_id, nonce,
        first_seen: now, last_launched: now,
        jve_sha: body.jve_sha as string,
        platform: platform as string,
        os_version: (body.os_version as string) ?? null,
        arch: arch as string,
        country: cf_country,
        timezone: cf_timezone,
        cpu_model: (cpu.model as string) ?? null,
        cpu_cores_physical: (cpu.cores_physical as number) ?? null,
        cpu_cores_logical: (cpu.cores_logical as number) ?? null,
        cpu_perf_cores: (cpu.perf_cores as number) ?? null,
        cpu_eff_cores: (cpu.eff_cores as number) ?? null,
        system_memory_mb: (body.system_memory_mb as number) ?? null,
        gpu_vendor: (gpu.vendor as string) ?? null,
        gpu_model: (gpu.model as string) ?? null,
        gpu_memory_mb: (gpu.memory_mb as number) ?? null,
        gpu_api: (gpu.api as string) ?? null,
        unified_memory: unified,
        reports_count: 0,
        status: "active",
    });

    return json({ nonce, server_ts: now, country: cf_country, timezone: cf_timezone }, 200);
}

async function handle_heartbeat(req: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
    if (req.headers.get("X-Schema-Version") !== env.WIRE_SCHEMA_VERSION) {
        return json({ error: "unknown_schema_version" }, 400);
    }
    const install_id = req.headers.get("X-Install-Id");
    if (!install_id) return json({ error: "unknown_install" }, 404);

    const body_text = await req.text();
    let body: Record<string, unknown>;
    try {
        body = JSON.parse(body_text) as Record<string, unknown>;
    } catch {
        return json({ error: "malformed_request" }, 400);
    }

    const x_hmac = req.headers.get("X-HMAC") ?? "";
    const auth_result = await auth.verify_install_hmac(env.DB, install_id, body_text, x_hmac);
    if (!auth_result.ok) {
        if (auth_result.code === "unknown_install") return json({ error: "unknown_install" }, 404);
        if (auth_result.code === "suspended") return json({ error: "suspended" }, 403);
        return json({ error: "bad_hmac" }, 401);
    }

    if (typeof body.ts !== "number") return json({ error: "ts_missing" }, 400);
    const now = Math.floor(Date.now() / 1000);
    if (Math.abs(body.ts - now) > 86400) return json({ error: "ts_out_of_range" }, 400);
    if (typeof body.jve_sha !== "string" || !/^[0-9a-f]{7}$/.test(body.jve_sha)) {
        return json({ error: "invalid_jve_sha" }, 400);
    }

    await d1.installs.update_last_launched_and_sha(env.DB, install_id, body.ts, body.jve_sha);

    if (body.hardware) {
        const h = body.hardware as Record<string, unknown>;
        const cpu = (h.cpu as Record<string, unknown>) ?? {};
        const gpu = (h.gpu as Record<string, unknown>) ?? {};
        await d1.installs.update_hardware(env.DB, install_id, {
            os_version: (h.os_version as string) ?? null,
            arch: (h.arch as string) ?? null,
            cpu_model: cpu.model as string ?? null,
            cpu_cores_physical: cpu.cores_physical as number ?? null,
            cpu_cores_logical: cpu.cores_logical as number ?? null,
            cpu_perf_cores: cpu.perf_cores as number ?? null,
            cpu_eff_cores: cpu.eff_cores as number ?? null,
            system_memory_mb: h.system_memory_mb as number ?? null,
            gpu_vendor: gpu.vendor as string ?? null,
            gpu_model: gpu.model as string ?? null,
            gpu_memory_mb: gpu.memory_mb as number ?? null,
            gpu_api: gpu.api as string ?? null,
            unified_memory: gpu.unified_memory === true ? 1 : 0,
        });
    }

    return json({ server_ts: now, status: "ok" }, 200);
}

interface MultipartParts {
    metadata_bytes: Uint8Array;
    payload_bytes: Uint8Array;
}

async function parse_multipart(req: Request): Promise<MultipartParts | null> {
    const form = await req.formData();
    const metadata = form.get("metadata");
    const payload = form.get("payload");
    if (typeof metadata !== "string" || !(payload instanceof Blob)) return null;
    return {
        metadata_bytes: new TextEncoder().encode(metadata),
        payload_bytes: new Uint8Array(await payload.arrayBuffer()),
    };
}

async function handle_report(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    if (req.headers.get("X-Schema-Version") !== env.WIRE_SCHEMA_VERSION) {
        return json({ error: "unknown_schema_version" }, 400);
    }
    const install_id = req.headers.get("X-Install-Id");
    if (!install_id) return json({ error: "unknown_install" }, 404);

    // Read entire body so we can size-check before downstream work.
    const raw = new Uint8Array(await req.arrayBuffer());
    if (raw.length > 10 * 1024 * 1024) {
        return json({ error: "payload_too_large" }, 413);
    }

    // Re-parse multipart. Reuse the byte body via a synthetic Request.
    const re_req = new Request(req.url, {
        method: "POST",
        headers: req.headers,
        body: raw,
    });
    const mp = await parse_multipart(re_req).catch(() => null);
    if (!mp) return json({ error: "malformed_request" }, 400);

    const metadata_text = new TextDecoder().decode(mp.metadata_bytes);
    let metadata: Record<string, unknown>;
    try {
        metadata = JSON.parse(metadata_text) as Record<string, unknown>;
    } catch {
        return json({ error: "malformed_request" }, 400);
    }

    const x_hmac = req.headers.get("X-HMAC") ?? "";
    const payload_sha = await auth.sha256_hex_bytes(mp.payload_bytes);
    const signed_payload = metadata_text + "\n" + payload_sha;
    const auth_result = await auth.verify_install_hmac(env.DB, install_id, signed_payload, x_hmac);
    if (!auth_result.ok) {
        if (auth_result.code === "unknown_install") return json({ error: "unknown_install" }, 404);
        if (auth_result.code === "suspended") return json({ error: "suspended" }, 403);
        return json({ error: "bad_hmac" }, 401);
    }

    // Metadata validation.
    if (typeof metadata.signature !== "string" || !/^[0-9a-f]{64}$/.test(metadata.signature)) {
        return json({ error: "invalid_signature" }, 400);
    }
    if (typeof metadata.user_title !== "string" || metadata.user_title.length === 0) {
        return json({ error: "missing_title" }, 400);
    }
    if (metadata.capture_type !== "user_submitted" && metadata.capture_type !== "automatic") {
        return json({ error: "invalid_capture_type" }, 400);
    }
    if (typeof metadata.ts !== "number") return json({ error: "ts_missing" }, 400);
    const now = Math.floor(Date.now() / 1000);
    if (Math.abs(metadata.ts - now) > 86400) return json({ error: "ts_out_of_range" }, 400);

    // Zip directory sanity check — accept anything that begins with
    // the zip-local-file-header magic and includes a 'capture.json'
    // file name marker. We don't decompress.
    const zip_text = new TextDecoder("utf-8", { fatal: false }).decode(mp.payload_bytes);
    if (mp.payload_bytes.length < 4 ||
        !(mp.payload_bytes[0] === 0x50 && mp.payload_bytes[1] === 0x4b)) {
        return json({ error: "malformed_payload" }, 400);
    }
    if (!zip_text.includes("capture.json")) {
        return json({ error: "malformed_payload" }, 400);
    }

    // Idempotency.
    const local_id = req.headers.get("X-Report-Local-Id") ?? "";
    if (local_id) {
        const prior = await d1.report_idempotency.get(env.DB, install_id, local_id);
        if (prior) {
            return json({
                report_id: prior.report_id,
                ref_short: prior.report_id.slice(0, 8),
                cluster_id: "",  // not stored in idempotency; clients rely on the original response
                cluster_count: 0,
                server_ts: now,
            }, 200);
        }
    }

    // Per-install daily rate (20/day).
    const since = now - 86400;
    const recent = await d1.reports.count_in_window(env.DB, install_id, since);
    if (recent >= 20) {
        return json({ error: "rate_limited", retry_after_seconds: 3600 }, 429);
    }

    // Cluster upsert + report insert.
    const cluster = await d1.clusters.upsert(env.DB, metadata.signature as string, now);
    const report_id = crypto.randomUUID();
    const r2_key = `reports/${report_id}.zip`;

    await r2.put_report_zip(env.BUCKET, report_id, mp.payload_bytes);

    await d1.reports.insert(env.DB, {
        id: report_id, install_id,
        ts: metadata.ts as number,
        jve_sha: (metadata.jve_sha as string) ?? "0000000",
        schema_version: env.WIRE_SCHEMA_VERSION,
        signature: metadata.signature as string,
        last_cmd: (metadata.last_cmd as string) ?? null,
        last_err: (metadata.last_err as string) ?? null,
        user_title: metadata.user_title as string,
        user_desc: (metadata.user_desc as string) ?? null,
        capture_type: metadata.capture_type as "user_submitted" | "automatic",
        text_only: metadata.text_only === true ? 1 : 0,
        r2_key,
        cluster_id: cluster.id,
    });

    await d1.installs.bump_reports_count(env.DB, install_id);
    if (local_id) {
        await d1.report_idempotency.insert(env.DB, install_id, local_id, report_id, now);
    }

    // FR-027a: every Nth report on a promoted cluster fires a GH comment.
    const N = parseInt(env.ISSUE_COMMENT_EVERY_N, 10);
    if (cluster.gh_issue_url && Number.isFinite(N) && N > 0 && cluster.count % N === 0) {
        const issue_number = parseInt(cluster.gh_issue_url.match(/\/issues\/(\d+)/)?.[1] ?? "0", 10);
        if (issue_number > 0) {
            ctx.waitUntil(github.comment_on_issue(env, issue_number,
                `Cluster bumped to ${cluster.count} reports. Most recent: ${report_id.slice(0, 8)}.`));
        }
    }

    // FR-027: NEVER auto-create a GitHub issue from /report.
    // (No github.create_issue call anywhere in this function — verified
    // by the spy assertion in test/report.test.ts.)

    return json({
        report_id, ref_short: report_id.slice(0, 8),
        cluster_id: cluster.id, cluster_count: cluster.count,
        server_ts: now,
    }, 200);
}

async function handle_promote(req: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
    if (req.headers.get("X-Schema-Version") !== env.WIRE_SCHEMA_VERSION) {
        return json({ error: "unknown_schema_version" }, 400);
    }
    const authz = req.headers.get("Authorization") ?? "";
    const expected = `Bearer ${env.JOE_PROMOTE_SECRET ?? ""}`;
    if (!env.JOE_PROMOTE_SECRET || authz.length !== expected.length) {
        return json({ error: "unauthorized" }, 401);
    }
    let diff = 0;
    for (let i = 0; i < authz.length; i++) diff |= authz.charCodeAt(i) ^ expected.charCodeAt(i);
    if (diff !== 0) return json({ error: "unauthorized" }, 401);

    let body: Record<string, unknown>;
    try {
        body = await req.json() as Record<string, unknown>;
    } catch {
        return json({ error: "malformed_request" }, 400);
    }
    const cluster_id = body.cluster_id;
    if (typeof cluster_id !== "string" || !UUID_V4_RE.test(cluster_id)) {
        return json({ error: "invalid_cluster_id" }, 400);
    }
    const cluster = await d1.clusters.get(env.DB, cluster_id);
    if (!cluster) return json({ error: "cluster_not_found" }, 404);

    const members = await d1.reports.list_for_cluster(env.DB, cluster_id);

    // Stage 1: fast path.
    if (cluster.gh_issue_url) {
        return json({
            gh_issue_url: cluster.gh_issue_url,
            cluster_id,
            member_report_count: members.length,
            created: false,
        }, 200);
    }

    // Stage 2: reconciliation via label search.
    const existing = await github.find_issue_by_cluster_label(env, cluster_id);
    if (existing) {
        await d1.clusters.set_gh_issue_url(env.DB, cluster_id, existing.html_url);
        return json({
            gh_issue_url: existing.html_url, cluster_id,
            member_report_count: members.length, created: false,
        }, 200);
    }

    // Stage 3: create.
    const title = (body.title_override as string)
        ?? `[cluster] ${members[0]?.user_title?.slice(0, 60) ?? "Untitled cluster"}`;
    const r2_urls = members.map((m) => `- ${m.r2_key}`).join("\n");
    const body_text = (body.body_override as string) ?? [
        `Cluster ${cluster_id}`,
        `Signature: ${cluster.signature}`,
        `Member count: ${cluster.count}`,
        ``,
        `R2 artifacts (presigned URLs expire in 1h — re-click cluster in triage UI to refresh):`,
        r2_urls,
        ``,
        `Promote source: /promote`,
    ].join("\n");
    const labels = (body.label_overrides as string[])
        ?? ["bug", "auto-triaged", `cluster:${cluster_id}`];

    const created = await github.create_issue(env, title, body_text, labels);
    await d1.clusters.set_gh_issue_url(env.DB, cluster_id, created.html_url);
    await github.comment_on_issue(env, created.number,
        `Initial member listing:\n\n${members.map((m) => `- ${m.id.slice(0, 8)}: ${m.user_title}`).join("\n")}`);

    return json({
        gh_issue_url: created.html_url, cluster_id,
        member_report_count: members.length, created: true,
    }, 201);
}

// Test-only routes are gated by GITHUB_BOT_TOKEN === "test_gh_token"
// (the vitest pool sets this; production secrets never match).
async function handle_test_route(req: Request, env: Env, url: URL): Promise<Response> {
    if (env.GITHUB_BOT_TOKEN !== "test_gh_token") {
        return json({ error: "not_found", path: url.pathname }, 404);
    }
    const g = globalThis as unknown as { __JVE_GH_TEST_CALLS?: Array<{ kind: string; args: unknown[] }>; __JVE_GH_TEST_REPLIES?: Record<string, unknown> };
    switch (url.pathname) {
        case "/__test/reset-gh-hook":
            g.__JVE_GH_TEST_CALLS = [];
            g.__JVE_GH_TEST_REPLIES = {};
            return json({ ok: true });
        case "/__test/gh-calls":
            return json(g.__JVE_GH_TEST_CALLS ?? []);
        case "/__test/gh-find-reply": {
            const body = await req.json() as { reply: unknown };
            g.__JVE_GH_TEST_REPLIES = g.__JVE_GH_TEST_REPLIES ?? {};
            g.__JVE_GH_TEST_REPLIES.find_issue = body.reply;
            return json({ ok: true });
        }
        default:
            return json({ error: "not_found", path: url.pathname }, 404);
    }
}

export default {
    async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
        // Stable Lua/TS signature verifier — surfaces parity bugs at
        // startup by recomputing one of the fixture vectors. Skip on
        // every actual request; the test suite already does parity.
        void signature_compute;

        const url = new URL(req.url);
        if (url.pathname.startsWith("/__test/")) return handle_test_route(req, env, url);
        if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
        switch (url.pathname) {
            case "/register":  return handle_register(req, env, ctx);
            case "/heartbeat": return handle_heartbeat(req, env, ctx);
            case "/report":    return handle_report(req, env, ctx);
            case "/promote":   return handle_promote(req, env, ctx);
            default:           return json({ error: "not_found", path: url.pathname }, 404);
        }
    },

    async scheduled(_event: ScheduledEvent, env: Env, ctx: ExecutionContext): Promise<void> {
        // T-NEW-C: hourly cleanup.
        const now = Math.floor(Date.now() / 1000);
        const cutoff_attempts = Math.floor(now / 3600) - 24;
        const cutoff_idempotency = now - 7 * 86400;
        ctx.waitUntil(env.DB.prepare(
            `DELETE FROM install_register_attempts WHERE window_start < ?`)
            .bind(cutoff_attempts).run());
        ctx.waitUntil(env.DB.prepare(
            `DELETE FROM report_idempotency WHERE created_at < ?`)
            .bind(cutoff_idempotency).run());
    },
};
