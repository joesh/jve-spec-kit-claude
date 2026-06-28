// HMAC verification + per-IP register rate limit (feature 027 T042).
//
// Shared-secret HMAC: the Worker stores the nonce raw (data-model.md
// §Side effects line 76 — verification requires the secret, not a
// hash). Constant-time compare so timing oracles can't sliver bits.

import * as d1 from "./d1";

function hexToBytes(hex: string): Uint8Array {
    const out = new Uint8Array(hex.length / 2);
    for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(2 * i, 2 * i + 2), 16);
    return out;
}

function bytesToHex(bytes: Uint8Array): string {
    return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function constant_time_equal(a: string, b: string): boolean {
    if (a.length !== b.length) return false;
    let diff = 0;
    for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
    return diff === 0;
}

async function hmac_sha256_hex(nonce_hex: string, message: string): Promise<string> {
    const key = await crypto.subtle.importKey(
        "raw", hexToBytes(nonce_hex), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
    return bytesToHex(new Uint8Array(sig));
}

export async function sha256_hex_text(s: string): Promise<string> {
    const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
    return bytesToHex(new Uint8Array(buf));
}

export async function sha256_hex_bytes(b: Uint8Array): Promise<string> {
    const buf = await crypto.subtle.digest("SHA-256", b.slice().buffer);
    return bytesToHex(new Uint8Array(buf));
}

export interface InstallAuthResult {
    ok: boolean;
    code?: "unknown_install" | "suspended" | "bad_hmac";
    install?: { install_id: string; nonce: string; status: string };
}

export async function verify_install_hmac(
    db: D1Database, install_id: string, signed_payload: string, x_hmac_header: string,
): Promise<InstallAuthResult> {
    const row = await d1.installs.get(db, install_id);
    if (!row) return { ok: false, code: "unknown_install" };
    if (row.status !== "active") return { ok: false, code: "suspended" };
    const expected = await hmac_sha256_hex(row.nonce, signed_payload);
    if (!constant_time_equal(expected, x_hmac_header)) {
        return { ok: false, code: "bad_hmac" };
    }
    return { ok: true, install: { install_id, nonce: row.nonce, status: row.status } };
}

export async function check_install_register_rate(
    db: D1Database, ip_hash: string, current_unix: number, cap: number,
): Promise<{ ok: boolean; retry_after_seconds?: number }> {
    const window_start = Math.floor(current_unix / 3600);
    const { exceeded } = await d1.install_register_attempts.atomic_increment_and_check(
        db, ip_hash, window_start, cap);
    if (exceeded) {
        const next_window_start = (window_start + 1) * 3600;
        return { ok: false, retry_after_seconds: Math.max(1, next_window_start - current_unix) };
    }
    return { ok: true };
}
