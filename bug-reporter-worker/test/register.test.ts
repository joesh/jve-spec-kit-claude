// Feature 027 T020: POST /register contract tests.
//
// Implements every bullet from contracts/register.md §Contract test
// outline. Currently RED — the Worker stub returns 501; T045 lands the
// real handler. Tests use Miniflare D1+R2 emulation per vitest.config.ts.

import { describe, expect, it } from "vitest";
import { SELF, env } from "cloudflare:test";
import { resetD1BeforeEach, uuidV4 } from "./_helpers";

resetD1BeforeEach();

const SAMPLE_BODY = {
    schema_version: "1",
    jve_sha: "8935293",
    platform: "Darwin",
    os_version: "24.6.0",
    arch: "arm64",
    cpu: {
        model: "Apple M2 Pro",
        cores_physical: 10,
        cores_logical: 10,
        perf_cores: 8,
        eff_cores: 2,
    },
    system_memory_mb: 32768,
    gpu: {
        vendor: "Apple",
        model: "Apple M2 Pro",
        memory_mb: 22016,
        api: "Metal",
        unified_memory: true,
    },
    consent_version: 1,
};

function postRegister(body: object, headers: Record<string, string> = {}): Promise<Response> {
    return SELF.fetch("https://example.com/register", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...headers },
        body: JSON.stringify(body),
    });
}

describe("POST /register", () => {
    it("happy path returns 200 with 64-hex nonce", async () => {
        const install_id = uuidV4();
        const res = await postRegister({ install_id, ...SAMPLE_BODY });
        expect(res.status).toBe(200);
        const body = await res.json() as { nonce: string; server_ts: number };
        expect(body.nonce).toMatch(/^[0-9a-f]{64}$/);
        expect(typeof body.server_ts).toBe("number");
    });

    it("duplicate install_id returns 409 install_id_exists", async () => {
        const install_id = uuidV4();
        const first = await postRegister({ install_id, ...SAMPLE_BODY });
        expect(first.status).toBe(200);

        const second = await postRegister({ install_id, ...SAMPLE_BODY });
        expect(second.status).toBe(409);
        const body = await second.json() as { error: string };
        expect(body.error).toBe("install_id_exists");
    });

    it("missing install_id returns 400", async () => {
        const res = await postRegister({ ...SAMPLE_BODY });
        expect(res.status).toBe(400);
    });

    it("non-UUID-v4 install_id returns 400", async () => {
        const res = await postRegister({ install_id: "not-a-uuid", ...SAMPLE_BODY });
        expect(res.status).toBe(400);
        const body = await res.json() as { error: string };
        expect(body.error).toBe("invalid_install_id");
    });

    it("unknown schema_version returns 400", async () => {
        const res = await postRegister({
            install_id: uuidV4(),
            ...SAMPLE_BODY,
            schema_version: "9999",
        });
        expect(res.status).toBe(400);
        const body = await res.json() as { error: string };
        expect(body.error).toBe("unknown_schema_version");
    });

    it("invalid jve_sha returns 400", async () => {
        const res = await postRegister({
            install_id: uuidV4(),
            ...SAMPLE_BODY,
            jve_sha: "NOTAHEX",
        });
        expect(res.status).toBe(400);
    });

    it("invalid platform returns 400", async () => {
        const res = await postRegister({
            install_id: uuidV4(),
            ...SAMPLE_BODY,
            platform: "Plan9",
        });
        expect(res.status).toBe(400);
    });

    it("invalid arch returns 400", async () => {
        const res = await postRegister({
            install_id: uuidV4(),
            ...SAMPLE_BODY,
            arch: "sparc",
        });
        expect(res.status).toBe(400);
    });

    it("6th call in same hour from same IP returns 429", async () => {
        // Five successful registers with different install_ids.
        for (let i = 0; i < 5; i++) {
            const res = await postRegister({ install_id: uuidV4(), ...SAMPLE_BODY });
            expect(res.status).toBe(200);
        }
        const sixth = await postRegister({ install_id: uuidV4(), ...SAMPLE_BODY });
        expect(sixth.status).toBe(429);
        const body = await sixth.json() as { error: string; retry_after_seconds: number };
        expect(body.error).toBe("rate_limited");
        expect(body.retry_after_seconds).toBeGreaterThan(0);
    });

    it("D1 row stores nonce raw (matches response)", async () => {
        const install_id = uuidV4();
        const res = await postRegister({ install_id, ...SAMPLE_BODY });
        const respBody = await res.json() as { nonce: string };
        const row = await env.DB
            .prepare("SELECT nonce, status, jve_sha FROM installs WHERE install_id = ?")
            .bind(install_id)
            .first<{ nonce: string; status: string; jve_sha: string }>();
        expect(row).not.toBeNull();
        expect(row!.nonce).toBe(respBody.nonce);
        expect(row!.status).toBe("active");
        expect(row!.jve_sha).toBe("8935293");
    });

    it("country and timezone resolved from request.cf are persisted", async () => {
        const install_id = uuidV4();
        await postRegister({ install_id, ...SAMPLE_BODY });
        const row = await env.DB
            .prepare("SELECT country, timezone FROM installs WHERE install_id = ?")
            .bind(install_id)
            .first<{ country: string | null; timezone: string | null }>();
        // Miniflare populates request.cf with synthetic values; we
        // verify the column was written (non-null), not the specific
        // value (which is environment-dependent).
        expect(row).not.toBeNull();
        // At least one of country/timezone MUST be non-null in the dev
        // miniflare; if neither, the handler isn't reading request.cf.
        expect(row!.country !== null || row!.timezone !== null).toBe(true);
    });

    it("install_register_attempts stores ip_hash, never raw IP", async () => {
        await postRegister({ install_id: uuidV4(), ...SAMPLE_BODY });
        const row = await env.DB
            .prepare("SELECT ip_hash, attempt_count, window_start FROM install_register_attempts LIMIT 1")
            .first<{ ip_hash: string; attempt_count: number; window_start: number }>();
        expect(row).not.toBeNull();
        expect(row!.ip_hash).toMatch(/^[0-9a-f]{64}$/);
        expect(row!.ip_hash).not.toMatch(/\./);
        expect(row!.ip_hash).not.toMatch(/:/);
        expect(row!.attempt_count).toBeGreaterThan(0);
    });

    it("concurrent registers from same IP converge to a correct counter", async () => {
        // Two simultaneous calls in the same hour window. The atomic
        // upsert in T042/T045 must guarantee no lost increments
        // (adversarial review concurrency case).
        const calls = [
            postRegister({ install_id: uuidV4(), ...SAMPLE_BODY }),
            postRegister({ install_id: uuidV4(), ...SAMPLE_BODY }),
        ];
        const results = await Promise.all(calls);
        for (const r of results) expect(r.status).toBe(200);
        const row = await env.DB
            .prepare("SELECT attempt_count FROM install_register_attempts LIMIT 1")
            .first<{ attempt_count: number }>();
        expect(row!.attempt_count).toBe(2);
    });
});
