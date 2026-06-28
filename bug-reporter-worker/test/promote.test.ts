// Feature 027 T023: POST /promote contract tests.
// Implements every bullet from contracts/promote.md outline. RED until
// T048 lands the handler + T044 lands github.ts spies.

import { describe, expect, it, beforeEach } from "vitest";
import { SELF, env } from "cloudflare:test";
import { resetD1BeforeEach, uuidV4 } from "./_helpers";

resetD1BeforeEach();

// Github calls are intercepted by src/github.ts when the worker-side
// __JVE_GH_TEST_CALLS array exists. We reset it before every test via
// a tiny /__test/ route on SELF that the handlers expose only in test
// mode (via env.GITHUB_BOT_TOKEN === "test_gh_token"); see
// vitest.config.ts. The call log + reply-injection live on
// globalThis inside the worker runtime; assertions read it via a
// dedicated /__test/gh-calls endpoint.
beforeEach(async () => {
    await SELF.fetch("https://example.com/__test/reset-gh-hook", { method: "POST" });
});

async function getGhCalls(): Promise<Array<{ kind: string; args: unknown[] }>> {
    const res = await SELF.fetch("https://example.com/__test/gh-calls");
    return await res.json();
}

async function setGhFindReply(reply: { html_url: string; number: number } | null) {
    await SELF.fetch("https://example.com/__test/gh-find-reply", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ reply }),
    });
}

const PROMOTE_SECRET = "test_promote_secret";

async function seedCluster(opts: { id?: string; signature?: string; count?: number; gh_issue_url?: string | null; report_count?: number; install_id?: string }) {
    const cluster_id = opts.id ?? uuidV4();
    const signature = opts.signature ?? "a".repeat(64);
    const count = opts.count ?? 4;
    const gh_issue_url = opts.gh_issue_url ?? null;
    const install_id = opts.install_id ?? uuidV4();

    await env.DB.prepare(`
        INSERT INTO installs (install_id, nonce, first_seen, last_launched, jve_sha,
                              platform, arch, status, reports_count, unified_memory)
        VALUES (?, ?, ?, ?, '8935293', 'Darwin', 'arm64', 'active', 0, 1)
    `).bind(install_id, "a".repeat(64), 0, 0).run();

    if (gh_issue_url) {
        await env.DB.prepare(`
            INSERT INTO clusters (id, signature, first_seen, count, gh_issue_url)
            VALUES (?, ?, 0, ?, ?)
        `).bind(cluster_id, signature, count, gh_issue_url).run();
    } else {
        await env.DB.prepare(`
            INSERT INTO clusters (id, signature, first_seen, count)
            VALUES (?, ?, 0, ?)
        `).bind(cluster_id, signature, count).run();
    }

    const report_count = opts.report_count ?? count;
    for (let i = 0; i < report_count; i++) {
        await env.DB.prepare(`
            INSERT INTO reports (id, install_id, ts, jve_sha, schema_version, signature,
                                 user_title, capture_type, text_only, r2_key, cluster_id)
            VALUES (?, ?, ?, '8935293', '1', ?, 'Cuts disappear after undo',
                    'user_submitted', 0, ?, ?)
        `).bind(uuidV4(), install_id, i, signature, `reports/r${i}.zip`, cluster_id).run();
    }
    return { cluster_id, signature };
}

function postPromote(opts: {
    cluster_id?: string;
    title_override?: string;
    body_override?: string;
    label_overrides?: string[];
    authorization?: string;
    schemaVersion?: string;
}): Promise<Response> {
    const body: Record<string, unknown> = {};
    if (opts.cluster_id !== undefined) body.cluster_id = opts.cluster_id;
    if (opts.title_override !== undefined) body.title_override = opts.title_override;
    if (opts.body_override !== undefined) body.body_override = opts.body_override;
    if (opts.label_overrides !== undefined) body.label_overrides = opts.label_overrides;
    return SELF.fetch("https://example.com/promote", {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
            "Authorization": opts.authorization ?? `Bearer ${PROMOTE_SECRET}`,
            "X-Schema-Version": opts.schemaVersion ?? "1",
        },
        body: JSON.stringify(body),
    });
}

describe("POST /promote", () => {
    it("happy path returns 201 created:true with valid gh_issue_url", async () => {
        const { cluster_id } = await seedCluster({ count: 4 });
        const res = await postPromote({ cluster_id });
        expect(res.status).toBe(201);
        const body = await res.json() as { gh_issue_url: string; cluster_id: string; member_report_count: number; created: boolean };
        expect(body.gh_issue_url).toMatch(/^https?:\/\//);
        expect(body.cluster_id).toBe(cluster_id);
        expect(body.created).toBe(true);
        expect(body.member_report_count).toBe(4);
    });

    it("second call with same cluster_id (gh_issue_url already set) returns 200 created:false", async () => {
        const { cluster_id } = await seedCluster({ count: 4 });
        const first = await postPromote({ cluster_id });
        expect(first.status).toBe(201);
        const second = await postPromote({ cluster_id });
        expect(second.status).toBe(200);
        const body = await second.json() as { gh_issue_url: string; created: boolean };
        expect(body.created).toBe(false);
    });

    it("lost-response reconciliation: gh_issue_url IS NULL but label-search finds existing issue", async () => {
        const { cluster_id } = await seedCluster({ count: 4 });
        await setGhFindReply({ html_url: "https://github.com/joeshapiro/jve-bugs/issues/77", number: 77 });
        const res = await postPromote({ cluster_id });
        expect(res.status).toBe(200);
        const body = await res.json() as { gh_issue_url: string; created: boolean };
        expect(body.created).toBe(false);
        expect(body.gh_issue_url).toBe("https://github.com/joeshapiro/jve-bugs/issues/77");
        const row = await env.DB
            .prepare("SELECT gh_issue_url FROM clusters WHERE id = ?")
            .bind(cluster_id)
            .first<{ gh_issue_url: string }>();
        expect(row!.gh_issue_url).toBe("https://github.com/joeshapiro/jve-bugs/issues/77");
    });

    it("wrong bearer returns 401", async () => {
        const { cluster_id } = await seedCluster({});
        const res = await postPromote({ cluster_id, authorization: "Bearer wrong" });
        expect(res.status).toBe(401);
    });

    it("missing Authorization returns 401", async () => {
        const { cluster_id } = await seedCluster({});
        const res = await SELF.fetch("https://example.com/promote", {
            method: "POST",
            headers: { "Content-Type": "application/json", "X-Schema-Version": "1" },
            body: JSON.stringify({ cluster_id }),
        });
        expect(res.status).toBe(401);
    });

    it("unknown cluster_id returns 404", async () => {
        const res = await postPromote({ cluster_id: uuidV4() });
        expect(res.status).toBe(404);
    });

    it("non-UUID cluster_id returns 400", async () => {
        const res = await postPromote({ cluster_id: "not-a-uuid" });
        expect(res.status).toBe(400);
    });

    it("unknown X-Schema-Version returns 400", async () => {
        const { cluster_id } = await seedCluster({});
        const res = await postPromote({ cluster_id, schemaVersion: "9" });
        expect(res.status).toBe(400);
    });

    it("GH issue body includes R2 (presigned) URLs for every member report", async () => {
        const { cluster_id } = await seedCluster({ count: 3 });
        await postPromote({ cluster_id });
        const calls = await getGhCalls();
        const create = calls.find((c) => c.kind === "create_issue");
        expect(create).toBeDefined();
        const bodyArg = create!.args[2] as string;
        const urlCount = (bodyArg.match(/reports\/r\d+\.zip/g) ?? []).length;
        expect(urlCount).toBeGreaterThanOrEqual(3);
    });

    it("GH issue labels include cluster:<id> for reconciliation", async () => {
        const { cluster_id } = await seedCluster({ count: 2 });
        await postPromote({ cluster_id });
        const calls = await getGhCalls();
        const create = calls.find((c) => c.kind === "create_issue");
        const labels = create!.args[3] as string[];
        expect(labels).toContain(`cluster:${cluster_id}`);
    });

    it("initial comment is posted with member listing", async () => {
        const { cluster_id } = await seedCluster({ count: 2 });
        await postPromote({ cluster_id });
        const calls = await getGhCalls();
        const comments = calls.filter((c) => c.kind === "comment_on_issue");
        expect(comments.length).toBeGreaterThanOrEqual(1);
    });
});
