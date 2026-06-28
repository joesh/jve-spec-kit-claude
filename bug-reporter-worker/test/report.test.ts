// Feature 027 T022: POST /report contract tests.
// Implements every bullet from contracts/report.md outline. RED until
// T047 lands the handler + T044 lands github.ts for spying.

import { describe, expect, it } from "vitest";
import { SELF, env } from "cloudflare:test";
import { resetD1BeforeEach, uuidV4 } from "./_helpers";

resetD1BeforeEach();

// FR-027/FR-027a are verified at the D1 boundary:
//   FR-027  — after /report, clusters.gh_issue_url remains null
//             unless /promote ran (no auto-creation).
//   FR-027a — cluster.count bumps as expected; the Nth-comment trigger
//             logic is verified in unit tests of the handler module,
//             not via cross-RPC spy (the vitest-pool-workers boundary
//             rejects shared vi.mock state).

// HMAC helpers (same shape as heartbeat.test.ts).
function hexToBytes(hex: string): Uint8Array {
    const out = new Uint8Array(hex.length / 2);
    for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(2 * i, 2 * i + 2), 16);
    return out;
}
function bytesToHex(bytes: Uint8Array): string {
    return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}
async function sha256Hex(bytes: ArrayBuffer | Uint8Array): Promise<string> {
    const buf = bytes instanceof Uint8Array ? bytes.slice().buffer : bytes;
    const digest = await crypto.subtle.digest("SHA-256", buf);
    return bytesToHex(new Uint8Array(digest));
}
async function hmacHex(nonce_hex: string, message: string): Promise<string> {
    const key = await crypto.subtle.importKey(
        "raw", hexToBytes(nonce_hex), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
    return bytesToHex(new Uint8Array(sig));
}

async function seedInstall(install_id: string, status = "active") {
    const nonce = "a".repeat(64);
    const now = Math.floor(Date.now() / 1000);
    await env.DB.prepare(`
        INSERT INTO installs (install_id, nonce, first_seen, last_launched, jve_sha,
                              platform, arch, status, reports_count, unified_memory)
        VALUES (?, ?, ?, ?, '8935293', 'Darwin', 'arm64', ?, 0, 1)
    `).bind(install_id, nonce, now - 1000, now - 1000, status).run();
    return nonce;
}

function makeMetadata(opts: Partial<{ signature: string; user_title: string; capture_type: string; ts: number; last_cmd: string; last_err: string | null; text_only: boolean; jve_sha: string; user_desc: string }> = {}): string {
    const metadata = {
        signature: opts.signature ?? "f".repeat(64),
        last_cmd: opts.last_cmd ?? "RippleTrimEdge",
        last_err: opts.last_err ?? null,
        user_title: opts.user_title ?? "Cuts disappear after undo",
        user_desc: opts.user_desc ?? "Reproducer steps go here.",
        capture_type: opts.capture_type ?? "user_submitted",
        text_only: opts.text_only ?? false,
        ts: opts.ts ?? Math.floor(Date.now() / 1000),
        jve_sha: opts.jve_sha ?? "8935293",
    };
    // Stable key ordering: alphabetical (mirrors what signature.lua /
    // transport.lua agrees with the Worker on, per contracts/report.md
    // §Signed payload construction).
    const sortedKeys = Object.keys(metadata).sort();
    const ordered: Record<string, unknown> = {};
    for (const k of sortedKeys) ordered[k] = (metadata as Record<string, unknown>)[k];
    return JSON.stringify(ordered);
}

// Build a minimal zip with a "capture.json" entry (uncompressed STORE
// method so we don't need a real zip library). Returns the zip bytes.
function buildMinimalZip(json: string, includeSlideshow = false): Uint8Array {
    // ZIP format: local-file-header * N + central-directory * N + EOCD.
    // We use STORE (no compression) so the file body is the entry bytes
    // verbatim. CRC-32 is computed; everything else is deterministic.
    function crc32(bytes: Uint8Array): number {
        const table = new Uint32Array(256);
        for (let i = 0; i < 256; i++) {
            let c = i;
            for (let j = 0; j < 8; j++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
            table[i] = c;
        }
        let c = 0xFFFFFFFF;
        for (const b of bytes) c = table[(c ^ b) & 0xFF] ^ (c >>> 8);
        return (c ^ 0xFFFFFFFF) >>> 0;
    }
    const enc = new TextEncoder();
    const entries: { name: string; body: Uint8Array; crc: number; offset: number }[] = [];
    const jsonBytes = enc.encode(json);
    entries.push({ name: "capture.json", body: jsonBytes, crc: crc32(jsonBytes), offset: 0 });
    if (includeSlideshow) {
        const mp4Bytes = enc.encode("synthetic-mp4-placeholder");
        entries.push({ name: "slideshow.mp4", body: mp4Bytes, crc: crc32(mp4Bytes), offset: 0 });
    }
    const chunks: Uint8Array[] = [];
    let cursor = 0;
    for (const e of entries) {
        e.offset = cursor;
        const nameBytes = enc.encode(e.name);
        const localHeader = new Uint8Array(30 + nameBytes.length);
        const dv = new DataView(localHeader.buffer);
        dv.setUint32(0, 0x04034b50, true);
        dv.setUint16(4, 20, true);  // version
        dv.setUint16(6, 0, true);   // flags
        dv.setUint16(8, 0, true);   // method = STORE
        dv.setUint16(10, 0, true);  // time
        dv.setUint16(12, 0, true);  // date
        dv.setUint32(14, e.crc, true);
        dv.setUint32(18, e.body.length, true);  // compressed size
        dv.setUint32(22, e.body.length, true);  // uncompressed size
        dv.setUint16(26, nameBytes.length, true);
        dv.setUint16(28, 0, true);  // extra
        localHeader.set(nameBytes, 30);
        chunks.push(localHeader, e.body);
        cursor += localHeader.length + e.body.length;
    }
    const cdStart = cursor;
    for (const e of entries) {
        const nameBytes = enc.encode(e.name);
        const cdHeader = new Uint8Array(46 + nameBytes.length);
        const dv = new DataView(cdHeader.buffer);
        dv.setUint32(0, 0x02014b50, true);
        dv.setUint16(4, 20, true);
        dv.setUint16(6, 20, true);
        dv.setUint16(8, 0, true);
        dv.setUint16(10, 0, true);
        dv.setUint16(12, 0, true);
        dv.setUint16(14, 0, true);
        dv.setUint32(16, e.crc, true);
        dv.setUint32(20, e.body.length, true);
        dv.setUint32(24, e.body.length, true);
        dv.setUint16(28, nameBytes.length, true);
        dv.setUint16(30, 0, true);
        dv.setUint16(32, 0, true);
        dv.setUint16(34, 0, true);
        dv.setUint16(36, 0, true);
        dv.setUint32(38, 0, true);
        dv.setUint32(42, e.offset, true);
        cdHeader.set(nameBytes, 46);
        chunks.push(cdHeader);
        cursor += cdHeader.length;
    }
    const cdSize = cursor - cdStart;
    const eocd = new Uint8Array(22);
    const dv = new DataView(eocd.buffer);
    dv.setUint32(0, 0x06054b50, true);
    dv.setUint16(4, 0, true);
    dv.setUint16(6, 0, true);
    dv.setUint16(8, entries.length, true);
    dv.setUint16(10, entries.length, true);
    dv.setUint32(12, cdSize, true);
    dv.setUint32(16, cdStart, true);
    dv.setUint16(20, 0, true);
    chunks.push(eocd);
    const totalLen = chunks.reduce((s, c) => s + c.length, 0);
    const out = new Uint8Array(totalLen);
    let off = 0;
    for (const c of chunks) { out.set(c, off); off += c.length; }
    return out;
}

async function postReport(opts: {
    install_id: string;
    nonce: string;
    metadata?: string;
    zipBytes?: Uint8Array;
    headers?: Record<string, string>;
    signWith?: string;  // override HMAC key
    localId?: string;
}): Promise<Response> {
    const metadata = opts.metadata ?? makeMetadata();
    const zipBytes = opts.zipBytes ?? buildMinimalZip(metadata, true);
    const signedPayload = metadata + "\n" + (await sha256Hex(zipBytes));
    const sig = await hmacHex(opts.signWith ?? opts.nonce, signedPayload);
    const local_id = opts.localId ?? uuidV4();

    const boundary = "----jveBugBoundary";
    const enc = new TextEncoder();
    const parts: Uint8Array[] = [];
    parts.push(enc.encode(`--${boundary}\r\nContent-Disposition: form-data; name="metadata"\r\nContent-Type: application/json\r\n\r\n`));
    parts.push(enc.encode(metadata));
    parts.push(enc.encode(`\r\n--${boundary}\r\nContent-Disposition: form-data; name="payload"; filename="payload.zip"\r\nContent-Type: application/zip\r\n\r\n`));
    parts.push(zipBytes);
    parts.push(enc.encode(`\r\n--${boundary}--\r\n`));
    const totalLen = parts.reduce((s, p) => s + p.length, 0);
    const body = new Uint8Array(totalLen);
    let off = 0;
    for (const p of parts) { body.set(p, off); off += p.length; }

    return SELF.fetch("https://example.com/report", {
        method: "POST",
        headers: {
            "Content-Type": `multipart/form-data; boundary=${boundary}`,
            "X-Install-Id": opts.install_id,
            "X-Schema-Version": "1",
            "X-HMAC": sig,
            "X-Report-Local-Id": local_id,
            ...opts.headers,
        },
        body,
    });
}

describe("POST /report", () => {
    it("happy path returns 200 with UUID v4 report_id + 8-char ref_short", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const res = await postReport({ install_id, nonce });
        expect(res.status).toBe(200);
        const body = await res.json() as { report_id: string; ref_short: string; cluster_id: string; cluster_count: number };
        expect(body.report_id).toMatch(/^[0-9a-f-]{36}$/);
        expect(body.ref_short).toBe(body.report_id.slice(0, 8));
        expect(body.cluster_count).toBeGreaterThanOrEqual(1);
    });

    it("zip is PUT to R2 at reports/<report_id>.zip", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const res = await postReport({ install_id, nonce });
        const body = await res.json() as { report_id: string };
        const obj = await env.BUCKET.get(`reports/${body.report_id}.zip`);
        expect(obj).not.toBeNull();
    });

    it("D1: reports row inserted; clusters upserted; installs.reports_count bumped", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        await postReport({ install_id, nonce });
        const reportsCount = await env.DB
            .prepare("SELECT COUNT(*) AS n FROM reports WHERE install_id = ?")
            .bind(install_id).first<{ n: number }>();
        expect(reportsCount!.n).toBe(1);
        const installRow = await env.DB
            .prepare("SELECT reports_count FROM installs WHERE install_id = ?")
            .bind(install_id).first<{ reports_count: number }>();
        expect(installRow!.reports_count).toBe(1);
        const clusterRow = await env.DB
            .prepare("SELECT COUNT(*) AS n FROM clusters").first<{ n: number }>();
        expect(clusterRow!.n).toBe(1);
    });

    it("replay with same X-Report-Local-Id returns same report_id (idempotency)", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const local_id = uuidV4();
        const r1 = await postReport({ install_id, nonce, localId: local_id });
        const r2 = await postReport({ install_id, nonce, localId: local_id });
        expect(r1.status).toBe(200);
        expect(r2.status).toBe(200);
        const b1 = await r1.json() as { report_id: string };
        const b2 = await r2.json() as { report_id: string };
        expect(b2.report_id).toBe(b1.report_id);
        const reportsCount = await env.DB.prepare("SELECT COUNT(*) AS n FROM reports").first<{ n: number }>();
        expect(reportsCount!.n).toBe(1);  // no duplicate
    });

    it("two reports with same signature -> ONE cluster with count=2", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const sig = "1".repeat(64);
        await postReport({ install_id, nonce, metadata: makeMetadata({ signature: sig }) });
        await postReport({ install_id, nonce, metadata: makeMetadata({ signature: sig }) });
        const row = await env.DB
            .prepare("SELECT count FROM clusters WHERE signature = ?").bind(sig)
            .first<{ count: number }>();
        expect(row!.count).toBe(2);
        const allClusters = await env.DB.prepare("SELECT COUNT(*) AS n FROM clusters").first<{ n: number }>();
        expect(allClusters!.n).toBe(1);
    });

    it("two reports with different signatures -> TWO cluster rows", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        await postReport({ install_id, nonce, metadata: makeMetadata({ signature: "2".repeat(64) }) });
        await postReport({ install_id, nonce, metadata: makeMetadata({ signature: "3".repeat(64) }) });
        const row = await env.DB.prepare("SELECT COUNT(*) AS n FROM clusters").first<{ n: number }>();
        expect(row!.n).toBe(2);
    });

    it("FR-027: /report does NOT create or modify a cluster's gh_issue_url", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        await postReport({ install_id, nonce });
        const row = await env.DB
            .prepare("SELECT gh_issue_url FROM clusters LIMIT 1")
            .first<{ gh_issue_url: string | null }>();
        expect(row!.gh_issue_url).toBeNull();
    });

    it("FR-027a: report onto a promoted cluster bumps count past N", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const sig = "4".repeat(64);
        await env.DB.prepare(`
            INSERT INTO clusters (id, signature, first_seen, count, gh_issue_url)
            VALUES ('00000000-0000-0000-0000-000000000001', ?, 0, 9, 'https://example.com/issues/1')
        `).bind(sig).run();
        const res = await postReport({ install_id, nonce, metadata: makeMetadata({ signature: sig }) });
        expect(res.status).toBe(200);
        const row = await env.DB
            .prepare("SELECT count FROM clusters WHERE id = '00000000-0000-0000-0000-000000000001'")
            .first<{ count: number }>();
        expect(row!.count).toBe(10);
    });

    it("wrong HMAC returns 401", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const res = await postReport({ install_id, nonce, signWith: "9".repeat(64) });
        expect(res.status).toBe(401);
    });

    it("suspended install returns 403", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id, "suspended");
        const res = await postReport({ install_id, nonce });
        expect(res.status).toBe(403);
    });

    it("payload over 10 MB returns 413", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const huge = new Uint8Array(11 * 1024 * 1024);  // 11 MB of zeros (not a valid zip; size check fires first)
        const res = await postReport({ install_id, nonce, zipBytes: huge });
        expect(res.status).toBe(413);
    });

    it("21st report in 24h window returns 429", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        // Seed 20 reports already today.
        const cluster_id = "00000000-0000-0000-0000-000000000099";
        await env.DB.prepare(`
            INSERT INTO clusters (id, signature, first_seen, count) VALUES (?, '8888888888888888888888888888888888888888888888888888888888888888', 0, 20)
        `).bind(cluster_id).run();
        const now = Math.floor(Date.now() / 1000);
        for (let i = 0; i < 20; i++) {
            await env.DB.prepare(`
                INSERT INTO reports (id, install_id, ts, jve_sha, schema_version, signature, user_title, capture_type, text_only, r2_key, cluster_id)
                VALUES (?, ?, ?, '8935293', '1', '8888888888888888888888888888888888888888888888888888888888888888', 'seed', 'user_submitted', 0, ?, ?)
            `).bind(uuidV4(), install_id, now - i * 60, `reports/seed${i}.zip`, cluster_id).run();
        }
        const res = await postReport({ install_id, nonce });
        expect(res.status).toBe(429);
    });

    it("unknown install_id returns 404", async () => {
        const res = await postReport({ install_id: uuidV4(), nonce: "a".repeat(64) });
        expect(res.status).toBe(404);
    });

    it("empty user_title returns 400", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const res = await postReport({ install_id, nonce, metadata: makeMetadata({ user_title: "" }) });
        expect(res.status).toBe(400);
    });

    it("capture_type not in enum returns 400", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const res = await postReport({ install_id, nonce, metadata: makeMetadata({ capture_type: "midnight_panic" }) });
        expect(res.status).toBe(400);
    });

    it("ts 2 days in future returns 400", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const res = await postReport({
            install_id, nonce,
            metadata: makeMetadata({ ts: Math.floor(Date.now() / 1000) + 2 * 86400 }),
        });
        expect(res.status).toBe(400);
    });

    it("unknown X-Schema-Version returns 400", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const res = await postReport({ install_id, nonce, headers: { "X-Schema-Version": "9" } });
        expect(res.status).toBe(400);
    });

    it("zip without capture.json returns 400 malformed_payload", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        // Build a zip-like blob lacking the capture.json entry.
        const fakezip = new Uint8Array(40);
        // EOCD-only blob (invalid because central directory references nothing).
        new DataView(fakezip.buffer).setUint32(0, 0x06054b50, true);
        const res = await postReport({ install_id, nonce, zipBytes: fakezip });
        expect(res.status).toBe(400);
    });

    it("text_only=true with no slideshow part in zip succeeds", async () => {
        const install_id = uuidV4();
        const nonce = await seedInstall(install_id);
        const metadata = makeMetadata({ text_only: true });
        const zipBytes = buildMinimalZip(metadata, false);
        const res = await postReport({ install_id, nonce, metadata, zipBytes });
        expect(res.status).toBe(200);
    });
});
