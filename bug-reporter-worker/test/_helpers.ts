// Shared test helpers for the Worker contract tests (T020-T023).
// Resets the D1 schema before each test so every test starts clean.

import { env } from "cloudflare:test";
import { beforeEach } from "vitest";
import migrationSql from "../migrations/0001_initial_schema.sql?raw";

declare module "cloudflare:test" {
    interface ProvidedEnv {
        DB: D1Database;
        BUCKET: R2Bucket;
        GITHUB_OWNER: string;
        GITHUB_REPO: string;
        WIRE_SCHEMA_VERSION: string;
        ISSUE_COMMENT_EVERY_N: string;
        GITHUB_BOT_TOKEN?: string;
        JOE_PROMOTE_SECRET?: string;
    }
}

const DROP_ORDER = [
    "reports",                   // FK depends on clusters + installs
    "report_idempotency",
    "install_register_attempts",
    "clusters",
    "installs",
];

async function applyMigration() {
    // exec() takes raw SQL with no parameter binding; semicolons OK.
    await env.DB.exec(migrationSql.replace(/\s*--[^\n]*\n/g, "").replace(/\n/g, " "));
}

export function resetD1BeforeEach() {
    beforeEach(async () => {
        for (const t of DROP_ORDER) {
            await env.DB.exec(`DROP TABLE IF EXISTS ${t}`);
        }
        await applyMigration();
    });
}

export function uuidV4(): string {
    return crypto.randomUUID();
}
