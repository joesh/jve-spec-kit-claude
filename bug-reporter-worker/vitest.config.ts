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
                },
                singleWorker: false,
            },
        },
    },
});
