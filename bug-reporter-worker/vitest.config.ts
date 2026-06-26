import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

// Miniflare-backed Workers runtime per vitest test. Each suite gets a
// fresh in-process D1 + R2 emulator — no external Cloudflare account
// touched during `npm test`. Production deploy is a separate path.
export default defineWorkersConfig({
    test: {
        poolOptions: {
            workers: {
                wrangler: { configPath: "./wrangler.toml" },
                miniflare: {
                    compatibilityFlags: ["nodejs_compat"],
                    d1Databases: ["DB"],
                    r2Buckets: ["BUCKET"],
                    bindings: {
                        GITHUB_OWNER: "joeshapiro",
                        GITHUB_REPO: "jve-bugs",
                        WIRE_SCHEMA_VERSION: "1",
                        ISSUE_COMMENT_EVERY_N: "10",
                        GITHUB_BOT_TOKEN: "test_gh_token",
                        JOE_PROMOTE_SECRET: "test_promote_secret",
                    },
                },
                singleWorker: false,
            },
        },
    },
});
