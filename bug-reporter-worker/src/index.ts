// JVE bug-reporter Cloudflare Worker entry. Built out task-by-task in
// the Phase B implementation pass (T045-T048 + T-NEW-C scheduled).

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

export default {
    async fetch(req: Request, _env: Env, _ctx: ExecutionContext): Promise<Response> {
        return new Response(
            JSON.stringify({ error: "not_implemented", path: new URL(req.url).pathname }),
            { status: 501, headers: { "Content-Type": "application/json" } },
        );
    },

    async scheduled(_event: ScheduledEvent, _env: Env, _ctx: ExecutionContext): Promise<void> {
        // T-NEW-C implements cleanup here.
    },
};
