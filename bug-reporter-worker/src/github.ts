// GitHub API surface for the bug-reporter pipeline (feature 027 T044).
//
// Three operations — all called via fetch() against GitHub's REST API.
// For testability, every call is also recorded to a global hook
// (__JVE_GH_TEST_CALLS) when present. The worker pool's RPC boundary
// makes vi.mock impractical; this in-Worker hook gives tests a
// deterministic spy surface without breaking storage isolation.

declare global {
    // eslint-disable-next-line no-var
    var __JVE_GH_TEST_CALLS: Array<{ kind: string; args: unknown[] }> | undefined;
    // eslint-disable-next-line no-var
    var __JVE_GH_TEST_REPLIES: { find_issue?: unknown } | undefined;
}

function record(kind: string, args: unknown[]): void {
    if (globalThis.__JVE_GH_TEST_CALLS) globalThis.__JVE_GH_TEST_CALLS.push({ kind, args });
}

export async function create_issue(
    env: { GITHUB_OWNER: string; GITHUB_REPO: string; GITHUB_BOT_TOKEN?: string },
    title: string,
    body: string,
    labels: string[],
): Promise<{ html_url: string; number: number }> {
    record("create_issue", [env, title, body, labels]);
    if (globalThis.__JVE_GH_TEST_CALLS) {
        return { html_url: `https://github.com/${env.GITHUB_OWNER}/${env.GITHUB_REPO}/issues/142`, number: 142 };
    }
    if (!env.GITHUB_BOT_TOKEN) {
        throw new Error("github.create_issue: GITHUB_BOT_TOKEN secret missing");
    }
    const res = await fetch(`https://api.github.com/repos/${env.GITHUB_OWNER}/${env.GITHUB_REPO}/issues`, {
        method: "POST",
        headers: {
            "Authorization": `token ${env.GITHUB_BOT_TOKEN}`,
            "Accept": "application/vnd.github+json",
            "User-Agent": "jve-bug-relay",
            "Content-Type": "application/json",
        },
        body: JSON.stringify({ title, body, labels }),
    });
    if (!res.ok) {
        const txt = await res.text();
        throw new Error(`github.create_issue failed: ${res.status} ${txt.slice(0, 200)}`);
    }
    return await res.json() as { html_url: string; number: number };
}

export async function find_issue_by_cluster_label(
    env: { GITHUB_OWNER: string; GITHUB_REPO: string; GITHUB_BOT_TOKEN?: string },
    cluster_id: string,
): Promise<{ html_url: string; number: number } | null> {
    record("find_issue_by_cluster_label", [env, cluster_id]);
    if (globalThis.__JVE_GH_TEST_CALLS) {
        const reply = globalThis.__JVE_GH_TEST_REPLIES?.find_issue;
        return reply as { html_url: string; number: number } | null ?? null;
    }
    if (!env.GITHUB_BOT_TOKEN) {
        throw new Error("github.find_issue_by_cluster_label: GITHUB_BOT_TOKEN secret missing");
    }
    const res = await fetch(
        `https://api.github.com/repos/${env.GITHUB_OWNER}/${env.GITHUB_REPO}/issues?labels=cluster:${cluster_id}&state=all`,
        {
            headers: {
                "Authorization": `token ${env.GITHUB_BOT_TOKEN}`,
                "Accept": "application/vnd.github+json",
                "User-Agent": "jve-bug-relay",
            },
        },
    );
    if (!res.ok) {
        throw new Error(`github.find_issue_by_cluster_label failed: ${res.status}`);
    }
    const results = await res.json() as Array<{ html_url: string; number: number }>;
    return results.length > 0 ? results[0] : null;
}

export async function comment_on_issue(
    env: { GITHUB_OWNER: string; GITHUB_REPO: string; GITHUB_BOT_TOKEN?: string },
    issue_number: number,
    body: string,
): Promise<void> {
    record("comment_on_issue", [env, issue_number, body]);
    if (globalThis.__JVE_GH_TEST_CALLS) return;
    if (!env.GITHUB_BOT_TOKEN) {
        throw new Error("github.comment_on_issue: GITHUB_BOT_TOKEN secret missing");
    }
    const res = await fetch(
        `https://api.github.com/repos/${env.GITHUB_OWNER}/${env.GITHUB_REPO}/issues/${issue_number}/comments`,
        {
            method: "POST",
            headers: {
                "Authorization": `token ${env.GITHUB_BOT_TOKEN}`,
                "Accept": "application/vnd.github+json",
                "User-Agent": "jve-bug-relay",
                "Content-Type": "application/json",
            },
            body: JSON.stringify({ body }),
        },
    );
    if (!res.ok) {
        const txt = await res.text();
        throw new Error(`github.comment_on_issue failed: ${res.status} ${txt.slice(0, 200)}`);
    }
}
