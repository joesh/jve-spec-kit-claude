// Feature 027 T021: POST /heartbeat contract tests.
// Implements every bullet from contracts/heartbeat.md outline. RED
// until T046 lands the handler.

import { describe, expect, it } from "vitest";
import { SELF, env } from "cloudflare:test";
import { resetD1BeforeEach, uuidV4 } from "./_helpers";

resetD1BeforeEach();

// Seed an install row so heartbeats have a row to update. Returns the
// nonce so tests can sign requests.
async function seedInstall(install_id: string, opts: { nonce?: string; status?: string; jve_sha?: string } = {}) {
    const nonce = opts.nonce ?? "a".repeat(64);
    const status = opts.status ?? "active";
    const jve_sha = opts.jve_sha ?? "8935293";
    const now = Math.floor(Date.now() / 1000);
    await env.DB
        .prepare(`
            INSERT INTO installs
              (install_id, nonce, first_seen, last_launched, jve_sha,
               platform, arch, status, reports_count, unified_memory,
               cpu_model, cpu_cores_physical, cpu_cores_logical,
               system_memory_mb, gpu_model)
            VALUES (?, ?, ?, ?, ?, 'Darwin', 'arm64', ?, 0, 1,
                    'Apple M2', 10, 10, 32768, 'Apple M2 GPU')
        `)
        .bind(install_id, nonce, now - 1000, now - 1000, jve_sha, status)
        .run();
    return nonce;
}

// HMAC-SHA256(key=hex_nonce, message=body) returning hex.
async function hmac(nonce_hex: string, body: string): Promise<string> {
    const enc = new TextEncoder();
    const key = await crypto.subtle.importKey(
        "raw",
        hexToBytes(nonce_hex),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["sign"],
    );
    const sig = await crypto.subtle.sign("HMAC", key, enc.encode(body));
    return bytesToHex(new Uint8Array(sig));
}

function hexToBytes(hex: string): Uint8Array {
    const bytes = new Uint8Array(hex.length / 2);
    for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(hex.slice(2 * i, 2 * i + 2), 16);
    return bytes;
}

function bytesToHex(bytes: Uint8Array): string {
    return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

async function postHeartbeat(opts: {
    install_id: string;
    nonce: string;
    body: object;
    headers?: Record<string, string>;
    signWith?: string;  // override the HMAC key for bad-HMAC tests
}): Promise<Response> {
    const bodyStr = JSON.stringify(opts.body);
    const sig = await hmac(opts.signWith ?? opts.nonce, bodyStr);
    return SELF.fetch("https://example.com/heartbeat", {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
            "X-Install-Id": opts.install_id,
            "X-Schema-Version": "1",
            "X-HMAC": sig,
            ...opts.headers,
        },
        body: bodyStr,
    });
}

describe("POST /heartbeat", () => {
    it("happy path returns 200 and bumps last_launched", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const ts = Math.floor(Date.now() / 1000);
        const res = await postHeartbeat({
            install_id, nonce, body: { ts, jve_sha: "8935293" },
        });
        expect(res.status).toBe(200);
        const row = await env.DB
            .prepare("SELECT last_launched FROM installs WHERE install_id = ?")
            .bind(install_id)
            .first<{ last_launched: number }>();
        expect(row!.last_launched).toBeGreaterThanOrEqual(ts);
    });

    it("replay is idempotent — last_launched not regressed", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const ts = Math.floor(Date.now() / 1000);
        await postHeartbeat({ install_id, nonce, body: { ts, jve_sha: "8935293" } });
        const earlier_ts = ts - 1000;
        const res = await postHeartbeat({
            install_id, nonce, body: { ts: earlier_ts, jve_sha: "8935293" },
        });
        expect(res.status).toBe(200);
        const row = await env.DB
            .prepare("SELECT last_launched FROM installs WHERE install_id = ?")
            .bind(install_id)
            .first<{ last_launched: number }>();
        expect(row!.last_launched).toBeGreaterThanOrEqual(ts);
    });

    it("missing X-Install-Id returns 404", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const ts = Math.floor(Date.now() / 1000);
        const body = JSON.stringify({ ts, jve_sha: "8935293" });
        const res = await SELF.fetch("https://example.com/heartbeat", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "X-Schema-Version": "1",
                "X-HMAC": await hmac(nonce, body),
            },
            body,
        });
        expect(res.status).toBe(404);
    });

    it("unknown install_id returns 404", async () => {
        const res = await postHeartbeat({
            install_id: uuidV4(),
            nonce: "b".repeat(64),
            body: { ts: Math.floor(Date.now() / 1000), jve_sha: "8935293" },
        });
        expect(res.status).toBe(404);
    });

    it("suspended install returns 403", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id, { status: "suspended" });
        const res = await postHeartbeat({
            install_id, nonce,
            body: { ts: Math.floor(Date.now() / 1000), jve_sha: "8935293" },
        });
        expect(res.status).toBe(403);
    });

    it("wrong X-HMAC returns 401", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const res = await postHeartbeat({
            install_id, nonce,
            signWith: "c".repeat(64),  // wrong key
            body: { ts: Math.floor(Date.now() / 1000), jve_sha: "8935293" },
        });
        expect(res.status).toBe(401);
    });

    it("attacker-chosen-nonce X-HMAC returns 401", async () => {
        // Same shape as the wrong-HMAC test — explicitly enumerated by
        // the contract outline.
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const attackerNonce = "f".repeat(64);
        const res = await postHeartbeat({
            install_id, nonce,
            signWith: attackerNonce,
            body: { ts: Math.floor(Date.now() / 1000), jve_sha: "e9d8d97" },
        });
        expect(res.status).toBe(401);
    });

    it("body with hardware updates GPU/CPU columns", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const ts = Math.floor(Date.now() / 1000);
        const res = await postHeartbeat({
            install_id, nonce,
            body: {
                ts,
                jve_sha: "e9d8d97",
                hardware: {
                    os_version: "26.0.0",
                    arch: "arm64",
                    cpu: { model: "Apple M3 Pro", cores_physical: 12, cores_logical: 12, perf_cores: 8, eff_cores: 4 },
                    system_memory_mb: 65536,
                    gpu: { vendor: "Apple", model: "Apple M3 Pro", memory_mb: 24576, api: "Metal", unified_memory: true },
                },
            },
        });
        expect(res.status).toBe(200);
        const row = await env.DB
            .prepare("SELECT cpu_model, gpu_model, system_memory_mb, jve_sha FROM installs WHERE install_id = ?")
            .bind(install_id)
            .first<{ cpu_model: string; gpu_model: string; system_memory_mb: number; jve_sha: string }>();
        expect(row!.cpu_model).toBe("Apple M3 Pro");
        expect(row!.gpu_model).toBe("Apple M3 Pro");
        expect(row!.system_memory_mb).toBe(65536);
        expect(row!.jve_sha).toBe("e9d8d97");
    });

    it("body without hardware does NOT clobber columns to null", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const res = await postHeartbeat({
            install_id, nonce,
            body: { ts: Math.floor(Date.now() / 1000), jve_sha: "8935293" },
        });
        expect(res.status).toBe(200);
        const row = await env.DB
            .prepare("SELECT cpu_model, gpu_model FROM installs WHERE install_id = ?")
            .bind(install_id)
            .first<{ cpu_model: string | null; gpu_model: string | null }>();
        expect(row!.cpu_model).toBe("Apple M2");
        expect(row!.gpu_model).toBe("Apple M2 GPU");
    });

    it("ts 2 days in future returns 400", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const future_ts = Math.floor(Date.now() / 1000) + 2 * 86400;
        const res = await postHeartbeat({
            install_id, nonce,
            body: { ts: future_ts, jve_sha: "8935293" },
        });
        expect(res.status).toBe(400);
    });

    it("unknown X-Schema-Version returns 400", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const res = await postHeartbeat({
            install_id, nonce,
            body: { ts: Math.floor(Date.now() / 1000), jve_sha: "8935293" },
            headers: { "X-Schema-Version": "9" },
        });
        expect(res.status).toBe(400);
    });
});
